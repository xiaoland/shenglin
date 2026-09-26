import CryptoKit
import Foundation
import Security

public struct PairingFrame: Codable {
    public enum Kind: String, Codable { case info, start, offer, nonceA, nonceB, confirm, finish, reject }
    private enum CodingKeys: String, CodingKey {
        case version = "v", kind = "k", session = "s", publicKey = "p", nonce = "n"
        case commitment = "c", name = "d", proof = "f", pairingMode = "m"
    }
    public let version: Int
    public let kind: Kind
    public let session: Data
    public let publicKey: Data?
    public let nonce: Data?
    public let commitment: Data?
    public let name: String?
    public let proof: Data?
    public let pairingMode: Bool?

    public init(kind: Kind, session: Data, publicKey: Data? = nil, nonce: Data? = nil,
                commitment: Data? = nil, name: String? = nil, proof: Data? = nil,
                pairingMode: Bool? = nil) {
        version = 1
        self.kind = kind
        self.session = session
        self.publicKey = publicKey
        self.nonce = nonce
        self.commitment = commitment
        self.name = name
        self.proof = proof
        self.pairingMode = pairingMode
    }
}

public enum PairingError: Error, Equatable, LocalizedError {
    case invalidMessage, wrongSession, wrongCommitment, wrongProof, expired, wrongStep

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: "配对消息无效"
        case .wrongSession: "配对会话不一致"
        case .wrongCommitment: "配对承诺校验失败"
        case .wrongProof: "配对确认校验失败"
        case .expired: "配对已超时"
        case .wrongStep: "配对步骤不正确"
        }
    }
}

private struct PairingKeys {
    let control: Data
    let sas: SymmetricKey
    let proof: SymmetricKey
    let transcriptHash: Data
}

private enum PairingCrypto {
    static func random16() throws -> Data {
        var data = Data(count: 16)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return data
    }

    static func name(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\\" && $0 != "\""
        }))
        var filtered = String(clean.prefix(24))
        while filtered.utf8.count > 24 { filtered.removeLast() }
        return filtered.isEmpty ? "设备" : filtered
    }

    static func validName(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= 96, name(text) == text else { return nil }
        return text
    }

    private static func append(_ field: Data, to data: inout Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(field)
    }

    static func context(session: Data, macKey: Data, padKey: Data, macName: String, padName: String) -> Data {
        var data = Data("NearbyAudio-Pair-v1".utf8)
        for field in [session, macKey, padKey, Data(macName.utf8), Data(padName.utf8)] { append(field, to: &data) }
        return data
    }

    static func commitment(context: Data, nonceB: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("pad-commit".utf8) + context,
                                             using: SymmetricKey(data: nonceB)))
    }

    static func derive(privateKey: P256.KeyAgreement.PrivateKey, peer: P256.KeyAgreement.PublicKey,
                       context: Data, nonceA: Data, nonceB: Data) throws -> PairingKeys {
        var transcript = context
        append(nonceA, to: &transcript)
        append(nonceB, to: &transcript)
        let hash = Data(SHA256.hash(data: transcript))
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        func key(_ purpose: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: hash,
                                           sharedInfo: Data("NearbyAudio-Pair-v1/\(purpose)".utf8), outputByteCount: 32)
        }
        let control = key("control").withUnsafeBytes { Data($0) }
        return PairingKeys(control: control, sas: key("sas"), proof: key("proof"), transcriptHash: hash)
    }

    static func code(_ keys: PairingKeys) -> String {
        let digest = Data(HMAC<SHA256>.authenticationCode(for: keys.transcriptHash, using: keys.sas))
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06d", number)
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

public final class PairingInitiator {
    private enum Step { case started, offered, ready, confirmed, finished }
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private let nonceA: Data
    private let macName: String
    private let deadline: Date
    private var step: Step = .started
    private var peerKey: P256.KeyAgreement.PublicKey?
    public private(set) var peerName: String?
    private var peerCommitment: Data?
    private var keys: PairingKeys?
    public let session: Data
    public private(set) var shortCode: String?

    public init(macName: String, now: Date = Date()) throws {
        self.macName = PairingCrypto.name(macName)
        nonceA = try PairingCrypto.random16()
        session = try PairingCrypto.random16()
        deadline = now.addingTimeInterval(90)
    }

    public var startFrame: PairingFrame {
        PairingFrame(kind: .start, session: session,
                     publicKey: privateKey.publicKey.x963Representation, name: macName)
    }

    private func check(_ frame: PairingFrame, kind: PairingFrame.Kind, now: Date) throws {
        guard now < deadline else { throw PairingError.expired }
        guard frame.version == 1, frame.kind == kind else { throw PairingError.invalidMessage }
        guard frame.session == session else { throw PairingError.wrongSession }
    }

    public func receiveOffer(_ frame: PairingFrame, now: Date = Date()) throws -> PairingFrame {
        guard step == .started else { throw PairingError.wrongStep }
        try check(frame, kind: .offer, now: now)
        guard let bytes = frame.publicKey, bytes.count == 65,
              let name = PairingCrypto.validName(frame.name),
              let commitment = frame.commitment, commitment.count == 32,
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: bytes) else { throw PairingError.invalidMessage }
        peerKey = peer
        peerName = name
        peerCommitment = commitment
        step = .offered
        return PairingFrame(kind: .nonceA, session: session, nonce: nonceA)
    }

    public func receiveNonceB(_ frame: PairingFrame, now: Date = Date()) throws {
        guard step == .offered, let peerKey, let peerName, let peerCommitment else { throw PairingError.wrongStep }
        try check(frame, kind: .nonceB, now: now)
        guard let nonceB = frame.nonce, nonceB.count == 16 else { throw PairingError.invalidMessage }
        let context = PairingCrypto.context(session: session, macKey: privateKey.publicKey.x963Representation,
                                            padKey: peerKey.x963Representation, macName: macName, padName: peerName)
        guard PairingCrypto.matches(peerCommitment, PairingCrypto.commitment(context: context, nonceB: nonceB))
        else { throw PairingError.wrongCommitment }
        let derived = try PairingCrypto.derive(privateKey: privateKey, peer: peerKey,
                                               context: context, nonceA: nonceA, nonceB: nonceB)
        keys = derived
        shortCode = PairingCrypto.code(derived)
        step = .ready
    }

    public func confirm(now: Date = Date()) throws -> PairingFrame {
        guard now < deadline else { throw PairingError.expired }
        guard step == .ready, let keys else { throw PairingError.wrongStep }
        step = .confirmed
        return PairingFrame(kind: .confirm, session: session,
                            proof: PairingCrypto.proof("mac-confirm", keys: keys))
    }

    public func receiveFinish(_ frame: PairingFrame, now: Date = Date()) throws -> Data {
        guard step == .confirmed, let keys else { throw PairingError.wrongStep }
        try check(frame, kind: .finish, now: now)
        guard let proof = frame.proof,
              PairingCrypto.matches(proof, PairingCrypto.proof("pad-confirm", keys: keys))
        else { throw PairingError.wrongProof }
        step = .finished
        return keys.control
    }
}

