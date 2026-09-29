import Foundation

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
}

public enum SpaceMode: String, Codable, CaseIterable, Hashable {
    case nearbyOrWiFi
    case nearbyAndWiFi

    public func allows(ble: Bool, wifi: Bool) -> Bool {
        switch self {
        case .nearbyOrWiFi: ble || wifi
        case .nearbyAndWiFi: ble && wifi
        }
    }
}

public struct SpaceGate {
    private var lastAllowedAt: Int64?

    public init() {}

    public mutating func reset() { lastAllowedAt = nil }

    public mutating func allows(_ mode: SpaceMode, ble: Bool, wifi: Bool, at now: Int64) -> Bool {
        if mode.allows(ble: ble, wifi: wifi) {
            lastAllowedAt = now
            return true
        }
        return lastAllowedAt.map { now < $0 + PeerTiming.leaseSeconds } ?? false
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
        self.origin = origin
        self.revision = revision
        self.quiet = known && quiet
        self.known = known
        self.validUntil = validUntil
        self.targetMilli = targetMilli
        signature = Authentication.sign("peer-state|2|\(origin)|\(revision)|\(self.quiet ? 1 : 0)|\(known ? 1 : 0)|\(validUntil)|\(targetMilli.map(String.init) ?? "-")", key: key)
    }

    public func valid(key: Data, expectedOrigin: String, now: Int64) -> Bool {
        origin == expectedOrigin && validUntil > now && validUntil <= now + PeerTiming.leaseSeconds &&
        (targetMilli.map { (0...500).contains($0) } ?? true) &&
        (!quiet || known) && Authentication.matches(signature, expected: Authentication.sign(
            "peer-state|2|\(origin)|\(revision)|\(quiet ? 1 : 0)|\(known ? 1 : 0)|\(validUntil)|\(targetMilli.map(String.init) ?? "-")", key: key))
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
        signature = Authentication.sign("peer-ack|1|\(origin)|\(revision)|\(quiet ? 1 : 0)|\(result)|\(targetMilli.map(String.init) ?? "-")", key: key)
    }

    public func valid(key: Data, expectedOrigin: String) -> Bool {
        origin == expectedOrigin && (targetMilli.map { (0...500).contains($0) } ?? true) &&
        Authentication.matches(signature, expected: Authentication.sign(
            "peer-ack|1|\(origin)|\(revision)|\(quiet ? 1 : 0)|\(result)|\(targetMilli.map(String.init) ?? "-")", key: key))
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

    public func activeCount(at now: Int64) -> Int {
        records.values.filter { ($0.validUntil ?? 0) > now }.count
    }

    public mutating func takeOver(at now: Int64) {
        if activeCount(at: now) > 0 { manualTakeover = true }
    }

    public mutating func expire(at now: Int64) -> QuietChange {
        change(at: now) { _ in false }
    }

    public mutating func accept(_ update: PeerQuietUpdate, from source: String, expectedOrigin: String,
                                key: Data, at now: Int64) -> QuietChange {
        change(at: now) { records in
            guard update.valid(key: key, expectedOrigin: expectedOrigin, now: now),
                  update.revision > (records[source]?.revision ?? 0) else { return false }
            records[source] = Record(revision: update.revision,
                                     validUntil: update.known ? (update.quiet ? update.validUntil : nil)
                                                              : records[source]?.validUntil)
            return true
        }
    }

    public mutating func stopResponding(at now: Int64) -> QuietChange {
        change(at: now) { records in
            for source in Array(records.keys) { records[source]?.validUntil = nil }
            return false
        }
    }

    public mutating func stopResponding(to source: String, at now: Int64) -> QuietChange {
        change(at: now) { records in
            records[source]?.validUntil = nil
            return false
        }
    }

    private mutating func change(at now: Int64, _ edit: (inout [String: Record]) -> Bool) -> QuietChange {
        let wasActive = records.values.contains { $0.validUntil != nil }
        for source in records.keys where (records[source]?.validUntil ?? 0) <= now {
            records[source]?.validUntil = nil
        }
        let accepted = edit(&records)
        let after = activeCount(at: now)
        let ended = wasActive && after == 0
        let manualAtEnd = ended && manualTakeover
        if ended { manualTakeover = false }
        return QuietChange(started: !wasActive && after > 0, ended: ended,
                           manualAtEnd: manualAtEnd, activeCount: after, accepted: accepted)
    }
}
