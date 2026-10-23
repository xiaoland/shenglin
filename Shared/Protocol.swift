#if canImport(ShenglinRust)
import ShenglinRust
#endif
import Foundation

// These UUIDs are the BLE wire contract shared by the Mac and iPad targets.
public enum BLEIdentifiers {
    public static let service = "8A27D37F-A94F-4A53-AD7C-0D48CC8108CF"
    public static let stateWrite = "E1FA496A-299F-4C84-9621-63396F75A3F2"
    public static let stateAck = "0F20B426-BBC9-48A4-A518-82827239AA9E"
    public static let peerState = "1AD254E9-97D9-443F-AB4B-C815B92CD364"
    public static let peerAckWrite = "51BCDB25-1849-480E-9512-2E41A2E52622"
    public static let pairingService = "C985D59E-9D34-4F37-8F14-03C942690C78"
    public static let pairingWrite = "01FA287F-9E5C-4A8A-8B58-23A9808981F4"
    public static let pairingResponse = "D56446C2-AB92-43C6-B80F-BE5E964015B4"
    public static let pairingInfo = "BF903515-CC03-4056-A7D0-16E3267ABEB4"
}

public enum BLEAttributeWrite {
    /// One ATT write transaction must contain a contiguous value no larger than the protocol frame limit.
    public static func assemble(_ fragments: [(offset: Int, value: Data)]) -> Data? {
        guard !fragments.isEmpty else { return nil }
        var data = Data()
        for fragment in fragments {
            guard fragment.offset == data.count, data.count + fragment.value.count <= 512 else { return nil }
            data.append(fragment.value)
        }
        return data
    }
}

public enum Authentication {
    public static func sign(_ message: String, key: Data) -> String {
        authenticationSign(message: message, key: key)
    }

    public static func matches(_ supplied: String, expected: String) -> Bool {
        authenticationMatches(supplied: supplied, expected: expected)
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

private let rustRemoteDuckingAllowed = remoteDuckingAllowed
private let rustQuietTarget = quietTarget

public enum VolumePolicy {
    // iPad yields its category-volume control whenever local input may need that output.
    public static func remoteDuckingAllowed(hasDemand: Bool, localRecording: Bool?, manual: Bool) -> Bool {
        rustRemoteDuckingAllowed(hasDemand, localRecording, manual)
    }

    public static func outputGain(identities: Set<String>, protected: Set<String>,
                                  browser: Bool, requested: Float?) -> Float {
        guard !browser, !identities.isEmpty, identities.isDisjoint(with: protected),
              let requested, requested.isFinite, (0...1).contains(requested) else { return 1 }
        return requested
    }

    public static func quietTarget(local: Float?, remote: Float?) -> Float? {
        rustQuietTarget(local, remote)
    }

    public static func target(current: Float, configured: Float) -> Float? {
        volumeTarget(current: current, configured: configured)
    }

    public static func restore(current: Float, route: String, snapshot: QuietSnapshot) -> Float? {
        volumeRestore(current: current, route: route, original: snapshot.original,
                      applied: snapshot.applied, originalRoute: snapshot.route)
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
public struct RemoteMicrophoneSource: Codable, Hashable {
    public let peerID: String
    public let sourceID: String
    public init(peerID: String, sourceID: String) { self.peerID = peerID; self.sourceID = sourceID }
    public var valid: Bool {
        peerID.hasPrefix("Shenglin-") && peerID.count == 25 &&
        peerID.dropFirst(9).allSatisfy { $0.isHexDigit } &&
        !sourceID.isEmpty && sourceID.utf8.count <= 512 && !sourceID.contains("\0")
    }
}

public struct PeerMicrophone: Codable, Identifiable {
    public let id: String
    public let name: String
    public let sampleRate: Int
    public let channels: Int
}

public struct DedicatedMicrophone: Codable, Equatable {
    public let bundle: String
    public let name: String
    public let sourceUID: String?
    public let sampleRate: Int?
    public let channels: Int?
    public let remoteSource: RemoteMicrophoneSource?
    public var selector: String { "bundle:\(bundle)" }
    public var uid: String { "local.shenglin.virtual-microphone.\(bundle)" }
    public var deviceName: String { "声邻 · \(name)" }
    public var outputSampleRate: Int { sampleRate ?? 48000 }
    public var outputChannels: Int { channels ?? 2 }

    public init(bundle: String, name: String, sourceUID: String? = nil,
                sampleRate: Int? = nil, channels: Int? = nil, remoteSource: RemoteMicrophoneSource? = nil) {
        self.bundle = bundle
        self.name = name
        self.sourceUID = sourceUID
        self.sampleRate = sampleRate
        self.channels = channels
        self.remoteSource = remoteSource
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
                  ($0.remoteSource == nil || ($0.sourceUID == nil && $0.remoteSource!.valid &&
                    $0.outputSampleRate == 48000 && $0.outputChannels == 1)) &&
                  ($0.sampleRate == nil && $0.channels == nil ||
                   $0.sampleRate != nil && $0.channels != nil &&
                   (8000...192000).contains($0.sampleRate!) && (1...2).contains($0.channels!)) }) else {
            throw NSError(domain: "Shenglin", code: 3,
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

// Codable is the native transport/storage boundary; Rust owns each protocol schema.
// Preserve integer precision while forwarding an enclosing Encoder/Decoder to the core JSON codec.
private indirect enum RustWireJSON: Codable {
    case object([String: RustWireJSON]), array([RustWireJSON]), string(String)
    case unsigned(UInt64), signed(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? value.decode(Int64.self) { self = .signed(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: RustWireJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([RustWireJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .unsigned(let v): try value.encode(v)
        case .signed(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}

func decodeRustWire<T>(_ decoder: Decoder, using decode: (String) throws -> T) throws -> T {
    let json = try JSONEncoder().encode(RustWireJSON(from: decoder))
    return try decode(String(decoding: json, as: UTF8.self))
}
func encodeRustWire(_ json: String, to encoder: Encoder) throws {
    try JSONDecoder().decode(RustWireJSON.self, from: Data(json.utf8)).encode(to: encoder)
}
