import CryptoKit
import Foundation
import Security
#if canImport(NativePAKE)
import NativePAKE
#endif

public struct PairingFrame: Codable {
    public enum Kind: String, Codable { case info, start, offer, confirm, finish, reject }
    private enum CodingKeys: String, CodingKey {
        case version = "v", kind = "k", session = "s", message = "p", name = "d", proof = "f", pairingMode = "m"
    }
    public let version: Int
    public let kind: Kind
    public let session: Data
    public let message: Data?
    public let name: String?
    public let proof: Data?
    public let pairingMode: Bool?

    public init(kind: Kind, session: Data, message: Data? = nil, name: String? = nil,
                proof: Data? = nil, pairingMode: Bool? = nil) {
        version = 3
        self.kind = kind
        self.session = session
        self.message = message
        self.name = name
        self.proof = proof
        self.pairingMode = pairingMode
    }
}

public enum PeerName {
    public static func display(_ claimed: String?, fallback: String) -> String {
        let name = claimed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallback : name
    }
}

public enum PeerPlatform: String, Codable { case mac, ipad }

public enum PeerRole: String, Codable {
    case initiator, responder
    public var remote: PeerRole { self == .initiator ? .responder : .initiator }
}

/// An authenticated relationship. The key identifies the relationship; a platform is a transport capability.
public struct PairedPeer: Codable {
    public let key: Data
    public var name: String
    public let platform: PeerPlatform
    public let localRole: PeerRole
    public var peripheralID: UUID?

    public init(key: Data, name: String, platform: PeerPlatform, localRole: PeerRole,
                peripheralID: UUID? = nil) throws {
        guard key.count == 32 else { throw PairingError.invalidMessage }
        self.key = key
        self.name = PeerName.display(name, fallback: platform == .mac ? "Mac" : "iPad")
        self.platform = platform
        self.localRole = localRole
        self.peripheralID = peripheralID
    }
}

public struct PeerNameClaim: Codable {
    public let name: String
    public let signature: String

    public init(name: String, key: Data) {
        let clean = PeerName.display(String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })), fallback: "设备")
        var value = String(clean.prefix(64))
        while value.utf8.count > 128 { value.removeLast() }
        self.name = value
        signature = Authentication.sign("peer-name|3|\(value)", key: key)
    }

    public func valid(key: Data) -> Bool {
        !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
        name.utf8.count <= 128 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        Authentication.matches(signature, expected: Authentication.sign("peer-name|3|\(name)", key: key))
    }
}

public enum PairingError: Error, Equatable, LocalizedError {
    case invalidMessage, wrongSession, wrongCode, expired, wrongStep, cryptoFailed

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: "配对消息无效"
        case .wrongSession: "配对会话不一致"
        case .wrongCode: "验证码错误或配对消息被修改"
        case .expired: "配对已超时"
        case .wrongStep: "配对步骤不正确"
        case .cryptoFailed: "安全配对计算失败"
        }
    }
}

private final class SPAKE2 {
    private var state: OpaquePointer?
    let message: Data

    init(code: String, role: Int32) throws {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw PairingError.wrongCode
        }
        var output = Data(count: 32)
        let codeBytes = Data(code.utf8)
        state = codeBytes.withUnsafeBytes { secret in
            output.withUnsafeMutableBytes { message in
                na_spake_start(role, secret.bindMemory(to: UInt8.self).baseAddress,
                               secret.count, message.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        guard state != nil else { throw PairingError.cryptoFailed }
        message = output
    }

    func finish(peer: Data) throws -> Data {
        guard peer.count == 32, let state else { throw PairingError.invalidMessage }
        var key = Data(count: 64)
        let success = peer.withUnsafeBytes { bytes in
            key.withUnsafeMutableBytes { output in
                na_spake_finish(state, bytes.bindMemory(to: UInt8.self).baseAddress,
                                output.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        na_spake_free(state)
        self.state = nil
        guard success == 1 else { throw PairingError.invalidMessage }
        return key
    }

    deinit { if let state { na_spake_free(state) } }
}

private struct PairingKeys {
    let control: Data
    let proof: SymmetricKey
    let transcriptHash: Data
}

private enum PairingCrypto {
    static func random16() throws -> Data {
        var data = Data(count: 16)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PairingError.cryptoFailed }
        return data
    }

    static func name(_ text: String, fallback: String) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\\" && $0 != "\""
        }))
        var filtered = String(clean.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        while filtered.utf8.count > 24 { filtered.removeLast() }
        return filtered.isEmpty ? fallback : filtered
    }

    static func validName(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= 96,
              name(text, fallback: "") == text else { return nil }
        return text
    }

    private static func append(_ field: Data, to data: inout Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(field)
    }

    static func derive(secret: Data, session: Data, initiatorName: String, responderName: String,
                       initiatorMessage: Data, responderMessage: Data) -> PairingKeys {
        var transcript = Data("NearbyAudio-SPAKE2-v3".utf8)
        for field in [session, Data(initiatorName.utf8), Data(responderName.utf8), initiatorMessage, responderMessage] {
            append(field, to: &transcript)
        }
        let hash = Data(SHA256.hash(data: transcript))
        let material = SymmetricKey(data: secret)
        func key(_ purpose: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: hash,
                                   info: Data("NearbyAudio-SPAKE2-v3/\(purpose)".utf8), outputByteCount: 32)
        }
        return PairingKeys(control: key("control").withUnsafeBytes { Data($0) },
                           proof: key("proof"), transcriptHash: hash)
    }

