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

func activeInputPIDs(on device: AudioObjectID? = nil) -> Set<pid_t>? {
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
        guard active == 1 else { continue }
        if let device {
            var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                                            mScope: kAudioObjectPropertyScopeInput,
                                                            mElement: kAudioObjectPropertyElementMain)
            var devicesSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &devicesAddress, 0, nil, &devicesSize) == noErr else { return nil }
            var devices = [AudioObjectID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
            guard !devices.isEmpty else { continue }
            let devicesStatus = devices.withUnsafeMutableBufferPointer { buffer in
                AudioObjectGetPropertyData(object, &devicesAddress, 0, nil, &devicesSize, buffer.baseAddress!)
            }
            guard devicesStatus == noErr else { return nil }
            guard devices.contains(device) else { continue }
        }
        running.insert(pid_t(pid))
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
    private let virtualMicrophone = VirtualMicrophone()
    private let changed: (InputObservation) -> Void

    init(changed: @escaping (InputObservation) -> Void) {
        self.changed = changed
    }

    private func unavailable(_ message: String) {
        virtualMicrophone?.suspend()
        guard lastError != message else { return }
        print(message)
        lastError = message
        previous = nil
        // Unknown input state must not keep a stale request to lower iPad volume.
        changed(.unavailable(message))
    }

    func poll() {
        guard var current = activeInputPIDs() else {
            unavailable("Core Audio 输入状态查询失败")
            return
        }
        current.remove(getpid())
        let excluded: Set<String>
        let muted: Set<String>
        do {
            excluded = try ExclusionStore.load()
            muted = try MuteStore.load()
        } catch {
            unavailable("无法读取应用设置：\(error)")
            return
        }
        let identities = Dictionary(uniqueKeysWithValues: current.map { ($0, sourceIdentities(pid: $0)) })
        var considered = InputExclusionPolicy.activePIDs(identities, excluded: excluded)
        if let virtualMicrophone {
            guard let virtualClients = activeInputPIDs(on: virtualMicrophone.deviceID) else {
                unavailable("Core Audio 虚拟麦克风输入状态查询失败")
                return
            }
            let clients = virtualClients.subtracting([getpid()])
            let mutedClients = clients.filter { !(identities[$0] ?? []).isDisjoint(with: muted) }
            do {
                try virtualMicrophone.update(activeClients: clients, mutedClients: mutedClients)
            } catch {
                unavailable("虚拟麦克风不可用：\(error.localizedDescription)")
                return
            }
            considered.subtract(mutedClients)
        }
        guard considered != previous else { return }
        previous = considered
        lastError = nil
        changed(.active(considered.count))
    }
}
