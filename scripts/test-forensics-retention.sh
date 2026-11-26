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
SWIFT
cat > "$work/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let rolling = root.appendingPathComponent("test/rolling", isDirectory: true)
try FileManager.default.createDirectory(at: rolling, withIntermediateDirectories: true)
let recorder = AudioForensics.shared
func manifest(in rolling: URL) throws {
    let data = Data(#"{"version":1,"encoding":"interleaved Float32 little-endian","selector":"test"}"#.utf8)
    try data.write(to: rolling.deletingLastPathComponent().appendingPathComponent("manifest.json"))
}
func until(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        recorder.poll([], ids: [:])
        if condition() { return }
        Thread.sleep(forTimeInterval: 0.05)
    }
    preconditionFailure(message)
}
func external(_ program: String, _ arguments: [String]) throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: program)
    child.arguments = arguments
    try child.run()
    child.waitUntilExit()
    precondition(child.terminationStatus == 0)
}
try manifest(in: rolling)
recorder.setLocation(root)
_ = recorder.location
recorder.setLimitGB(1)
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
let newer = try segment(now - 10, 700_000_000)
let newest = try segment(now - 5, 700_000_000)
let unrelated = root.appendingPathComponent("unrelated.bin")
FileManager.default.createFile(atPath: unrelated.path, contents: Data([1]))
let sparse = try FileHandle(forWritingTo: unrelated)
try sparse.truncate(atOffset: 2_000_000_000)
try sparse.close()
until("cap must prune the oldest eligible evidence") {
    !FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: newer.path)
}
precondition(FileManager.default.fileExists(atPath: unrelated.path), "retention must leave unrelated files alone")
precondition(FileManager.default.fileExists(atPath: newest.path), "newest evidence must survive cap pruning")
precondition(abs(recorder.status(for: "test").coverageSeconds - (Int(Date().timeIntervalSince1970) - (now - 5) * 60)) <= 1,
             "coverage must start at the oldest surviving audio minute")
try external("/usr/bin/touch", ["-t", "200001010000", newest.path])
until("external changes must refresh coverage") {
    recorder.status(for: "test").coverageSeconds == 0
}
recorder.recordSource("test", sampleRate: 48_000, channels: 1, hostTime: 1, sampleTime: 0, samples: [0])
_ = recorder.location
precondition(abs(recorder.status(for: "test").coverageSeconds - (Int(Date().timeIntervalSince1970) - (now - 5) * 60)) <= 1,
             "successful audio writes must immediately restore coverage")
Thread.sleep(forTimeInterval: 5.1)
precondition(recorder.status(for: "test").coverageSeconds == 0,
             "cached coverage must expire when recording pauses")
recorder.recordSource("test", sampleRate: 48_000, channels: 1, hostTime: 2, sampleTime: 1, samples: [0])
_ = recorder.location
try external("/bin/rm", [newest.path])
until("retention reconciliation must forget externally deleted audio") {
    abs(recorder.status(for: "test").coverageSeconds - (Int(Date().timeIntervalSince1970) - now * 60)) <= 1
}
let openSegment = try FileManager.default.contentsOfDirectory(at: rolling, includingPropertiesForKeys: nil)
    .first { $0.pathExtension == "bin" }!
try external("/bin/rm", [openSegment.path])
until("coverage must forget a deleted segment even when its handle was open") {
    recorder.status(for: "test").coverageSeconds == 0
}
recorder.recordSource("test", sampleRate: 48_000, channels: 1, hostTime: 3, sampleTime: 2, samples: [0])
_ = recorder.location
precondition(recorder.status(for: "test").coverageSeconds > 0, "the next write must reopen a deleted segment")
precondition(try! FileManager.default.contentsOfDirectory(at: rolling, includingPropertiesForKeys: nil)
    .contains { $0.pathExtension == "bin" }, "the next write must be visible on disk")
let eventBucket = Int(Date().timeIntervalSince1970 / 60)
recorder.mark("test")
let device = DedicatedMicrophone(selector: "test", uid: "test", sourceUID: nil,
                                 outputSampleRate: 48_000, outputChannels: 1)
