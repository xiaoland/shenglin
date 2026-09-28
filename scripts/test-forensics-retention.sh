#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/stubs.swift" <<'SWIFT'
import CoreAudio
import Foundation

enum MacPreferences {
    static let defaults = UserDefaults(suiteName: "Shenglin.ForensicsRetentionTest.\(UUID())")!
}
struct DedicatedMicrophone: Equatable {
    let selector: String
    let uid: String
    let sourceUID: String?
    let outputSampleRate: Int
    let outputChannels: Int
}
struct CaptureDiagnostics {
    let sourceSampleRate: Double?
    let sourceChannels: Int?
    let directFormat: Bool
    let tappedFrames: Int64
    let busyDroppedFrames: Int64
    let conversionDroppedFrames: Int64
    let pushFailedFrames: Int64
    let pushedFrames: Int64
}
enum VirtualMicrophone {
    static func deviceID(uid: String) -> AudioObjectID? { nil }
}
SWIFT
cat > "$work/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let rolling = root.appendingPathComponent("test/rolling", isDirectory: true)
try FileManager.default.createDirectory(at: rolling, withIntermediateDirectories: true)
let recorder = AudioForensics.shared
recorder.setLocation(root)
_ = recorder.location
recorder.setLimitGB(1)
_ = recorder.location
let now = Int(Date().timeIntervalSince1970 / 60)
func segment(_ minute: Int, _ bytes: UInt64) throws -> URL {
    let url = rolling.appendingPathComponent("\(minute)-0-upstream.bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let file = try FileHandle(forWritingTo: url)
    try file.truncate(atOffset: bytes)
    try file.close()
    return url
}
let old = try segment(now - 20_000, 100)
recorder.poll([])
_ = recorder.location
precondition(FileManager.default.fileExists(atPath: old.path), "age alone must not delete evidence")
let newer = try segment(now - 10, 700_000_000)
let newest = try segment(now - 5, 700_000_000)
recorder.setLimitGB(1)
_ = recorder.location
precondition(!FileManager.default.fileExists(atPath: old.path))
precondition(!FileManager.default.fileExists(atPath: newer.path))
precondition(FileManager.default.fileExists(atPath: newest.path), "newest evidence must survive cap pruning")
recorder.mark("test")
let device = DedicatedMicrophone(selector: "test", uid: "test", sourceUID: nil,
                                 outputSampleRate: 48_000, outputChannels: 1)
recorder.performance([device], capture: CaptureDiagnostics(sourceSampleRate: 48_000,
    sourceChannels: 1, directFormat: true, tappedFrames: 123, busyDroppedFrames: 0,
    conversionDroppedFrames: 0, pushFailedFrames: 0, pushedFrames: 123))
recorder.event("test", "large-event", ["payload": String(repeating: "x", count: 1_100_000)])
recorder.event("test", "after-large-event")
_ = recorder.location
let events = rolling.appendingPathComponent("\(now)-0-events.jsonl")
let content = try String(contentsOf: events, encoding: .utf8)
precondition(content.contains("incident-marked"), "manual mark must be recorded")
precondition(content.contains("capture-performance") && content.contains("\"tappedFrames\":123"),
             "capture counters must be retained as events")
precondition(content.contains("large-event") && content.contains("after-large-event"),
             "event history must not rotate at 1 MB")
precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("test/incidents").path),
             "mark must not duplicate retained audio")
let selected = root.appendingPathComponent("selected", isDirectory: true)
let disconnected = root.appendingPathComponent("disconnected", isDirectory: true)
let alias = root.appendingPathComponent("selected-link", isDirectory: true)
try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selected)
recorder.setLocation(alias)
precondition(recorder.location == selected, "storage selection must resolve symlinks")
try FileManager.default.moveItem(at: selected, to: disconnected)
recorder.setLocation(alias)
_ = recorder.location
recorder.event("test", "after-disconnect")
_ = recorder.location
precondition(!FileManager.default.fileExists(atPath: selected.path),
             "disconnected storage must not be recreated on another volume")
precondition(recorder.status(for: "test").writeErrors > 0,
             "disconnected storage must raise a visible write error")
var exportError: Error?
recorder.export(to: root.appendingPathComponent("unexpected.zip")) { exportError = $0 }
_ = recorder.location
precondition(exportError != nil, "disconnected storage must not export a substitute directory")
try FileManager.default.moveItem(at: disconnected, to: selected)
recorder.setLocation(selected)
recorder.event("test", "after-reselect")
_ = recorder.location
precondition(FileManager.default.fileExists(atPath: selected.appendingPathComponent("test/rolling/\(now)-0-events.jsonl").path),
             "reselected storage must resume recording")
precondition(recorder.status(for: "test").warning == nil,
             "a successful reselect must clear the active storage warning")
print("forensics retention: passed")
SWIFT
swiftc "$repo/Mac/AudioForensics.swift" "$work/stubs.swift" "$work/main.swift" -o "$work/test-forensics"
"$work/test-forensics" "$work/evidence"
