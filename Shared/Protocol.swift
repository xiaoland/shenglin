import CryptoKit
import Foundation

// These UUIDs are the BLE wire contract shared by the Mac and iPad targets.
public enum BLEIdentifiers {
    public static let service = "8A27D37F-A94F-4A53-AD7C-0D48CC8108CF"
    public static let command = "E1FA496A-299F-4C84-9621-63396F75A3F2"
    public static let ack = "0F20B426-BBC9-48A4-A518-82827239AA9E"
    public static let pairingService = "C985D59E-9D34-4F37-8F14-03C942690C78"
    public static let pairingWrite = "01FA287F-9E5C-4A8A-8B58-23A9808981F4"
    public static let pairingResponse = "D56446C2-AB92-43C6-B80F-BE5E964015B4"
    public static let pairingInfo = "BF903515-CC03-4056-A7D0-16E3267ABEB4"
}

public struct ControlCommand: Codable {
    public let sequence: UInt64
    public let quiet: Bool
    public let expiresAt: Int64
    public let targetMilli: Int?
    public let signature: String

    public init(sequence: UInt64, quiet: Bool, expiresAt: Int64, targetMilli: Int? = nil, key: Data) {
        self.sequence = sequence
        self.quiet = quiet
        self.expiresAt = expiresAt
        self.targetMilli = targetMilli
        signature = Authentication.sign("command|\(sequence)|\(quiet ? 1 : 0)|\(expiresAt)|\(targetMilli.map(String.init) ?? "-")", key: key)
    }

    public func valid(key: Data, now: Int64) -> Bool {
        expiresAt > now && expiresAt <= now + 30 && (targetMilli.map { (0...500).contains($0) } ?? true) &&
        Authentication.matches(signature, expected: Authentication.sign("command|\(sequence)|\(quiet ? 1 : 0)|\(expiresAt)|\(targetMilli.map(String.init) ?? "-")", key: key))
    }
}

public struct ControlAck: Codable {
    public let sequence: UInt64
    public let quiet: Bool
    public let result: String
    public let volumeMilli: Int
    public let targetMilli: Int
    public let signature: String

    public init(sequence: UInt64, quiet: Bool, result: String, volumeMilli: Int, targetMilli: Int, key: Data) {
        self.sequence = sequence
        self.quiet = quiet
        self.result = result
        self.volumeMilli = volumeMilli
        self.targetMilli = targetMilli
        signature = Authentication.sign("ack|\(sequence)|\(quiet ? 1 : 0)|\(result)|\(volumeMilli)|\(targetMilli)", key: key)
    }

    public func valid(key: Data) -> Bool {
        Authentication.matches(signature, expected: Authentication.sign("ack|\(sequence)|\(quiet ? 1 : 0)|\(result)|\(volumeMilli)|\(targetMilli)", key: key))
    }
}

public enum Authentication {
    public static func sign(_ message: String, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }

    public static func matches(_ supplied: String, expected: String) -> Bool {
        guard let a = Data(base64Encoded: supplied), let b = Data(base64Encoded: expected), a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

public struct QuietSnapshot: Codable {
    public let original: Float
    public let applied: Float
    public let route: String

    public init(original: Float, applied: Float, route: String) {
        self.original = original
        self.applied = applied
        self.route = route
    }
}

public enum VolumePolicy {
    public static func target(current: Float, configured: Float) -> Float? {
        guard current.isFinite, configured.isFinite, (0...1).contains(current), (0...1).contains(configured) else { return nil }
        return current > configured + 0.005 ? configured : nil
    }

    public static func restore(current: Float, route: String, snapshot: QuietSnapshot) -> Float? {
        guard current.isFinite, route == snapshot.route, abs(current - snapshot.applied) <= 0.005 else { return nil }
        return snapshot.original
    }
}

public enum InputSelectionPolicy {
    public static func activePIDs(_ identitiesByPID: [Int32: Set<String>], selected: Set<String>) -> Set<Int32> {
        Set(identitiesByPID.compactMap { pid, identities in
            identities.isDisjoint(with: selected) ? nil : pid
        })
    }
}
