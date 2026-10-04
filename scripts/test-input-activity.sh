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
var sizeFailures = Set<Property>()
var readFailures = Set<Property>()
var reads = [Property]()
var sizes = [Property]()

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
    guard !readFailures.contains(key), let value = properties[key] else { return -1 }
    let bytes = value.count * MemoryLayout<UInt32>.size
    precondition(Int(size.pointee) >= bytes)
    value.withUnsafeBytes { source in output.copyMemory(from: source.baseAddress!, byteCount: bytes) }
    size.pointee = UInt32(bytes)
    return noErr
}

func reset() {
    properties = [list: [inactive, active],
        Property(inactive, kAudioProcessPropertyIsRunningInput): [0],
        Property(active, kAudioProcessPropertyIsRunningInput): [1],
        Property(active, kAudioProcessPropertyPID): [42],
        Property(active, kAudioProcessPropertyDevices): [201, 202]]
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
precondition(activeInputDevices() == nil, "活跃输入缺少设备必须报告未知状态")
reset()
properties[list] = []
precondition(activeInputDevices() == [:])
precondition(reads.isEmpty)
print("通过：空闲进程跳过 PID/设备查询、活跃设备合并及筛选、Core Audio 查询失败边界。")
SWIFT
swiftc "$work/queries.swift" "$work/main.swift" -o "$work/test-input-activity"
"$work/test-input-activity"
