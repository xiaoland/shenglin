import CoreAudio
import Foundation
import AppKit
import Darwin

// 只读 HAL 元数据。设备 stream 是硬件流，不能当作网页的音频流。
func words(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [String: Any] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard status == noErr else { return ["status": status] }
    guard size % 4 == 0, size <= 65536 else { return ["error": "unexpected size", "bytes": size] }
    if size == 0 { return ["status": 0, "values": [UInt32]()] }
    var result = [UInt32](repeating: 0, count: Int(size) / 4)
    let read = result.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
    }
    return read == noErr ? ["status": 0, "values": Array(result.prefix(Int(size) / 4))] : ["status": read]
}
func first(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    (words(object, selector)["values"] as? [UInt32])?.first
}
func bundle(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
        let path = String(cString: buffer)
        if let end = path.range(of: ".app/") {
            return Bundle(path: String(path[..<end.lowerBound]) + ".app")?.bundleIdentifier ?? "unknown"
        }
    }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
}
let phase = CommandLine.arguments.dropFirst().first ?? "unlabelled"
for _ in 0..<8 {
    let processList = words(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    guard let ids = processList["values"] as? [UInt32] else { fatalError("HAL process list: \(processList)") }
    var rows = [[String: Any]]()
    var deviceIDs = Set<UInt32>()
    for object in ids {
        guard let pid = first(object, kAudioProcessPropertyPID) else { continue }
        let outputs = words(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
        deviceIDs.formUnion(outputs["values"] as? [UInt32] ?? [])
        rows.append(["object": object, "pid": pid, "bundle": bundle(pid_t(pid)),
                     "input": first(object, kAudioProcessPropertyIsRunningInput) as Any? ?? NSNull(),
                     "output": first(object, kAudioProcessPropertyIsRunningOutput) as Any? ?? NSNull(),
                     "outputDevices": outputs,
                     "ownedObjects": words(object, kAudioObjectPropertyOwnedObjects)])
    }
    let devices = deviceIDs.sorted().map { ["object": $0, "outputStreams": words($0, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)] as [String: Any] }
    let json = try JSONSerialization.data(withJSONObject: ["phase": phase, "time": Date().timeIntervalSince1970,
        "processes": rows, "devices": devices], options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
    Thread.sleep(forTimeInterval: 0.25)
}
