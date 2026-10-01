import CoreAudio
import Foundation
#if canImport(ShenglinCore)
import ShenglinCore
#endif

func audioProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var result: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
}

func activeInputDevices() -> [pid_t: Set<AudioObjectID>]? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard !objects.isEmpty else { return [:] }
    let status = objects.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, buffer.baseAddress!)
    }
    guard status == noErr else { return nil }
    var running = [pid_t: Set<AudioObjectID>]()
    for object in objects {
        guard let pid = audioProperty(object, kAudioProcessPropertyPID),
              let active = audioProperty(object, kAudioProcessPropertyIsRunningInput) else { return nil }
        guard active == 1 else { continue }
        do {
            var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                                            mScope: kAudioObjectPropertyScopeInput,
                                                            mElement: kAudioObjectPropertyElementMain)
            var devicesSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &devicesAddress, 0, nil, &devicesSize) == noErr else { return nil }
            var devices = [AudioObjectID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
            guard !devices.isEmpty else { return nil }
            let devicesStatus = devices.withUnsafeMutableBufferPointer { buffer in
                AudioObjectGetPropertyData(object, &devicesAddress, 0, nil, &devicesSize, buffer.baseAddress!)
            }
            guard devicesStatus == noErr else { return nil }
            running[pid_t(pid), default: []].formUnion(devices)
        }
    }
    return running
}

func activeInputPIDs(on device: AudioObjectID? = nil) -> Set<pid_t>? {
    guard let inputs = activeInputDevices() else { return nil }
    return Set(inputs.compactMap { pid, devices in device.map { devices.contains($0) } ?? true ? pid : nil })
}

enum InputObservation {
    case active(Int, Bool)
    case partial(Int, Bool, String)
    case unavailable(String)

    var count: Int {
        if case .active(let count, _) = self { return count }
        if case .partial(let count, _, _) = self { return count }
        return 0
    }

    var localRecording: Bool {
        if case .active(_, let recording) = self { return recording }
        if case .partial(_, let recording, _) = self { return recording }
        return false
    }

    var error: String? {
        if case .unavailable(let message) = self { return message }
        if case .partial(_, _, let message) = self { return message }
        return nil
    }

    var needsQuiet: Bool { count > 0 }
}

final class InputActivity {
    private struct Group: Hashable {
        let sourceUID: String?
        let sampleRate: Int
        let channels: Int
        init(_ device: DedicatedMicrophone) {
            sourceUID = device.sourceUID
            sampleRate = device.outputSampleRate
            channels = device.outputChannels
        }
    }
    private var previous: Set<pid_t>?
    private var previousLocalRecording = false
    private var lastError: String?
    private var captures = [Group: VirtualMicrophone]()
    private let changed: (InputObservation) -> Void
    private let captureEnabled: Bool
    private let ignoredPID: () -> pid_t?
    private(set) var lastObservation = InputObservation.active(0, false)
    // Excluding a source from remote requests must not remove its output protection.
    private(set) var protectedPIDs = Set<pid_t>()
    private(set) var protectedIdentities = Set<String>()
    private(set) var participatingPIDs = Set<pid_t>()
    private(set) var localDemandPIDs = Set<pid_t>()

    var captureDiagnostics: CaptureDiagnostics {
        let values = captures.values.map { $0.diagnostics() }
        return CaptureDiagnostics(sourceSampleRate: values.count == 1 ? values[0].sourceSampleRate : nil,
            sourceChannels: values.count == 1 ? values[0].sourceChannels : nil,
            directFormat: values.count == 1 && values[0].directFormat,
            tappedFrames: values.reduce(0) { $0 + $1.tappedFrames },
            busyDroppedFrames: values.reduce(0) { $0 + $1.busyDroppedFrames },
            conversionDroppedFrames: values.reduce(0) { $0 + $1.conversionDroppedFrames },
            pushFailedFrames: values.reduce(0) { $0 + $1.pushFailedFrames },
            pushedFrames: values.reduce(0) { $0 + $1.pushedFrames })
    }

