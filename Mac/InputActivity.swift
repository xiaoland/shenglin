import CoreAudio
import Foundation
#if canImport(NearbyAudioCore)
import NearbyAudioCore
#endif

func audioProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var result: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
}

func activeInputPIDs() -> Set<pid_t>? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard !objects.isEmpty else { return [] }
    let status = objects.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, buffer.baseAddress!)
    }
    guard status == noErr else { return nil }
    var running = Set<pid_t>()
    for object in objects {
        guard let pid = audioProperty(object, kAudioProcessPropertyPID),
              let active = audioProperty(object, kAudioProcessPropertyIsRunningInput) else { return nil }
        if active == 1 { running.insert(pid_t(pid)) }
    }
    return running
}

enum InputObservation {
    case active(Int)
    case unavailable(String)

    var count: Int {
        if case .active(let count) = self { return count }
        return 0
    }

    var error: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }

    var needsQuiet: Bool { count > 0 }
}

final class InputActivity {
    private var previous: Set<pid_t>?
    private var lastError: String?
    private let changed: (InputObservation) -> Void

    init(changed: @escaping (InputObservation) -> Void) {
        self.changed = changed
    }

    private func unavailable(_ message: String) {
        guard lastError != message else { return }
        print(message)
        lastError = message
        previous = nil
        // Unknown input state must not keep a stale request to lower iPad volume.
        changed(.unavailable(message))
    }

    func poll() {
        guard let current = activeInputPIDs() else {
            unavailable("Core Audio 输入状态查询失败")
            return
        }
        let excluded: Set<String>
        do {
            excluded = try ExclusionStore.load()
        } catch {
            unavailable("无法读取排除设置：\(error)")
            return
        }
        let identities = Dictionary(uniqueKeysWithValues: current.map { ($0, sourceIdentities(pid: $0)) })
        let considered = InputExclusionPolicy.activePIDs(identities, excluded: excluded)
        guard considered != previous else { return }
        previous = considered
        lastError = nil
        changed(.active(considered.count))
    }
}
