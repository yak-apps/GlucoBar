import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.glucobar.dexcom"

    enum Key: String {
        case username = "dexcom_username"
        case password = "dexcom_password"
        case region = "dexcom_region"
        case sessionId = "dexcom_session_id"
        case accountId = "dexcom_account_id"
    }

    @discardableResult
    static func save(_ value: String, for key: Key) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // Fallback to UserDefaults if Keychain fails
            UserDefaults.standard.set(value, forKey: "fallback.\(key.rawValue)")
            return true
        }
        return status == errSecSuccess
    }

    static func getValue(for key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess,
           let data = result as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        // Fallback to UserDefaults
        return UserDefaults.standard.string(forKey: "fallback.\(key.rawValue)")
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "fallback.\(key.rawValue)")
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func deleteAll() {
        for key in [Key.username, .password, .region, .sessionId, .accountId] {
            delete(key)
        }
    }

    static var hasCredentials: Bool {
        getValue(for: .username) != nil && getValue(for: .password) != nil
    }
}