recorder.performance([device], capture: CaptureDiagnostics(sourceSampleRate: 48_000,
    sourceChannels: 1, directFormat: true, tappedFrames: 123, busyDroppedFrames: 0,
    conversionDroppedFrames: 0, pushFailedFrames: 0, pushedFrames: 123))
recorder.event("test", "large-event", ["payload": String(repeating: "x", count: 1_100_000)])
recorder.event("test", "after-large-event")
_ = recorder.location
let events = rolling.appendingPathComponent("\(eventBucket)-0-events.jsonl")
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
recorder.recordSource("test", sampleRate: 48_000, channels: 1, hostTime: 3, sampleTime: 2, samples: [0])
_ = recorder.location
precondition(!FileManager.default.fileExists(atPath: selected.path),
             "disconnected storage must not be recreated on another volume")
precondition(recorder.status(for: "test").writeErrors > 0,
             "disconnected storage must raise a visible write error")
precondition(recorder.status(for: "test").coverageSeconds == 0,
             "failed audio writes must not create coverage")
var exportError: Error?
recorder.export(to: root.appendingPathComponent("unexpected.zip")) { exportError = $0 }
_ = recorder.location
precondition(exportError != nil, "disconnected storage must not export a substitute directory")
try FileManager.default.moveItem(at: disconnected, to: selected)
recorder.setLocation(selected)
let reselectedBucket = Int(Date().timeIntervalSince1970 / 60)
recorder.event("test", "after-reselect")
_ = recorder.location
precondition(FileManager.default.fileExists(atPath: selected.appendingPathComponent("test/rolling/\(reselectedBucket)-0-events.jsonl").path),
             "reselected storage must resume recording")
precondition(recorder.status(for: "test").warning == nil,
             "a successful reselect must clear the active storage warning")
// Use an isolated archive to compare the old directory-based status algorithm
// with repeated reads of the production cache, without touching user evidence.
let archive = root.appendingPathComponent("status-benchmark", isDirectory: true)
let archiveRolling = archive.appendingPathComponent("test/rolling", isDirectory: true)
try FileManager.default.createDirectory(at: archiveRolling, withIntermediateDirectories: true)
for index in 0..<10_000 {
    try Data([0]).write(to: archiveRolling.appendingPathComponent("\(now - index)-0-upstream.bin"))
}
try FileManager.default.setAttributes([.modificationDate: Date()],
    ofItemAtPath: archiveRolling.appendingPathComponent("\(now)-0-upstream.bin").path)
try manifest(in: archiveRolling)
recorder.setLocation(archive)
_ = recorder.location
let coldStart = DispatchTime.now().uptimeNanoseconds
until("initial inventory must discover existing audio") {
    recorder.status(for: "test").coverageSeconds >= 9_999 * 60
}
let coldMS = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000
func measure(_ iterations: Int, _ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { try body() }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
}
let iterations = 20
let scanMS = try measure(iterations) {
    let files = try FileManager.default.contentsOfDirectory(at: archiveRolling,
        includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
        .filter { $0.pathExtension == "bin" }
    _ = files.compactMap { Int($0.lastPathComponent.split(separator: "-").first ?? "") }.min()
    _ = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
}
let cachedMS = measure(iterations) { _ = recorder.status(for: "test") }
print(String(format: "forensics status (10000 files; %d reads each): old scan %.3f ms/read; warm cached %.3f ms/read; cold discovery %.3f ms", iterations, scanMS, cachedMS, coldMS))
let empty = root.appendingPathComponent("empty", isDirectory: true)
try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
recorder.setLocation(empty)
_ = recorder.location
precondition(recorder.status(for: "test").coverageSeconds == 0,
             "directory changes must not retain coverage from the previous archive")
print("forensics retention: passed")
SWIFT
swiftc "$repo/Mac/AudioForensics.swift" "$work/stubs.swift" "$work/main.swift" -o "$work/test-forensics"
"$work/test-forensics" "$work/evidence"
