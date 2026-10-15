import Foundation
#if canImport(ShenglinRust)
import ShenglinRust
#endif

public enum PeerResult {
    public static func message(_ result: String, device: String) -> String {
        switch result {
        case "applied": "\(device) 音量已降低"
        case "restored", "restoring": "\(device) 音量正在恢复"
        case "alreadyRestored": "\(device) 音量保持原状"
        case "alreadyQuiet", "alreadyBelowTarget": "\(device) 音量已符合目标"
        case "preservedManualOrRoute", "preservedManual": "保留了你手动调整的音量或新输出设备"
        case "paused": "\(device) 已暂停协同"
        case "outsideSpace": "\(device) 未满足空间条件"
        case "unknown": "\(device) 录音状态暂不可用"
        case "protectedLocal": "\(device) 正在使用本机输入，保留本机输出"
        case "partialOutput": "\(device) 已协调可控输出，部分输出暂不支持"
        case "selectiveApplied": "\(device) 已降低其他应用，保留输入应用的输出"
        case "readFailed", "readFailedAfterSet", "setFailed", "restoreFailed", "unsupported", "outputUnsupported":
            "\(device) 音量操作失败"
        case "stalePairing": "\(device) 配对需要重新验证"
        default: "\(device) 响应异常"
        }
    }
}

public enum PeerTiming {
    // Renew well before expiry; the receiver's own clock bounds a lost connection.
    public static let leaseSeconds: Int64 = 20
    public static let renewalSeconds: TimeInterval = 5
    // Paired devices can cross an integer-second boundary at different times.
    // The receiver still caps accepted quiet demand at its own 20-second lease.
    public static let clockSkewToleranceSeconds: Int64 = 5
}

public enum NetworkScope: String, Codable, CaseIterable, Sendable {
    case wifi
    case lan

    public func allows(lanVerified: Bool, wifiVerified: Bool) -> Bool {
        networkScopeAllows(wifiOnly: self == .wifi, lanVerified: lanVerified, wifiVerified: wifiVerified)
    }
}

public enum SpaceMode: String, Codable, CaseIterable, Hashable {
    case nearbyOrWiFi
    case nearbyAndWiFi

    public func allows(ble: Bool, wifi: Bool) -> Bool {
        spacePredicate(requireBoth: self == .nearbyAndWiFi, ble: ble, network: wifi)
    }
}

public struct SpaceGate {
    private var lastAllowedAt: Int64?

    public init() {}

    public mutating func reset() { lastAllowedAt = nil }

    public mutating func allows(_ mode: SpaceMode, ble: Bool, wifi: Bool, at now: Int64) -> Bool {
        let gate = RustSpaceGate()
        gate.loadSnapshot(last: lastAllowedAt)
        let allowed = gate.allows(requireBoth: mode == .nearbyAndWiFi, ble: ble, network: wifi, now: now)
        lastAllowedAt = gate.snapshot()
        return allowed
    }
}

public struct PeerQuietUpdate: Codable {
    public let origin: String
    public let revision: UInt64
    public let quiet: Bool
    public let known: Bool
    public let validUntil: Int64
    public let targetMilli: Int?
    public let signature: String

    public init(origin: String, revision: UInt64, quiet: Bool, known: Bool = true, validUntil: Int64,
                targetMilli: Int? = nil, key: Data) {
        let update = signUpdate(origin: origin, revision: revision, quiet: quiet, known: known,
                                validUntil: validUntil, targetMilli: targetMilli.map(Int64.init), key: key)
        self.origin = update.origin
        self.revision = update.revision
        self.quiet = update.quiet
        self.known = update.known
        self.validUntil = update.validUntil
        self.targetMilli = update.targetMilli.map(Int.init)
        self.signature = update.signature
    }

    public init(from decoder: Decoder) throws {
        let update = try decodeRustWire(decoder, using: decodeUpdate)
        origin = update.origin; revision = update.revision; quiet = update.quiet; known = update.known
        validUntil = update.validUntil; targetMilli = update.targetMilli.map(Int.init); signature = update.signature
    }
    public func encode(to encoder: Encoder) throws { try encodeRustWire(encodeUpdate(value: rust), to: encoder) }

    var rust: PeerUpdate {
        PeerUpdate(origin: origin, revision: revision, quiet: quiet, known: known,
                   validUntil: validUntil, targetMilli: targetMilli.map(Int64.init), signature: signature)
    }

    public func valid(key: Data, expectedOrigin: String, now: Int64) -> Bool {
        validUpdate(update: rust, key: key, expectedOrigin: expectedOrigin, now: now)
    }
}

