import Foundation
import Security

enum PairingStore {
    private static let currentAccount = "NearbyAudioPairingKey" // Also used by the original version.
    private static let peersAccount = "NearbyAudioPairedMacs"
    private static let pendingAccount = "NearbyAudioPendingPairingKey"
    struct PairedMac: Codable { let key: Data; let name: String }
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

    static func current() throws -> Data? {
        try all().last?.key
    }

    static func all() throws -> [PairedMac] {
        if let data = try read(peersAccount) {
            let peers = try JSONDecoder().decode([PairedMac].self, from: data)
            guard peers.allSatisfy({ $0.key.count == 32 }) else { throw PairingError.invalidMessage }
            return peers
        }
        guard let key = try read(currentAccount) else { return [] }
        guard key.count == 32 else { throw PairingError.invalidMessage }
        return [PairedMac(key: key, name: "Mac（名称未知）")]
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
        try save(JSONEncoder().encode(Pending(key: key, expiresAt: Date().addingTimeInterval(300), name: name)),
                 account: pendingAccount)
    }

    static func promotePending() throws -> Data {
        guard let data = try read(pendingAccount) else { throw PairingError.expired }
        let pending = try JSONDecoder().decode(Pending.self, from: data)
        guard pending.expiresAt > Date(), pending.key.count == 32 else { throw PairingError.expired }
        var peers = try all()
        if !peers.contains(where: { $0.key == pending.key }) {
            peers.append(PairedMac(key: pending.key, name: pending.name ?? "Mac"))
        }
        try save(JSONEncoder().encode(peers), account: peersAccount)
        try? delete(pendingAccount)
        return pending.key
    }

    static func clearPending() throws { try delete(pendingAccount) }
}
