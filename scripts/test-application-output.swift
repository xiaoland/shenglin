import AppKit
import CoreAudio
import Foundation

// Only the external observation/store dependencies are substituted. The relay buffer function,
// BrowserAdapter validation and Native Messaging parser compile from the shipping source files.
func audioProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? { nil }
func sourceIdentities(pid: pid_t) -> Set<String> { [] }
func executablePath(pid: pid_t) -> String? { nil }
struct MicrophoneAgentStatus { let pid: pid_t; static func current() -> Self? { nil } }
struct CaptureDiagnostics: Codable {}
enum PeerPlatform: String, Codable { case mac, ipad }
enum ExclusionStore {
    static let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shenglin-test/exclusions.json")
}

@main struct OutputCheck {
    @MainActor static func main() throws {
        let source: [Float] = [0.002, -0.002, 0.001, -0.001]
        var destination = [Float](repeating: 9, count: 4)
        source.withUnsafeBytes { input in
            destination.withUnsafeMutableBytes { output in
                var a = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: UnsafeMutableRawPointer(mutating: input.baseAddress)))
                var b = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: output.baseAddress))
                assert(applyOutputGain(&a, &b, gain: 0.2))
                assert(abs(output.load(as: Float.self) - 0.0004) < 1e-9)
                assert(applyOutputGain(&a, &b, gain: 0))
                assert(output.load(as: Float.self) == 0)
                assert(!applyOutputGain(&a, &b, gain: .nan))
                b.mBuffers.mNumberChannels = 1
                assert(!applyOutputGain(&a, &b, gain: 0.2))
                assert(output.load(as: Float.self) == 0)
            }
        }
        assert(source[0] == 0.002)
        assert(isBrowser(["bundle:net.imput.helium", "path:/helper"]))
        assert(isBrowser(["bundle:com.google.Chrome.beta"]))
        assert(!isBrowser(["bundle:com.openai.chat"]))
        let adapter = BrowserAdapter(), id = UUID().uuidString
        try adapter.accept(BrowserSnapshot(connection: id, pages: [BrowserPage(id: "doc-a", role: "conversation", input: "active", controllable: false)]))
        assert(adapter.needsQuiet && adapter.known)
        adapter.expire(at: ProcessInfo.processInfo.systemUptime + 6)
        assert(!adapter.needsQuiet && adapter.pages.isEmpty)
        try adapter.accept(BrowserSnapshot(connection: id, pages: [BrowserPage(id: "doc-a", role: "conversation", input: "idle", controllable: false)]))
        assert(!adapter.needsQuiet && adapter.known)
        try adapter.accept(BrowserSnapshot(connection: id, pages: [BrowserPage(id: "doc-a", role: "conversation", input: "unknown", controllable: false)]))
        assert(!adapter.needsQuiet && !adapter.known)
        let background = BrowserPage(id: "doc-b", role: "background", input: "idle", controllable: true)
        for invalid in [BrowserSnapshot(connection: "", pages: []),
                        BrowserSnapshot(connection: id, pages: [background, background]),
                        BrowserSnapshot(connection: id, pages: [BrowserPage(id: "doc-c", role: "background", input: "active", controllable: true)]),
                        BrowserSnapshot(connection: id, pages: (0...64).map { BrowserPage(id: String($0), role: "background", input: "idle", controllable: true) })] {
            do { try adapter.accept(invalid); assertionFailure("必须拒绝无效网页快照") } catch {}
        }
        try adapter.accept(BrowserSnapshot(connection: id, pages: []))
        assert(!adapter.needsQuiet && adapter.known)
        print("通过：正式缓冲增益、零增益、格式拒绝、浏览器分组、网页状态、文档更换和容量边界。")
    }
}