public struct PeerStateAck: Codable {
    public let origin: String
    public let revision: UInt64
    public let quiet: Bool
    public let result: String
    public let targetMilli: Int?
    public let signature: String

    public init(origin: String, revision: UInt64, quiet: Bool, result: String,
                targetMilli: Int? = nil, key: Data) {
        self.origin = origin
        self.revision = revision
        self.quiet = quiet
        self.result = result
        self.targetMilli = targetMilli
        signature = signAck(origin: origin, revision: revision, quiet: quiet, result: result,
                            targetMilli: targetMilli.map(Int64.init), key: key).signature
    }

    public init(from decoder: Decoder) throws {
        let ack = try decodeRustWire(decoder, using: decodeAck)
        origin = ack.origin; revision = ack.revision; quiet = ack.quiet; result = ack.result
        targetMilli = ack.targetMilli.map(Int.init); signature = ack.signature
    }
    public func encode(to encoder: Encoder) throws { try encodeRustWire(encodeAck(value: rust), to: encoder) }

    var rust: PeerAck {
        PeerAck(origin: origin, revision: revision, quiet: quiet, result: result,
                targetMilli: targetMilli.map(Int64.init), signature: signature)
    }

    public func valid(key: Data, expectedOrigin: String) -> Bool {
        validAck(ack: rust, key: key, expectedOrigin: expectedOrigin)
    }
}

public struct QuietChange {
    public let started: Bool
    public let ended: Bool
    public let manualAtEnd: Bool
    public let activeCount: Int
    public let accepted: Bool
}

public struct PeerDemandLedger: Codable {
    public struct Record: Codable {
        public var revision: UInt64
        public var validUntil: Int64?
    }

    public private(set) var records: [String: Record] = [:]
    public private(set) var manualTakeover = false

    public init() {}

    private func core() -> DemandLedger {
        let ledger = DemandLedger()
        ledger.loadSnapshot(snapshot: LedgerSnapshot(records: records.mapValues {
            DemandRecord(revision: $0.revision, validUntil: $0.validUntil)
        }, manualTakeover: manualTakeover))
        return ledger
    }

    private mutating func adopt(_ ledger: DemandLedger) {
        let snapshot = ledger.snapshot()
        records = snapshot.records.mapValues { Record(revision: $0.revision, validUntil: $0.validUntil) }
        manualTakeover = snapshot.manualTakeover
    }

    private mutating func change(_ operation: (DemandLedger) -> RustQuietChange) -> QuietChange {
        let ledger = core()
        let result = operation(ledger)
        adopt(ledger)
        return QuietChange(started: result.started, ended: result.ended, manualAtEnd: result.manualAtEnd,
                           activeCount: Int(result.activeCount), accepted: result.accepted)
    }

    public func activeCount(at now: Int64) -> Int { Int(core().activeCount(now: now)) }

    public mutating func takeOver(at now: Int64) {
        let ledger = core()
        ledger.takeOver(now: now)
        adopt(ledger)
    }

    public mutating func expire(at now: Int64) -> QuietChange { change { $0.expire(now: now) } }

    public mutating func accept(_ update: PeerQuietUpdate, from source: String, expectedOrigin: String,
                                key: Data, at now: Int64) -> QuietChange {
        change { $0.accept(update: update.rust, source: source, expectedOrigin: expectedOrigin, key: key, now: now) }
    }

    public mutating func stopResponding(at now: Int64) -> QuietChange {
        change { $0.stopResponding(source: nil, now: now) }
    }

    public mutating func stopResponding(to source: String, at now: Int64) -> QuietChange {
        change { $0.stopResponding(source: source, now: now) }
    }
}

/// Native transports retain connection ownership; Rust verifies signed evidence and its lease.
public final class PeerLinkProof {
    private let core = LinkProof()
    public init() {}
    private var elapsed: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    public func sent(_ update: PeerQuietUpdate) { core.sent(update: update.rust) }
    public func clear() { core.clear() }
    public var verified: Bool { core.verified(elapsedMillis: elapsed) }
    public func accept(_ ack: PeerStateAck, key: Data, remoteOrigin: String) -> Bool {
        core.accept(ack: ack.rust, key: key, remoteOrigin: remoteOrigin,
                    wallSeconds: Int64(Date().timeIntervalSince1970), elapsedMillis: elapsed)
    }
    public func accept(_ update: PeerQuietUpdate, key: Data, remoteOrigin: String) -> Bool {
        core.acceptUpdate(update: update.rust, key: key, remoteOrigin: remoteOrigin,
                          wallSeconds: Int64(Date().timeIntervalSince1970), elapsedMillis: elapsed)
    }
}
