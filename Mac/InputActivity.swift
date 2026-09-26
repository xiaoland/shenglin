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

final class InputActivity {
    private var previous: Set<pid_t>?
    private var lastError: String?
    private let changed: (Bool, Int) -> Void

    init(changed: @escaping (Bool, Int) -> Void) {
        self.changed = changed
    }

    func poll() {
        guard let current = activeInputPIDs() else {
            let message = "Core Audio 输入状态查询失败"
            if lastError != message { print(message); lastError = message }
            return
        }
        let selected: Set<String>
        do {
            selected = try SelectionStore.load()
            lastError = nil
        } catch {
            let message = "无法读取输入源选择：\(error)"
            if lastError != message { print(message); lastError = message }
            return
        }
        let identities = Dictionary(uniqueKeysWithValues: current.map { ($0, sourceIdentities(pid: $0)) })
        let considered = InputSelectionPolicy.activePIDs(identities, selected: selected)
        guard considered != previous else { return }
        previous = considered
        changed(!considered.isEmpty, considered.count)
    }
}
