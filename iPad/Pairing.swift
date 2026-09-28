import Foundation
import Security

enum PairingStore {
    private static let peersAccount = "ShenglinPairedPeersV3"
    private static let pendingAccount = "ShenglinPendingPeerV3"
    private struct Pending: Codable { let key: Data; let expiresAt: Date; let name: String? }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) throws -> Data? {
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

    private static func save(_ data: Data, account: String) throws {
        var entry = query(account)
        // Background BLE can use the key while locked after the first unlock; it never leaves this iPad.
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        entry[kSecValueData as String] = data
        let status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(query(account) as CFDictionary,
                                        [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func all() throws -> [PairedPeer] {
        guard let data = try read(peersAccount) else { return [] }
        let peers = try JSONDecoder().decode([PairedPeer].self, from: data)
        guard peers.allSatisfy({ $0.key.count == 32 && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(peers.map(\.key)).count == peers.count
        else { throw PairingError.invalidMessage }
        return peers
    }

    static func updateName(_ key: Data, name: String) throws {
        var peers = try all()
        guard let index = peers.firstIndex(where: { $0.key == key }) else { throw PairingError.invalidMessage }
        peers[index].name = PeerName.display(name, fallback: "Mac")
        try save(JSONEncoder().encode(peers), account: peersAccount)
    }

    static func pending() throws -> Data? {
        guard let data = try read(pendingAccount) else { return nil }
        let record = try JSONDecoder().decode(Pending.self, from: data)
        guard record.key.count == 32 else { throw PairingError.invalidMessage }
        if record.expiresAt <= Date() {
            try delete(pendingAccount)
            return nil
        }
        return record.key
    }

    static func stage(_ key: Data, name: String = "Mac") throws {
        guard key.count == 32 else { throw PairingError.invalidMessage }
        try save(JSONEncoder().encode(Pending(key: key, expiresAt: Date().addingTimeInterval(300),
                                            name: PeerName.display(name, fallback: "Mac"))),
                 account: pendingAccount)
    }

    static func promotePending() throws -> Data {
        guard let data = try read(pendingAccount) else { throw PairingError.expired }
        let pending = try JSONDecoder().decode(Pending.self, from: data)
        guard pending.expiresAt > Date(), pending.key.count == 32 else { throw PairingError.expired }
        var peers = try all()
        if !peers.contains(where: { $0.key == pending.key }) {
            peers.append(try PairedPeer(key: pending.key,
                                        name: PeerName.display(pending.name, fallback: "Mac"),
                                        platform: .mac, localRole: .responder))
        }
        try save(JSONEncoder().encode(peers), account: peersAccount)
        try? delete(pendingAccount)
        return pending.key
    }

    static func clearPending() throws { try delete(pendingAccount) }
}
