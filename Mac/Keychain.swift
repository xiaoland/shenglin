import Foundation
import Security

enum MacPreferences {
    static let defaults = UserDefaults(suiteName: "local.nearbyaudio.preferences")!
}

enum MacCredentials {
    private static let service = "local.nearbyaudio.mac"

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
