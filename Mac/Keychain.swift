import Foundation
import Security
#if canImport(ShenglinCore)
import ShenglinCore
#endif

enum MacPreferences {
    static let defaults = UserDefaults(suiteName: "local.shenglin.preferences")!
}

enum MacCredentials {
    private static let service = "local.shenglin.mac"
    private static let peersAccount = "pairedPeersV3"
    private static let pendingAccount = "pendingPeerV3"
    private static let pendingMacAccount = "pendingMacPeersV3"
    private struct Pending: Codable {
        let key: Data
        let expiresAt: Date
        let name: String?
        let peripheralID: UUID?
    }
    private struct PendingMac: Codable {
        var peer: PairedPeer
        let expiresAt: Date
    }
    static func peers() throws -> [PairedPeer] {
        guard let data = try read(peersAccount) else { return [] }
        let peers = try JSONDecoder().decode([PairedPeer].self, from: data)
        guard peers.allSatisfy({ $0.key.count == 32 && !PeerName.display($0.name, fallback: "").isEmpty }),
              Set(peers.map(\.key)).count == peers.count else {
            throw PairingError.invalidMessage
        }
        return peers
    }

    static func addPeer(key: Data, name: String, platform: PeerPlatform, localRole: PeerRole,
                        peripheralID: UUID? = nil) throws {
        let peer = try PairedPeer(key: key, name: name, platform: platform,
                                  localRole: localRole, peripheralID: peripheralID)
        var records = try peers()
        if let index = records.firstIndex(where: { $0.key == key }) { records[index] = peer }
        else { records.append(peer) }
        try save(JSONEncoder().encode(records), account: peersAccount)
    }

    static func pendingMacPeers() throws -> [PairedPeer] {
        guard let data = try read(pendingMacAccount) else { return [] }
        let records = try JSONDecoder().decode([PendingMac].self, from: data)
        let savedKeys = Set(try peers().map(\.key))
        let active = records.filter { $0.expiresAt > Date() && !savedKeys.contains($0.peer.key) }
        guard active.allSatisfy({ $0.peer.platform == .mac && $0.peer.key.count == 32 }) else {
            throw PairingError.invalidMessage
        }
        if active.count != records.count { try save(JSONEncoder().encode(active), account: pendingMacAccount) }
        return active.map(\.peer)
    }

    static func stageMacPeer(key: Data, name: String, localRole: PeerRole) throws {
        let peer = try PairedPeer(key: key, name: name, platform: .mac, localRole: localRole)
        let data = try read(pendingMacAccount)
        var records = try data.map { try JSONDecoder().decode([PendingMac].self, from: $0) } ?? []
        records.removeAll { $0.peer.key == key || $0.expiresAt <= Date() }
        records.append(PendingMac(peer: peer, expiresAt: Date().addingTimeInterval(300)))
        try save(JSONEncoder().encode(records), account: pendingMacAccount)
    }

    static func promoteMacPeer(_ key: Data) throws {
        guard let data = try read(pendingMacAccount) else { throw PairingError.expired }
        var records = try JSONDecoder().decode([PendingMac].self, from: data)
        guard let record = records.first(where: { $0.peer.key == key && $0.expiresAt > Date() })
        else { throw PairingError.expired }
        try addPeer(key: key, name: record.peer.name, platform: .mac,
                    localRole: record.peer.localRole)
        records.removeAll { $0.peer.key == key }
        try save(JSONEncoder().encode(records), account: pendingMacAccount)
    }

    static func updatePadPeripheralID(_ key: Data, peripheralID: UUID) throws {
        var peers = try peers()
        guard let index = peers.firstIndex(where: { $0.key == key }) else { return }
        peers[index].peripheralID = peripheralID
        try save(JSONEncoder().encode(peers), account: peersAccount)
    }

    static func updatePadName(_ key: Data, name: String) throws {
        try updatePeerName(key, name: name)
    }

    static func updatePeerName(_ key: Data, name: String) throws {
        var peers = try peers()
        if let index = peers.firstIndex(where: { $0.key == key }) {
            peers[index].name = PeerName.display(name, fallback: peers[index].platform == .mac ? "Mac" : "iPad")
            try save(JSONEncoder().encode(peers), account: peersAccount)
            return
        }
        guard let data = try read(pendingMacAccount) else { throw PairingError.invalidMessage }
        var pending = try JSONDecoder().decode([PendingMac].self, from: data)
        guard let index = pending.firstIndex(where: { $0.peer.key == key }) else { throw PairingError.invalidMessage }
        pending[index].peer.name = PeerName.display(name, fallback: "Mac")
        try save(JSONEncoder().encode(pending), account: pendingMacAccount)
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
        try addPeer(key: key, name: name, platform: .ipad, localRole: .initiator,
                    peripheralID: peripheralID)
        try? delete(pendingAccount)
    }

    static func clearPendingPairing() throws { try delete(pendingAccount) }

    static func nextSequence() -> UInt64 {
        // The sequence is not secret; only the pairing key belongs in Keychain.
        let preferences = MacPreferences.defaults
        let saved = preferences.string(forKey: "peerSequenceV3").flatMap(UInt64.init) ?? 0
        let clock = UInt64(Date().timeIntervalSince1970 * 1000)
        let next = max(clock, saved + 1)
        preferences.set(String(next), forKey: "peerSequenceV3")
        preferences.synchronize()
        return next
    }
}
