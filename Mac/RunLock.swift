import Darwin
import Foundation

final class RunLock {
    private let descriptor: Int32

    init?() {
        let directory = ExclusionStore.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = open(directory.appendingPathComponent("control.lock").path, O_CREAT | O_RDWR, 0o600)
        guard opened >= 0 else { return nil }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { close(opened); return nil }
        descriptor = opened
    }

    deinit { close(descriptor) }
}
