import Foundation
#if canImport(ShenglinRust)
import ShenglinRust
#endif

public struct PairingFrame: Codable {
    public enum Kind: String, Codable { case info, start, offer, confirm, finish, reject }
    public let version: Int
    public let kind: Kind
    public let session: Data
    public let message: Data?
    public let name: String?
    public let proof: Data?
    public let pairingMode: Bool?
    public let platform: PeerPlatform?

    public init(kind: Kind, session: Data, message: Data? = nil, name: String? = nil,
                proof: Data? = nil, pairingMode: Bool? = nil, platform: PeerPlatform? = nil, version: Int = 3) {
        self.version = version
        self.platform = platform
        self.kind = kind
        self.session = session
        self.message = message
        self.name = name
        self.proof = proof
        self.pairingMode = pairingMode
    }
    public init(from decoder: Decoder) throws {
        self.init(try decodeRustWire(decoder, using: decodePairing))
    }
    public func encode(to encoder: Encoder) throws { try encodeRustWire(encodePairing(value: rust), to: encoder) }

}

public enum PeerName {
    public static func display(_ claimed: String?, fallback: String) -> String {
        let name = claimed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallback : name
    }
}

public enum PeerPlatform: String, Codable {
    case mac, ipad, android
    public var displayName: String { switch self { case .mac: "Mac"; case .ipad: "iPad"; case .android: "Android" } }
}

public enum PeerTransport: String, Codable { case wifiDirect }

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
    public let transport: PeerTransport?

    public init(key: Data, name: String, platform: PeerPlatform, localRole: PeerRole,
                peripheralID: UUID? = nil, transport: PeerTransport? = nil) throws {
        guard key.count == 32 else { throw PairingError.invalidMessage }
        self.key = key
        self.name = PeerName.display(name, fallback: platform.displayName)
        self.platform = platform
        self.localRole = localRole
        self.peripheralID = peripheralID
        self.transport = transport
    }
}

public struct PeerNameClaim: Codable {
    public let name: String
    public let signature: String

    public init(name: String, key: Data) {
        let claim = signName(name: name, key: key)
        self.name = claim.name
        signature = claim.signature
    }

    public init(from decoder: Decoder) throws {
        let claim = try decodeRustWire(decoder, using: decodeName)
        name = claim.name; signature = claim.signature
    }
    public func encode(to encoder: Encoder) throws {
        try encodeRustWire(encodeName(value: RustNameClaim(name: name, signature: signature)), to: encoder)
    }

    public func valid(key: Data) -> Bool {
        validName(claim: RustNameClaim(name: name, signature: signature), key: key)
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

private func pairingCall<T>(_ operation: () throws -> T) throws -> T {
    do { return try operation() }
    catch let error as CoreError {
        switch error {
        case .InvalidMessage: throw PairingError.invalidMessage
        case .WrongSession: throw PairingError.wrongSession
        case .WrongCode: throw PairingError.wrongCode
        case .Expired: throw PairingError.expired
        case .WrongStep: throw PairingError.wrongStep
        case .CryptoFailed: throw PairingError.cryptoFailed
        }
    }
}

private extension PairingFrame {
    var rust: RustPairingFrame {
        RustPairingFrame(version: Int32(exactly: version) ?? -1, kind: kind.rawValue, session: session,
                         message: message, name: name, proof: proof, pairingMode: pairingMode,
                         platform: platform?.rawValue)
    }
    init(_ frame: RustPairingFrame) {
        self.init(kind: Kind(rawValue: frame.kind)!, session: frame.session, message: frame.message,
                  name: frame.name, proof: frame.proof, pairingMode: frame.pairingMode,
                  platform: frame.platform.flatMap(PeerPlatform.init(rawValue:)), version: Int(frame.version))
    }
}

public enum PairingCode {
    public static func generate() throws -> String { try pairingCall { try pairingCode() } }
}

public final class PairingInitiator {
    private let core: RustPairingInitiator
    public var peerPlatform: PeerPlatform? { core.peerPlatform().flatMap(PeerPlatform.init(rawValue:)) }
    public var peerName: String? { core.peerName() }
    public var session: Data { core.session() }

    public init(code: String, initiatorName: String, platform: PeerPlatform? = nil, now: Date = Date()) throws {
        core = try pairingCall { try RustPairingInitiator(code: code, name: initiatorName,
                                                        platform: platform?.rawValue, now: now.timeIntervalSince1970) }
    }

    public var startFrame: PairingFrame { PairingFrame(core.startFrame()) }

    public func receiveOffer(_ frame: PairingFrame, now: Date = Date()) throws -> PairingFrame {
        try pairingCall { PairingFrame(try core.receiveOffer(frame: frame.rust, now: now.timeIntervalSince1970)) }
    }

    public func receiveFinish(_ frame: PairingFrame, now: Date = Date()) throws -> Data {
        try pairingCall { try core.receiveFinish(frame: frame.rust, now: now.timeIntervalSince1970) }
    }
}

public final class PairingResponder {
    private let core: RustPairingResponder
    public var peerPlatform: PeerPlatform? { core.peerPlatform().flatMap(PeerPlatform.init(rawValue:)) }
    public var session: Data { core.session() }
    public var offerFrame: PairingFrame { PairingFrame(core.offerFrame()) }
    public var confirmedKey: Data? { core.confirmedKey() }

    public init(start: PairingFrame, code: String, responderName: String,
                fallbackName: String = "iPad", platform: PeerPlatform? = nil, now: Date = Date()) throws {
        core = try pairingCall { try RustPairingResponder(start: start.rust, code: code, name: responderName,
            fallbackName: fallbackName, platform: platform?.rawValue, now: now.timeIntervalSince1970) }
    }

    public func receiveConfirm(_ frame: PairingFrame, now: Date = Date()) throws -> PairingFrame {
        try pairingCall { PairingFrame(try core.receiveConfirm(frame: frame.rust, now: now.timeIntervalSince1970)) }
    }
}
