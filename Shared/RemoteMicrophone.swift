import Foundation
import Network
#if canImport(ShenglinRust)
import ShenglinRust
#endif

public enum MicrophoneProtocol {
    public static let service = "_shenglin-mic._tcp"
    public static func peerID(_ peer: PairedPeer) -> String { serviceName(key: peer.key) }
    public static func failure(_ message: String) -> NSError {
        NSError(domain: "ShenglinMicrophone", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func checkRemoteError(_ frame: Data) throws {
        if frame.first == 1,
           let object = try? JSONSerialization.jsonObject(with: frame.dropFirst()) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty, message.utf8.count <= 512 {
            throw failure("远端：\(message)")
        }
    }
}

/// Blocking transport runs on a worker, while Network callbacks have their own serial queue.
public final class PeerMicrophoneConnection {
    private let queue = DispatchQueue(label: "Shenglin.PeerMicrophone.Network")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var cancelled = false
    private var tx = Data(), rx = Data()
    private var sent: UInt64 = 0, received: UInt64 = 0

    public init() {}
    deinit { cancel() }
    public func cancel() {
        lock.lock(); cancelled = true; let connection = connection; lock.unlock()
        connection?.cancel()
    }
    private func checkCancelled() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw MicrophoneProtocol.failure("麦克风连接已关闭") }
    }
    public func connect(peer: PairedPeer) throws {
        try checkCancelled()
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: MicrophoneProtocol.service, domain: nil), using: parameters)
        let found = DispatchSemaphore(value: 0)
        var endpoint: NWEndpoint?
        var browseFailure: Error?
        let expected = "\(MicrophoneProtocol.peerID(peer))-\(peer.localRole.remote.rawValue)"
        browser.browseResultsChangedHandler = { results, _ in
            guard endpoint == nil else { return }
            for result in results {
                if case .service(let name, let type, let domain, _) = result.endpoint, name == expected,
                   let interface = result.interfaces.first(where: { $0.type == .wifi || $0.type == .wiredEthernet }) {
                    endpoint = .service(name: name, type: type, domain: domain, interface: interface)
                    found.signal(); break
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { browseFailure = error; found.signal() }
        }
        browser.start(queue: queue)
        let discovered = found.wait(timeout: .now() + 5) == .success
        browser.cancel()
        let selected = try queue.sync { if let browseFailure { throw browseFailure }; return endpoint }
        guard discovered, let selected else { throw MicrophoneProtocol.failure("未发现共享麦克风；请确认对端在线并已向本机授权") }
        try checkCancelled()
        if case .service(_, _, _, let interface) = selected { parameters.requiredInterface = interface }
        let candidate = NWConnection(to: selected, using: parameters)
        try start(candidate)
        let hello = try readJSONLine()
        guard hello["version"] as? Int == 1, let raw = hello["nonce"] as? String,
              let server = Data(base64Encoded: raw), server.count == 32 else { throw MicrophoneProtocol.failure("麦克风协议版本或挑战无效") }
        let client = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        tx = try audioSessionKey(key: peer.key, serverNonce: server, clientNonce: client, role: peer.localRole.rawValue)
        rx = try audioSessionKey(key: peer.key, serverNonce: server, clientNonce: client, role: peer.localRole.remote.rawValue)
        try write(JSONSerialization.data(withJSONObject: ["nonce": client.base64EncodedString(),
            "proof": authenticationSign(message: "microphone-open|1", key: tx)]) + Data([10]))
        let proof = try readJSONLine()
        guard let signature = proof["proof"] as? String,
              authenticationMatches(supplied: signature, expected: authenticationSign(message: "microphone-ready|1", key: rx)) else {
            throw MicrophoneProtocol.failure("共享麦克风身份认证失败")
        }
    }

    private func start(_ candidate: NWConnection) throws {
        lock.lock(); connection = candidate; let stopped = cancelled; lock.unlock()
        if stopped { candidate.cancel(); throw MicrophoneProtocol.failure("麦克风连接已关闭") }
        let ready = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        candidate.stateUpdateHandler = { state in
            guard result == nil else { return }
            switch state {
            case .ready: result = .success(()); ready.signal()
            case .failed(let error): result = .failure(error); ready.signal()
            case .cancelled: result = .failure(MicrophoneProtocol.failure("麦克风连接已关闭")); ready.signal()
            default: break
            }
        }
        candidate.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { cancel(); throw MicrophoneProtocol.failure("麦克风连接超时") }
        try queue.sync { try result!.get() }
    }

    /// Accept only an already-authorized peer; the caller owns revocation and connection limits.
    public func accept(_ candidate: NWConnection, peer: PairedPeer) throws {
        try start(candidate)
        guard let path = candidate.currentPath,
              path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) else {
            throw MicrophoneProtocol.failure("麦克风仅允许局域网连接")
        }
        let server = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        try write(JSONSerialization.data(withJSONObject: ["version": 1, "nonce": server.base64EncodedString()]) + Data([10]))
        let hello = try readJSONLine()
        guard let raw = hello["nonce"] as? String, let client = Data(base64Encoded: raw), client.count == 32,
              let proof = hello["proof"] as? String else { throw MicrophoneProtocol.failure("麦克风认证消息无效") }
        tx = try audioSessionKey(key: peer.key, serverNonce: server, clientNonce: client, role: peer.localRole.rawValue)
        rx = try audioSessionKey(key: peer.key, serverNonce: server, clientNonce: client, role: peer.localRole.remote.rawValue)
        guard authenticationMatches(supplied: proof, expected: authenticationSign(message: "microphone-open|1", key: rx)) else {
            throw MicrophoneProtocol.failure("共享麦克风身份认证失败")
        }
        try write(JSONSerialization.data(withJSONObject: ["proof": authenticationSign(message: "microphone-ready|1", key: tx)]) + Data([10]))
    }

    public func send(_ frame: Data) throws {
        guard (1...16384).contains(frame.count) else { throw MicrophoneProtocol.failure("音频帧长度无效") }
        let record = try audioSeal(key: tx, sequence: sent, plaintext: frame); sent += 1
        var size = UInt32(record.count).bigEndian
        try write(withUnsafeBytes(of: &size) { Data($0) } + record, timeout: frame.first == 2 ? 0.3 : 2)
    }
    public func respond(_ value: [String: Any]) throws {
        try send(Data([1]) + JSONSerialization.data(withJSONObject: value))
    }

    private func write(_ data: Data, timeout: Double = 2) throws {
        try checkCancelled()
        guard let connection else { throw MicrophoneProtocol.failure("麦克风未连接") }
        let done = DispatchSemaphore(value: 0)
        var failure: NWError?
        connection.send(content: data, completion: .contentProcessed { error in failure = error; done.signal() })
        guard done.wait(timeout: .now() + timeout) == .success else { cancel(); throw MicrophoneProtocol.failure("麦克风发送超时") }
        if let failure = queue.sync(execute: { failure }) { throw failure }
    }
    private func read(_ length: Int, timeout: Double = 3) throws -> Data {
        try checkCancelled()
        guard let connection else { throw MicrophoneProtocol.failure("麦克风未连接") }
        let done = DispatchSemaphore(value: 0)
        var output = Data(), failure: Error?
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
            output = data ?? Data(); failure = error; done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { cancel(); throw MicrophoneProtocol.failure("麦克风音频超时") }
        return try queue.sync {
            if let failure { throw failure }
            guard output.count == length else { throw MicrophoneProtocol.failure("麦克风连接中断") }
            return output
        }
    }
    private func readJSONLine() throws -> [String: Any] {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while data.count <= 1024 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw MicrophoneProtocol.failure("麦克风认证超时") }
            let byte = try read(1, timeout: remaining)
            if byte[0] == 10 {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
                return object
            }
            data.append(byte)
        }
        throw MicrophoneProtocol.failure("麦克风控制消息无效")
    }
    public func request(_ value: [String: String]) throws {
        try respond(value)
    }
    public func next() throws -> Data {
        let header = try read(4)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (17...16400).contains(count) else { throw MicrophoneProtocol.failure("音频帧长度无效") }
        let result = try audioOpen(key: rx, sequence: received, ciphertext: read(Int(count)))
        received += 1
        try MicrophoneProtocol.checkRemoteError(result)
        return result
    }
    public func response() throws -> Data {
        let frame = try next()
        guard frame.first == 1 else { throw MicrophoneProtocol.failure("麦克风响应无效") }
        return frame.dropFirst()
    }
    public static func sources(peer: PairedPeer) throws -> [PeerMicrophone] {
        let connection = PeerMicrophoneConnection(); defer { connection.cancel() }
        try connection.connect(peer: peer); try connection.request(["operation": "list"])
        struct List: Decodable { let sources: [PeerMicrophone] }
        let sources = try JSONDecoder().decode(List.self, from: connection.response()).sources
        guard sources.count <= 64, sources.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 512 &&
            !$0.name.isEmpty && $0.name.utf8.count <= 256 && $0.sampleRate == 48000 && $0.channels == 1 }) else {
            throw MicrophoneProtocol.failure("远端麦克风列表无效")
        }
        return sources
    }
}
