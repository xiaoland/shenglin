import Darwin
import Foundation
import ServiceManagement

struct MicrophoneAgentStatus: Codable {
    let pid: pid_t
    let updatedAt: Date
    let error: String?
    let diagnostics: CaptureDiagnostics
    let forensics: [String: ForensicStatus]

    static let plistName = "local.shenglin.microphone.plist"
    static let service = SMAppService.agent(plistName: plistName)
    static let url = MicrophoneStore.url.deletingLastPathComponent()
        .appendingPathComponent("microphone-agent.json")

    static func current() -> Self? {
        guard let data = try? Data(contentsOf: url),
              let status = try? JSONDecoder().decode(Self.self, from: data),
              abs(status.updatedAt.timeIntervalSinceNow) < 2 else { return nil }
        return status
    }
}

enum MicrophoneAgent {
    static func run() -> Never {
        let directory = MicrophoneStore.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("microphone-agent.lock").path,
                              O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { exit(1) }
        let activity = InputActivity { observation in
            if let error = observation.error { NSLog("Shenglin microphone agent: %@", error) }
        }
        var forensics = [String: ForensicStatus]()
        var lastForensicCheck = Date.distantPast
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            activity.poll()
            if Date().timeIntervalSince(lastForensicCheck) >= 1 {
                forensics = Dictionary(uniqueKeysWithValues: ((try? MicrophoneStore.load()) ?? [])
                    .map { ($0.selector, AudioForensics.shared.status(for: $0.selector)) })
                lastForensicCheck = Date()
            }
            let status = MicrophoneAgentStatus(pid: getpid(), updatedAt: Date(),
                error: activity.lastObservation.error, diagnostics: activity.captureDiagnostics,
                forensics: forensics)
            if let data = try? JSONEncoder().encode(status) {
                try? data.write(to: MicrophoneAgentStatus.url, options: .atomic)
            }
        }
        activity.poll()
        RunLoop.current.add(timer, forMode: .common)
        RunLoop.current.run()
        exit(0)
    }
}