public final class PairingResponder {
    private enum Step { case offered, ready, finished }
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private let nonceB: Data
    private let peerKey: P256.KeyAgreement.PublicKey
    private let macName: String
    private let padName: String
    private let deadline: Date
    private var step: Step = .offered
    private var keys: PairingKeys?
    private var macConfirmed = false
    private var padConfirmed = false
    public let session: Data
    public let offerFrame: PairingFrame
    public private(set) var shortCode: String?
    public var confirmedKey: Data? { step == .finished ? keys?.control : nil }

    public init(start: PairingFrame, padName: String, now: Date = Date()) throws {
        guard start.version == 1, start.kind == .start, start.session.count == 16,
              let bytes = start.publicKey, bytes.count == 65,
              let name = PairingCrypto.validName(start.name),
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: bytes) else { throw PairingError.invalidMessage }
        session = start.session
        peerKey = peer
        macName = name
        self.padName = PairingCrypto.name(padName)
        nonceB = try PairingCrypto.random16()
        deadline = now.addingTimeInterval(90)
        let context = PairingCrypto.context(session: session, macKey: bytes,
                                            padKey: privateKey.publicKey.x963Representation,
                                            macName: macName, padName: self.padName)
        offerFrame = PairingFrame(kind: .offer, session: session,
                                  publicKey: privateKey.publicKey.x963Representation,
                                  commitment: PairingCrypto.commitment(context: context, nonceB: nonceB),
                                  name: self.padName)
    }

    private func check(_ frame: PairingFrame, kind: PairingFrame.Kind, now: Date) throws {
        guard now < deadline else { throw PairingError.expired }
        guard frame.version == 1, frame.kind == kind else { throw PairingError.invalidMessage }
        guard frame.session == session else { throw PairingError.wrongSession }
    }

    public func receiveNonceA(_ frame: PairingFrame, now: Date = Date()) throws -> PairingFrame {
        guard step == .offered else { throw PairingError.wrongStep }
        try check(frame, kind: .nonceA, now: now)
        guard let nonceA = frame.nonce, nonceA.count == 16 else { throw PairingError.invalidMessage }
        let context = PairingCrypto.context(session: session, macKey: peerKey.x963Representation,
                                            padKey: privateKey.publicKey.x963Representation,
                                            macName: macName, padName: padName)
        let derived = try PairingCrypto.derive(privateKey: privateKey, peer: peerKey,
                                               context: context, nonceA: nonceA, nonceB: nonceB)
        keys = derived
        shortCode = PairingCrypto.code(derived)
        step = .ready
        return PairingFrame(kind: .nonceB, session: session, nonce: nonceB)
    }

    private func finishIfBothConfirmed() -> PairingFrame? {
        guard macConfirmed, padConfirmed, step == .ready, let keys else { return nil }
        step = .finished
        return PairingFrame(kind: .finish, session: session,
                            proof: PairingCrypto.proof("pad-confirm", keys: keys))
    }

    public func confirmLocal(now: Date = Date()) throws -> PairingFrame? {
        guard now < deadline else { throw PairingError.expired }
        guard step == .ready else { throw PairingError.wrongStep }
        padConfirmed = true
        return finishIfBothConfirmed()
    }

    public func receiveConfirm(_ frame: PairingFrame, now: Date = Date()) throws -> PairingFrame? {
        guard step == .ready, let keys else { throw PairingError.wrongStep }
        try check(frame, kind: .confirm, now: now)
        guard let proof = frame.proof,
              PairingCrypto.matches(proof, PairingCrypto.proof("mac-confirm", keys: keys))
        else { throw PairingError.wrongProof }
        macConfirmed = true
        return finishIfBothConfirmed()
    }
}
