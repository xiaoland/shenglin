#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Compile the shipping query functions; only the Core Audio property boundary is substituted.
awk '/^enum InputObservation / { exit } { print }' "$repo/Mac/InputActivity.swift" > "$work/queries.swift"
cat > "$work/main.swift" <<'SWIFT'
import CoreAudio
import Foundation

struct Property: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        self.object = object
        self.selector = selector
    }
}
let list = Property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
let inactive: AudioObjectID = 100
let active: AudioObjectID = 101
let second: AudioObjectID = 102
var properties = [Property: [UInt32]]()
var readOverrides = [Property: [UInt32]]()
var sizeFailures = Set<Property>()
var readFailures = Set<Property>()
var reads = [Property]()
var sizes = [Property]()
var executablePaths = [pid_t: String]()
func executablePath(pid: pid_t) -> String? { executablePaths[pid] }

func AudioObjectGetPropertyDataSize(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    let key = Property(object, address.pointee.mSelector)
    precondition(address.pointee.mScope == (key.selector == kAudioProcessPropertyDevices
        ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal))
    sizes.append(key)
    guard !sizeFailures.contains(key), let value = properties[key] else { return -1 }
    size.pointee = UInt32(value.count * MemoryLayout<UInt32>.size)
    return noErr
}

func AudioObjectGetPropertyData(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>,
    _ output: UnsafeMutableRawPointer) -> OSStatus {
    let key = Property(object, address.pointee.mSelector)
    precondition(address.pointee.mScope == (key.selector == kAudioProcessPropertyDevices
        ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal))
    reads.append(key)
    guard !readFailures.contains(key), let value = readOverrides[key] ?? properties[key] else { return -1 }
    let bytes = value.count * MemoryLayout<UInt32>.size
    precondition(Int(size.pointee) >= bytes)
    if bytes > 0 { value.withUnsafeBytes { source in output.copyMemory(from: source.baseAddress!, byteCount: bytes) } }
    size.pointee = UInt32(bytes)
    return noErr
}

func reset() {
    executablePaths = [getpid(): "/Applications/声邻.app/Contents/MacOS/声邻"]
    properties = [list: [inactive, active],
        Property(inactive, kAudioProcessPropertyIsRunningInput): [0],
        Property(active, kAudioProcessPropertyIsRunningInput): [1],
        Property(active, kAudioProcessPropertyPID): [42],
        Property(active, kAudioProcessPropertyDevices): [201, 202]]
    readOverrides = [:]
    sizeFailures = []
    readFailures = []
    reads = []
    sizes = []
}

reset()
precondition(activeInputDevices() == [42: [201, 202]])
precondition(reads == [list, Property(inactive, kAudioProcessPropertyIsRunningInput),
    Property(active, kAudioProcessPropertyIsRunningInput), Property(active, kAudioProcessPropertyPID),
    Property(active, kAudioProcessPropertyDevices)], "空闲进程不能查询 PID 或设备")
precondition(sizes == [list, Property(active, kAudioProcessPropertyDevices)])
// The inactive PID is deliberately missing: an unreadable inactive PID must not fail the poll.
reset()
properties[list] = [inactive]
precondition(activeInputDevices() == [:])
precondition(reads.count == 2 && sizes == [list])

reset()
properties[list] = [active, second]
properties[Property(second, kAudioProcessPropertyIsRunningInput)] = [1]
properties[Property(second, kAudioProcessPropertyPID)] = [42]
properties[Property(second, kAudioProcessPropertyDevices)] = [202, 203]
precondition(activeInputDevices() == [42: [201, 202, 203]], "同 PID 的设备必须取并集")
precondition(activeInputPIDs(on: 203) == [42])
precondition(activeInputPIDs(on: 999) == [])
precondition(activeInputPIDs() == [42])

for property in [list, Property(inactive, kAudioProcessPropertyIsRunningInput),
                 Property(active, kAudioProcessPropertyIsRunningInput),
                 Property(active, kAudioProcessPropertyPID), Property(active, kAudioProcessPropertyDevices)] {
    reset()
    readFailures = [property]
    precondition(activeInputDevices() == nil, "读取失败必须报告未知状态：\(property)")
    precondition(activeInputPIDs() == nil)
}
for property in [list, Property(active, kAudioProcessPropertyDevices)] {
    reset()
    sizeFailures = [property]
    precondition(activeInputDevices() == nil, "大小查询失败必须报告未知状态")
}
reset()
properties[Property(active, kAudioProcessPropertyDevices)] = []
precondition(activeInputDevices() == [:], "成功空列表没有可归属的输入设备")
precondition(activeInputPIDs(on: 201) == [])
reset()
properties[list] = [active, second]
properties[Property(second, kAudioProcessPropertyIsRunningInput)] = [1]
properties[Property(second, kAudioProcessPropertyPID)] = [43]
properties[Property(second, kAudioProcessPropertyDevices)] = []
precondition(activeInputDevices() == [42: [201, 202]], "空设备进程不能阻断正常客户端")
properties[Property(second, kAudioProcessPropertyPID)] = [42]
precondition(activeInputDevices() == [42: [201, 202]], "同 PID 空设备对象不能抹去有效设备")
reset()
readOverrides[Property(active, kAudioProcessPropertyDevices)] = [201]
precondition(activeInputDevices() == [42: [201]], "只消费实际返回的设备数据")
readOverrides[Property(active, kAudioProcessPropertyDevices)] = []
precondition(activeInputDevices() == [:])
reset()
readOverrides[list] = [inactive]
precondition(activeInputDevices() == [:], "进程列表缩短不读取尾部填充对象")
reset()
properties[list] = []
precondition(activeInputDevices() == [:])
precondition(reads.isEmpty)
// GUI and microphone agent share an executable. Their tap-only input must never reach device queries.
reset()
properties[list] = [active, second]
properties[Property(second, kAudioProcessPropertyIsRunningInput)] = [1]
properties[Property(second, kAudioProcessPropertyPID)] = [43]
properties[Property(second, kAudioProcessPropertyDevices)] = []
executablePaths[43] = executablePaths[getpid()]
precondition(activeInputDevices() == [42: [201, 202]])
precondition(!sizes.contains(Property(second, kAudioProcessPropertyDevices)))
precondition(!reads.contains(Property(second, kAudioProcessPropertyDevices)))
// Exact caller-provided PIDs and the observer itself are excluded at the same boundary.
reset()
precondition(activeInputDevices(ignoringPIDs: [42]) == [:])
precondition(sizes == [list])
reset()
properties[Property(active, kAudioProcessPropertyPID)] = [UInt32(getpid())]
properties[Property(active, kAudioProcessPropertyDevices)] = []
precondition(activeInputDevices() == [:])
precondition(sizes == [list])
// Missing executable metadata must not cause nil == nil to classify an external process as internal.
reset()
executablePaths = [:]
readFailures = [Property(active, kAudioProcessPropertyDevices)]
precondition(activeInputDevices() == nil)
print("通过：空闲进程跳过 PID/设备查询、活跃设备合并、内部 tap 提前排除、成功空列表不阻断其他输入、缩短列表仅取实值、外部失败仍报告未知。")
SWIFT
swiftc "$work/queries.swift" "$work/main.swift" -o "$work/test-input-activity"
"$work/test-input-activity"
