#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/stubs.swift" <<'SWIFT'
import Foundation
struct CaptureDiagnostics: Codable {}
struct ForensicStatus: Codable { let coverageSeconds: Int }
struct Device { let selector: String }
enum MicrophoneStore {
    static let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("microphones.json")
    static func load() throws -> [Device] { [Device(selector: "remote")] }
}
final class State {
    let lock = NSLock()
    var polls = 0
    var snapshots = 0
    func poll() { lock.lock(); polls += 1; lock.unlock() }
    func snapshot() { lock.lock(); snapshots += 1; lock.unlock() }
    func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (polls, snapshots) }
}
let state = State()
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
final class AudioForensics {
    static let shared = AudioForensics()
    func status(for selector: String) -> ForensicStatus {
        state.snapshot()
        entered.signal()
        release.wait()
        return ForensicStatus(coverageSeconds: 123)
    }
}
final class InputActivity {
    struct Observation { var error: String? { nil } }
    let lastObservation = Observation()
    let captureDiagnostics = CaptureDiagnostics()
    init(changed: @escaping (Observation) -> Void) {}
    func poll() { state.poll() }
}
SWIFT
cat > "$work/main.swift" <<'SWIFT'
import Foundation
DispatchQueue.global().async {
    precondition(entered.wait(timeout: .now() + 10) == .success)
    let before = state.counts().0
    Thread.sleep(forTimeInterval: 1.2)
    let during = state.counts()
    guard during.0 - before >= 3, during.1 == 1,
          let status = MicrophoneAgentStatus.current(),
          Date().timeIntervalSince(status.updatedAt) < 0.75 else {
        fputs("失败：诊断阻塞了输入检测/心跳，或重复排入诊断查询。\n", stderr)
        exit(1)
    }
    release.signal()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if MicrophoneAgentStatus.current()?.forensics["remote"]?.coverageSeconds == 123 {
            print("通过：诊断阻塞时输入检测与心跳继续，查询不堆积，释放后状态更新。")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    fputs("失败：诊断完成后未发布快照。\n", stderr)
    exit(1)
}
MicrophoneAgent.run()
SWIFT
swiftc "$work/stubs.swift" "${1:-$repo/Mac/MicrophoneAgent.swift}" "$work/main.swift" -o "$work/check"
"$work/check" "$work/data"