    init(captureEnabled: Bool = true, ignoredPID: @escaping () -> pid_t? = { nil },
         changed: @escaping (InputObservation) -> Void) {
        self.captureEnabled = captureEnabled
        self.ignoredPID = ignoredPID
        self.changed = changed
    }

    private func unavailable(_ message: String) {
        protectedPIDs = []
        protectedIdentities = []
        participatingPIDs = []
        localDemandPIDs = []
        for capture in captures.values { capture.suspend() }
        guard lastError != message else { return }
        print(message)
        lastError = message
        previous = nil
        previousLocalRecording = false
        // Unknown input state must not keep a stale request to lower iPad volume.
        lastObservation = .unavailable(message)
        changed(lastObservation)
    }

    func poll() {
        guard var inputs = activeInputDevices() else {
            unavailable("Core Audio 输入状态查询失败")
            return
        }
        inputs.removeValue(forKey: getpid())
        if let ignored = ignoredPID() { inputs.removeValue(forKey: ignored) }
        let current = Set(inputs.keys)
        let excluded: Set<String>
        let muted: Set<String>
        let microphones: [DedicatedMicrophone]
        do {
            excluded = try ExclusionStore.load()
            muted = try MuteStore.load()
            microphones = try MicrophoneStore.load()
        } catch {
            unavailable("无法读取应用设置：\(error)")
            return
        }
        let identities = Dictionary(uniqueKeysWithValues: current.map { ($0, sourceIdentities(pid: $0)) })
        var considered = InputExclusionPolicy.activePIDs(identities, excluded: excluded)
        protectedPIDs = current
        protectedIdentities = identities.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        participatingPIDs = considered
        localDemandPIDs = current
        if !captureEnabled {
            let mutedIDs = Set(microphones.filter { muted.contains($0.selector) }
                .compactMap { VirtualMicrophone.deviceID(uid: $0.uid) })
            let mutedPIDs = DedicatedInputPolicy.mutedPIDs(inputs, mutedDevices: mutedIDs)
            considered.subtract(mutedPIDs)
            participatingPIDs = considered
            localDemandPIDs.subtract(mutedPIDs)
            let localRecording = !current.subtracting(mutedPIDs).isEmpty
            if considered != previous || localRecording != previousLocalRecording || lastError != nil {
                previous = considered
                previousLocalRecording = localRecording
                lastError = nil
                lastObservation = .active(considered.count, localRecording)
                changed(lastObservation)
            }
            return
        }
        let groups = Dictionary(grouping: microphones, by: Group.init)
        for key in Array(captures.keys) where groups[key] == nil { captures.removeValue(forKey: key)?.suspend() }
        var problems = [String]()
        for (key, devices) in groups {
            let capture = captures[key] ?? VirtualMicrophone(sourceUID: key.sourceUID,
                sampleRate: key.sampleRate, channels: key.channels)
            captures[key] = capture
            do {
                considered.subtract(try capture.update(inputs: inputs, devices: microphones,
                    group: devices, muted: muted))
            } catch {
                capture.suspend()
                problems.append("\(devices.map(\.name).joined(separator: "、"))：\(error.localizedDescription)")
                let failedIDs = Set(devices.compactMap { VirtualMicrophone.deviceID(uid: $0.uid) })
                considered.subtract(DedicatedInputPolicy.mutedPIDs(inputs, mutedDevices: failedIDs))
            }
            AudioForensics.shared.performance(devices, capture: capture.diagnostics())
        }
        let problem = problems.isEmpty ? nil : "专用麦克风不可用：\(problems.joined(separator: "；"))"
        AudioForensics.shared.poll(microphones)
        if problem != lastError {
            for device in microphones {
                AudioForensics.shared.event(device.selector, problem == nil ? "capture-recovered" : "capture-error",
                    problem.map { ["error": $0] } ?? [:])
            }
        }
        let localRecording = !current.isEmpty
        guard considered != previous || localRecording != previousLocalRecording || lastError != problem else { return }
        previous = considered
        previousLocalRecording = localRecording
        lastError = problem
        if let problem { lastObservation = .partial(considered.count, localRecording, problem) }
        else { lastObservation = .active(considered.count, localRecording) }
        changed(lastObservation)
    }
}
