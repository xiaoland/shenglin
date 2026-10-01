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
              let route = uid?.takeRetainedValue() as String? else { return nil }
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

// Only migrates a volume change owned by the previous whole-device implementation.
// New coordination must use ApplicationOutput and must never create this snapshot.
@MainActor enum LegacyOutputRecovery {
    static func recover() -> String? {
        let preferences = MacPreferences.defaults
        let key = "ShenglinMacQuietSnapshot"
        guard let data = preferences.data(forKey: key) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(QuietSnapshot.self, from: data),
              let output = MacOutput.current(),
              let original = VolumePolicy.restore(current: output.volume, route: output.route, snapshot: snapshot) else {
            preferences.removeObject(forKey: key)
            return nil
        }
        guard MacOutput.write(original, on: output.id) else { return "旧版声邻的音量尚未恢复，请手动检查系统音量" }
        preferences.removeObject(forKey: key)
        preferences.synchronize()
        return nil
    }
}
