import Foundation
import Security

enum KeychainStore {
    private static let service = "com.vauth.foxyvpn.macos"
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load(account: String = "firefox-oauth") throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return value as? Data
    }

    static func save(_ data: Data, account: String = "firefox-oauth") throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account: account)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(account: String = "firefox-oauth") throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Связка ключей: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"
    }
}
