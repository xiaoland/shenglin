import Foundation
import Security

enum PairingStore {
    private static let currentAccount = "NearbyAudioPairingKey" // Also used by the original version.
    private static let pendingAccount = "NearbyAudioPendingPairingKey"
    private struct Pending: Codable { let key: Data; let expiresAt: Date }

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
        guard let key = try read(currentAccount) else { return nil }
        guard key.count == 32 else { throw PairingError.invalidMessage }
        return key
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

    static func stage(_ key: Data) throws {
        guard key.count == 32 else { throw PairingError.invalidMessage }
        try save(JSONEncoder().encode(Pending(key: key, expiresAt: Date().addingTimeInterval(300))),
                 account: pendingAccount)
    }

    static func promotePending() throws -> Data {
        guard let key = try pending() else { throw PairingError.expired }
        try save(key, account: currentAccount)
        try? delete(pendingAccount)
        return key
    }

    static func clearPending() throws { try delete(pendingAccount) }
}
