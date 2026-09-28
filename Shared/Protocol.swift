import CryptoKit
import Foundation

// These UUIDs are the BLE wire contract shared by the Mac and iPad targets.
public enum BLEIdentifiers {
    public static let service = "8A27D37F-A94F-4A53-AD7C-0D48CC8108CF"
    public static let command = "E1FA496A-299F-4C84-9621-63396F75A3F2"
    public static let ack = "0F20B426-BBC9-48A4-A518-82827239AA9E"
    public static let peerState = "1AD254E9-97D9-443F-AB4B-C815B92CD364"
    public static let peerAckWrite = "51BCDB25-1849-480E-9512-2E41A2E52622"
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

public enum InputExclusionPolicy {
    public static func activePIDs(_ identitiesByPID: [Int32: Set<String>], excluded: Set<String>) -> Set<Int32> {
        Set(identitiesByPID.compactMap { pid, identities in
            identities.isDisjoint(with: excluded) ? pid : nil
        })
    }
}

public enum InputExclusionStore {
    private struct Configuration: Codable { let excluded: [String] }
    private struct LegacyConfiguration: Decodable { let selected: [String] }

    public static func load(at url: URL, legacyURL: URL) throws -> Set<String> {
        if FileManager.default.fileExists(atPath: url.path) {
            return Set(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)).excluded)
        }
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            // Old selections were permissions, not exclusions; never invert their meaning.
            _ = try JSONDecoder().decode(LegacyConfiguration.self, from: Data(contentsOf: legacyURL))
            try save([], at: url)
        }
        return []
    }

    public static func change(_ selector: String, add: Bool, at url: URL, legacyURL: URL) throws {
        var excluded = try load(at: url, legacyURL: legacyURL)
        if add { excluded.insert(selector) } else { excluded.remove(selector) }
        try save(excluded, at: url)
    }

    private static func save(_ excluded: Set<String>, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Configuration(excluded: excluded.sorted())).write(to: url, options: .atomic)
    }
}

public enum InputMuteStore {
    private struct Configuration: Codable { let muted: [String] }

    public static func load(at url: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)).muted)
    }

    public static func change(_ selector: String, add: Bool, at url: URL) throws {
        var muted = try load(at: url)
        if add { muted.insert(selector) } else { muted.remove(selector) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Configuration(muted: muted.sorted())).write(to: url, options: .atomic)
    }
}

/// 用户显式分配的专用输入设备；应用重启或改名不会改变设备 UID。
public struct DedicatedMicrophone: Codable, Equatable {
    public let bundle: String
    public let name: String
    public let sourceUID: String?
    public let sampleRate: Int?
    public let channels: Int?
    public var selector: String { "bundle:\(bundle)" }
    public var uid: String { "local.nearbyaudio.virtual-microphone.\(bundle)" }
    public var deviceName: String { "Nearby · \(name)" }
    public var outputSampleRate: Int { sampleRate ?? 48000 }
    public var outputChannels: Int { channels ?? 2 }

    public init(bundle: String, name: String, sourceUID: String? = nil,
                sampleRate: Int? = nil, channels: Int? = nil) {
        self.bundle = bundle
        self.name = name
        self.sourceUID = sourceUID
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public enum DedicatedMicrophoneStore {
    public static func validate(_ devices: [DedicatedMicrophone]) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard devices.count <= 32, Set(devices.map(\.bundle)).count == devices.count,
              devices.allSatisfy({ !$0.bundle.isEmpty && $0.bundle.utf8.count <= 255 &&
                  $0.bundle.unicodeScalars.allSatisfy(allowed.contains) &&
                  !$0.name.isEmpty && $0.name.utf8.count <= 160 && !$0.name.contains("\0") &&
                  ($0.sourceUID == nil || (!$0.sourceUID!.isEmpty && $0.sourceUID!.utf8.count <= 255)) &&
                  ($0.sampleRate == nil && $0.channels == nil ||
                   $0.sampleRate != nil && $0.channels != nil &&
                   (8000...192000).contains($0.sampleRate!) && (1...2).contains($0.channels!)) }) else {
            throw NSError(domain: "NearbyAudio", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "专用麦克风配置无效（最多 32 个，应用标识不得重复）"])
        }
    }

    public static func load(at url: URL) throws -> [DedicatedMicrophone] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let devices = try JSONDecoder().decode([DedicatedMicrophone].self, from: Data(contentsOf: url))
        try validate(devices)
        return devices
    }

    public static func save(_ devices: [DedicatedMicrophone], at url: URL) throws {
        try validate(devices)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(devices.sorted { $0.bundle < $1.bundle }).write(to: url, options: .atomic)
    }
}

public enum DedicatedInputPolicy {
    /// 只有进程的全部活动输入都已静音时，才从协同来源中移除该进程。
    public static func mutedPIDs(_ inputs: [Int32: Set<UInt32>], mutedDevices: Set<UInt32>) -> Set<Int32> {
        Set(inputs.compactMap { pid, devices in
            !devices.isEmpty && devices.isSubset(of: mutedDevices) ? pid : nil
        })
    }
}
