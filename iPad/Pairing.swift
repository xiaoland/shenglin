import Foundation
import Security

enum PairingStore {
    private static let account = "NearbyAudioPairingKey"

    static func loadOrCreate() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data, key.count == 32 { return key }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(randomStatus)) }
        var entry = query
        entry.removeValue(forKey: kSecReturnData as String)
        entry.removeValue(forKey: kSecMatchLimit as String)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        entry[kSecValueData as String] = key
        let saveStatus = SecItemAdd(entry as CFDictionary, nil)
        guard saveStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(saveStatus)) }
        return key
    }
}
