import Foundation
#if canImport(ShenglinCore)
import ShenglinCore
#endif

final class RemoteMicrophoneCapture {
    private let lock = NSLock()
    private var stopped = false
    private var connection: PeerMicrophoneConnection?
    private var problem: String?
    var error: String? { lock.lock(); defer { lock.unlock() }; return problem }

    init(source: RemoteMicrophoneSource, receive: @escaping (Data) throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                lock.lock(); let done = stopped; lock.unlock()
                if done { return }
                let stream = PeerMicrophoneConnection()
                lock.lock(); connection = stream; let cancelled = stopped; lock.unlock()
                if cancelled { stream.cancel(); return }
                do {
                    guard let peer = try MacCredentials.peers().first(where: { MicrophoneProtocol.peerID($0) == source.peerID }) else {
                        throw MicrophoneProtocol.failure("该设备已解除配对，请移除远端麦克风")
                    }
                    try stream.connect(peer: peer)
                    try stream.request(["operation": "stream", "sourceID": source.sourceID])
                    let format = try JSONSerialization.jsonObject(with: stream.response()) as? [String: Any]
                    guard format?["sampleRate"] as? Int == 48000, format?["channels"] as? Int == 1,
                          format?["encoding"] as? String == "f32le", format?["packetFrames"] as? Int == 960 else {
                        throw MicrophoneProtocol.failure("远端麦克风格式不受支持")
                    }
                    var lastAuthorization = Date()
                    while true {
                        let frame = try stream.next()
                        guard frame.first == 2, frame.count == 3841 else { throw MicrophoneProtocol.failure("音频包格式无效") }
                        let pcm = Data(frame.dropFirst())
                        let finite = pcm.withUnsafeBytes { bytes in
                            stride(from: 0, to: bytes.count, by: 4).allSatisfy { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self).isFinite }
                        }
                        guard finite else { throw MicrophoneProtocol.failure("远端音频包含无效样本") }
                        if Date().timeIntervalSince(lastAuthorization) > 1 {
                            guard try MacCredentials.peers().contains(where: { $0.key == peer.key }) else { throw MicrophoneProtocol.failure("设备已解除配对") }
                            lastAuthorization = Date()
                        }
                        try receive(pcm)
                        lock.lock(); problem = nil; lock.unlock()
                    }
                } catch {
                    lock.lock(); problem = error.localizedDescription; lock.unlock()
                }
                stream.cancel()
                // A fresh authenticated session prevents old TCP backlog from surviving reconnect.
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }
    func stop() {
        lock.lock(); stopped = true; let stream = connection; lock.unlock()
        stream?.cancel()
    }
    deinit { stop() }
}
