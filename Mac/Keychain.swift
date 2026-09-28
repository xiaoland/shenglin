import Foundation
import Security
#if canImport(NearbyAudioCore)
import NearbyAudioCore
#endif

enum MacPreferences {
    static let defaults = UserDefaults(suiteName: "local.nearbyaudio.preferences")!
}

enum MacCredentials {
    private static let service = "local.nearbyaudio.mac"
    private static let pendingAccount = "pendingPairingKey"
    private struct Pending: Codable {
        let key: Data
        let expiresAt: Date
        let name: String?
        let peripheralID: UUID?
    }
    struct PadPeer: Codable {
        let key: Data
        let name: String
        let peripheralID: UUID?
    }
    struct MacPeer: Codable {
        let key: Data
        let name: String
        let isInitiator: Bool
    }

    static func macPeers() throws -> [MacPeer] {
        guard let data = try read("pairedMacs") else { return [] }
        let peers = try JSONDecoder().decode([MacPeer].self, from: data)
        guard peers.allSatisfy({ $0.key.count == 32 }) else { throw PairingError.invalidMessage }
        let normalized = peers.map { MacPeer(key: $0.key,
                                             name: PeerName.display($0.name, fallback: "Mac"),
                                             isInitiator: $0.isInitiator) }
        if zip(peers, normalized).contains(where: { $0.0.name != $0.1.name }) {
            try save(JSONEncoder().encode(normalized), account: "pairedMacs")
        }
        return normalized
    }

    static func addMacPeer(key: Data, name: String, isInitiator: Bool) throws {
        guard key.count == 32 else { throw PairingError.invalidMessage }
        var peers = try macPeers()
        if !peers.contains(where: { $0.key == key }) {
            peers.append(MacPeer(key: key, name: PeerName.display(name, fallback: "Mac"),
                                 isInitiator: isInitiator))
            try save(JSONEncoder().encode(peers), account: "pairedMacs")
        }
    }

    static func padPeers() throws -> [PadPeer] {
        if let data = try read("pairedPads") {
            let peers = try JSONDecoder().decode([PadPeer].self, from: data)
            guard peers.allSatisfy({ $0.key.count == 32 }) else { throw PairingError.invalidMessage }
            let normalized = peers.map { PadPeer(key: $0.key, name: PeerName.display($0.name, fallback: "iPad"),
                                                 peripheralID: $0.peripheralID) }
            if zip(peers, normalized).contains(where: { $0.0.name != $0.1.name }) {
                try save(JSONEncoder().encode(normalized), account: "pairedPads")
            }
            return normalized
        }
        guard let key = try read("pairingKey") else { return [] }
        guard key.count == 32 else { throw PairingError.invalidMessage }
        let preferences = MacPreferences.defaults
        let name = preferences.string(forKey: "pairedPadIdentity") == Authentication.sign("paired-peer-id", key: key)
            ? preferences.string(forKey: "pairedPadName") : nil
        let peers = [PadPeer(key: key, name: PeerName.display(name, fallback: "iPad"), peripheralID: nil)]
        try save(JSONEncoder().encode(peers), account: "pairedPads")
        return peers
    }

    static func updatePadPeripheralID(_ key: Data, peripheralID: UUID) throws {
        var peers = try padPeers()
        guard let index = peers.firstIndex(where: { $0.key == key }) else { return }
        peers[index] = PadPeer(key: key, name: peers[index].name, peripheralID: peripheralID)
        try save(JSONEncoder().encode(peers), account: "pairedPads")
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    static func save(_ data: Data, account: String) throws {
        var entry = query(account)
        entry[kSecValueData as String] = data
        let status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updated = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func pendingPairing() throws -> (key: Data, expiresAt: Date, name: String?, peripheralID: UUID?)? {
        guard let data = try read(pendingAccount) else { return nil }
        let pending = try JSONDecoder().decode(Pending.self, from: data)
        guard pending.key.count == 32 else { throw PairingError.invalidMessage }
        if pending.expiresAt <= Date() {
            try delete(pendingAccount)
            return nil
        }
        return (pending.key, pending.expiresAt, pending.name, pending.peripheralID)
    }

    static func stagePairing(_ key: Data, name: String, peripheralID: UUID) throws -> Date {
        guard key.count == 32 else { throw PairingError.invalidMessage }
        let deadline = Date().addingTimeInterval(300)
        try save(JSONEncoder().encode(Pending(key: key, expiresAt: deadline,
                                             name: PeerName.display(name, fallback: "iPad"),
                                             peripheralID: peripheralID)), account: pendingAccount)
        return deadline
    }

    static func promotePairing(_ key: Data, name: String, peripheralID: UUID?) throws {
        guard let pending = try pendingPairing(), pending.key == key else { throw PairingError.expired }
        var peers = try padPeers()
        let peer = PadPeer(key: key, name: PeerName.display(name, fallback: "iPad"), peripheralID: peripheralID)
        if let index = peers.firstIndex(where: { $0.key == key }) { peers[index] = peer }
        else { peers.append(peer) }
        try save(JSONEncoder().encode(peers), account: "pairedPads")
        try save(key, account: "pairingKey")
        try? delete(pendingAccount)
    }

    static func clearPendingPairing() throws { try delete(pendingAccount) }

    static func nextSequence() -> UInt64 {
        // The sequence is not secret; only the pairing key belongs in Keychain.
        let preferences = MacPreferences.defaults
        let saved = preferences.string(forKey: "sequence").flatMap(UInt64.init) ?? 0
        let clock = UInt64(Date().timeIntervalSince1970 * 1000)
        let next = max(clock, saved + 1)
        preferences.set(String(next), forKey: "sequence")
        preferences.synchronize()
        return next
    }
}
