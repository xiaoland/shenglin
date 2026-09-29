import CoreAudio
import Foundation
#if canImport(ShenglinCore)
import ShenglinCore
#endif

private struct MacOutput {
    let id: AudioObjectID
    let route: String
    let volume: Float

    static func current() -> MacOutput? {
        var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress,
                                         0, nil, &size, &id) == noErr else { return nil }
        var volumeAddress = address()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(id, &volumeAddress),
              AudioObjectIsPropertySettable(id, &volumeAddress, &settable) == noErr,
              settable.boolValue else { return nil }
        var value: Float = -1
        size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &volumeAddress, 0, nil, &size, &value) == noErr,
              value.isFinite, (0...1).contains(value) else { return nil }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &size, &uid) == noErr,
              let route = uid?.takeUnretainedValue() as String? else { return nil }
        return MacOutput(id: id, route: route, volume: value)
    }

    static func address() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func write(_ value: Float, on id: AudioObjectID) -> Bool {
        var address = address()
        var value = value
        return AudioObjectSetPropertyData(id, &address, 0, nil,
                                          UInt32(MemoryLayout<Float>.size), &value) == noErr
    }
}

@MainActor final class MacQuietVolume {
    private let stateKey = "ShenglinMacQuietSnapshot"
    private let onManual: () -> Void
    private var snapshot: QuietSnapshot?
    private var roundActive = false
    private var manual = false
    private var restoring = false
    private var expectedVolume: Float?
    private var observedDevice: AudioObjectID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var restoreTimer: Timer?
    private var restoreStepCount = 0
    private var restoreStart: Float = 0

    init(onManual: @escaping () -> Void) {
        self.onManual = onManual
        if let data = MacPreferences.defaults.data(forKey: stateKey) {
            snapshot = try? JSONDecoder().decode(QuietSnapshot.self, from: data)
        }
    }

    private func save() {
        MacPreferences.defaults.set(snapshot.flatMap { try? JSONEncoder().encode($0) }, forKey: stateKey)
        MacPreferences.defaults.synchronize()
    }

    func recoverPreviousRound() {
        guard snapshot != nil else { return }
        finish(manualAtEnd: false)
    }

    func begin(target: Float) -> String {
        if roundActive, let saved = snapshot {
            guard !manual, let output = MacOutput.current(),
                  output.route == saved.route, let expectedVolume,
                  abs(output.volume - expectedVolume) <= 0.005 else { return "preservedManual" }
            guard let wanted = VolumePolicy.target(current: output.volume, configured: target) else {
                return "alreadyQuiet"
            }
            self.expectedVolume = wanted
            guard MacOutput.write(wanted, on: output.id), let actual = MacOutput.current(),
                  actual.route == saved.route else {
                self.expectedVolume = output.volume
                return "setFailed"
            }
            snapshot = QuietSnapshot(original: saved.original, applied: actual.volume, route: saved.route)
            self.expectedVolume = actual.volume
            save()
            return "applied"
        }
        roundActive = false
        // A new request during the restore ramp must retain the original pre-quiet volume.
        let recovering = restoring ? snapshot : nil
        let previousExpected = expectedVolume
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoring = false
        roundActive = true
        manual = false
        guard let output = MacOutput.current() else { return "outputUnsupported" }
        watch(output.id)
        let original: Float
        if let recovering, output.route == recovering.route,
           let previousExpected, abs(output.volume - previousExpected) <= 0.005 {
            original = recovering.original
        } else { original = output.volume }
        let wanted = VolumePolicy.target(current: output.volume, configured: target)
        snapshot = QuietSnapshot(original: original,
                                 applied: wanted ?? output.volume, route: output.route)
        expectedVolume = wanted ?? output.volume
        save()
        guard let wanted else { return "alreadyBelowTarget" }
        guard MacOutput.write(wanted, on: output.id), let actual = MacOutput.current(),
              actual.route == output.route else {
            snapshot = nil
            save()
            return "setFailed"
        }
        snapshot = QuietSnapshot(original: original, applied: actual.volume, route: output.route)
        expectedVolume = actual.volume
        save()
        return "applied"
    }

    func finish(manualAtEnd: Bool) {
        roundActive = false
        guard let saved = snapshot, !manualAtEnd, !manual,
              let output = MacOutput.current(), output.route == saved.route,
              abs(output.volume - saved.applied) <= 0.005 else {
            clear()
            return
        }
        guard abs(saved.original - output.volume) > 0.005 else { clear(); return }
        restoring = true
        watch(output.id)
        expectedVolume = output.volume
        restoreStepCount = 0
        restoreStart = output.volume
        restoreTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restoreStep() }
        }
    }

    private func restoreStep() {
        guard let saved = snapshot, let output = MacOutput.current(), output.route == saved.route,
              let expectedVolume, abs(output.volume - expectedVolume) <= 0.005 else {
            clear()
            return
        }
        restoreStepCount += 1
        let next = restoreStart + (saved.original - restoreStart) * Float(restoreStepCount) / 8
        self.expectedVolume = next
        guard MacOutput.write(next, on: output.id), let actual = MacOutput.current(),
              actual.route == saved.route else {
            clear()
            return
        }
        self.expectedVolume = actual.volume
        if restoreStepCount == 8 { clear() }
    }

    private func watch(_ device: AudioObjectID) {
        if observedDevice == device { return }
        unwatch()
        observedDevice = device
        var volumeAddress = MacOutput.address()
        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeVolume() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &volumeAddress, .main, volumeBlock) == noErr {
            volumeListener = volumeBlock
        }
        var routeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
        let routeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeVolume() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &routeAddress, .main, routeBlock) == noErr {
            routeListener = routeBlock
        }
    }

    private func observeVolume() {
        guard roundActive || restoring, let saved = snapshot else { return }
        guard let output = MacOutput.current(), output.route == saved.route,
              let expectedVolume, abs(output.volume - expectedVolume) <= 0.005 else {
            manual = true
            if roundActive { onManual() }
            restoreTimer?.invalidate()
            restoreTimer = nil
            if restoring { clear() }
            return
        }
    }

    private func clear() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoring = false
        snapshot = nil
        expectedVolume = nil
        save()
        unwatch()
    }

    private func unwatch() {
        if let observedDevice, let volumeListener {
            var address = MacOutput.address()
            AudioObjectRemovePropertyListenerBlock(observedDevice, &address, .main, volumeListener)
        }
        if let routeListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, .main, routeListener)
        }
        observedDevice = nil
        volumeListener = nil
        routeListener = nil
    }
}