    static func proof(_ role: String, keys: PairingKeys) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(role.utf8) + keys.transcriptHash, using: keys.proof))
    }

    static func matches(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

public enum PairingCode {
    public static func generate() throws -> String {
        var value: UInt32 = 0
        // Rejection sampling keeps all six-digit codes equally likely.
        repeat {
            let status = withUnsafeMutableBytes(of: &value) {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            guard status == errSecSuccess else { throw PairingError.cryptoFailed }
        } while value >= 4_294_000_000
        return String(format: "%06d", value % 1_000_000)
    }
}

public final class PairingInitiator {
    private enum Step { case started, ready, confirmed, finished }
    private let pake: SPAKE2
    private let initiatorName: String
    private let deadline: Date
    private var step: Step = .started
    private var keys: PairingKeys?
    public private(set) var peerName: String?
    public let session: Data

    public init(code: String, initiatorName: String, now: Date = Date()) throws {
        self.initiatorName = PairingCrypto.name(initiatorName, fallback: "Mac")
        pake = try SPAKE2(code: code, role: 0)
        session = try PairingCrypto.random16()
        deadline = now.addingTimeInterval(90)
    }

    public var startFrame: PairingFrame {
        PairingFrame(kind: .start, session: session, message: pake.message, name: initiatorName)
    }

    private func check(_ frame: PairingFrame, kind: PairingFrame.Kind, now: Date) throws {
        guard now < deadline else { throw PairingError.expired }
        guard frame.version == 3, frame.kind == kind else { throw PairingError.invalidMessage }
        guard frame.session == session else { throw PairingError.wrongSession }
    }

    public func receiveOffer(_ frame: PairingFrame, now: Date = Date()) throws -> PairingFrame {
        guard step == .started else { throw PairingError.wrongStep }
        try check(frame, kind: .offer, now: now)
        guard let message = frame.message, message.count == 32,
              let name = PairingCrypto.validName(frame.name) else { throw PairingError.invalidMessage }
        let secret = try pake.finish(peer: message)
        keys = PairingCrypto.derive(secret: secret, session: session, initiatorName: initiatorName,
                                    responderName: name, initiatorMessage: pake.message, responderMessage: message)
        peerName = name
        step = .ready
        return try confirm(now: now)
    }

    private func confirm(now: Date) throws -> PairingFrame {
        guard now < deadline else { throw PairingError.expired }
        guard step == .ready, let keys else { throw PairingError.wrongStep }
        step = .confirmed
        return PairingFrame(kind: .confirm, session: session,
                            proof: PairingCrypto.proof("initiator-confirm", keys: keys))
    }

    public func receiveFinish(_ frame: PairingFrame, now: Date = Date()) throws -> Data {
        guard step == .confirmed, let keys else { throw PairingError.wrongStep }
        try check(frame, kind: .finish, now: now)
        guard let proof = frame.proof,
              PairingCrypto.matches(proof, PairingCrypto.proof("responder-confirm", keys: keys))
        else { throw PairingError.wrongCode }
        step = .finished
        return keys.control
    }
}

public final class PairingResponder {
    private enum Step { case offered, finished }
    private let keys: PairingKeys
    private let deadline: Date
    private var step: Step = .offered
    public let session: Data
    public let offerFrame: PairingFrame
    public var confirmedKey: Data? { step == .finished ? keys.control : nil }

    public init(start: PairingFrame, code: String, responderName: String,
                fallbackName: String = "iPad", now: Date = Date()) throws {
        guard start.version == 3, start.kind == .start, start.session.count == 16,
              let message = start.message, message.count == 32,
              let initiatorName = PairingCrypto.validName(start.name) else { throw PairingError.invalidMessage }
        session = start.session
        deadline = now.addingTimeInterval(90)
        let normalizedPadName = PairingCrypto.name(responderName, fallback: fallbackName)
        let pake = try SPAKE2(code: code, role: 1)
        let secret = try pake.finish(peer: message)
        keys = PairingCrypto.derive(secret: secret, session: session, initiatorName: initiatorName,
                                    responderName: normalizedPadName, initiatorMessage: message, responderMessage: pake.message)
        offerFrame = PairingFrame(kind: .offer, session: session, message: pake.message, name: normalizedPadName)
    }

    public func receiveConfirm(_ frame: PairingFrame, now: Date = Date()) throws -> PairingFrame {
        guard step == .offered else { throw PairingError.wrongStep }
        guard now < deadline else { throw PairingError.expired }
        guard frame.version == 3, frame.kind == .confirm else { throw PairingError.invalidMessage }
        guard frame.session == session else { throw PairingError.wrongSession }
        guard let proof = frame.proof,
              PairingCrypto.matches(proof, PairingCrypto.proof("initiator-confirm", keys: keys))
        else { throw PairingError.wrongCode }
        step = .finished
        return PairingFrame(kind: .finish, session: session,
                            proof: PairingCrypto.proof("responder-confirm", keys: keys))
    }
}
