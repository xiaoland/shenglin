import CoreAudio
import Foundation

// 只读 Core Audio 进程状态；不创建采集会话，不读取音频数据。
func audioProcesses() -> [AudioObjectID]? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    if ids.isEmpty { return [] }
    let status = ids.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, buffer.baseAddress!)
    }
    return status == noErr ? ids : nil
}

func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var number: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &number) == noErr ? number : nil
}

func activeInputPIDs() -> Set<pid_t>? {
    guard let processes = audioProcesses() else { return nil }
    var active = Set<pid_t>()
    for object in processes {
        guard let pid = value(object, kAudioProcessPropertyPID),
              let running = value(object, kAudioProcessPropertyIsRunningInput) else { return nil }
        if running == 1 { active.insert(pid_t(pid)) }
    }
    return active
}

let duration = Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
let until = Date().addingTimeInterval(duration)
var previous: Set<pid_t>?
while Date() < until {
    if let current = activeInputPIDs() {
        if let previous {
            for pid in current.subtracting(previous).sorted() { print("\(Date().timeIntervalSince1970) input-start pid=\(pid)") }
            for pid in previous.subtracting(current).sorted() { print("\(Date().timeIntervalSince1970) input-end pid=\(pid)") }
        } else {
            print("\(Date().timeIntervalSince1970) baseline activeInputProcesses=\(current.count)")
        }
        previous = current
        fflush(stdout)
    }
    Thread.sleep(forTimeInterval: 0.25)
}
