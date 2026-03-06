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
        // CareLink
        case clAccessToken  = "cl_access_token"
        case clRefreshToken = "cl_refresh_token"
        case clClientId     = "cl_client_id"
        case clClientSecret = "cl_client_secret"
        case clMagId        = "cl_mag_identifier"
        case clUsername     = "cl_username"
        case clCountry      = "cl_country"
        // FreeStyle Libre (LibreLinkUp)
        case libreEmail     = "libre_email"
        case librePassword  = "libre_password"
        case libreToken     = "libre_token"
        case libreHost      = "libre_host"
        case librePatientId = "libre_patient_id"
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

    static func deleteCareLinkCredentials() {
        for key in [Key.clAccessToken, .clRefreshToken, .clClientId, .clClientSecret,
                    .clMagId, .clUsername, .clCountry] {
            delete(key)
        }
    }

    static func deleteLibreCredentials() {
        for key in [Key.libreEmail, .librePassword, .libreToken, .libreHost, .librePatientId] {
            delete(key)
        }
        UserDefaults.standard.removeObject(forKey: "libreTokenExpiry")
    }

    static var hasCredentials: Bool {
        getValue(for: .username) != nil && getValue(for: .password) != nil
    }

    static var hasCareLinkCredentials: Bool {
        getValue(for: .clAccessToken) != nil && getValue(for: .clUsername) != nil
    }

    static var hasLibreCredentials: Bool {
        getValue(for: .libreToken) != nil && getValue(for: .libreEmail) != nil
    }

    // MARK: - CGM Source (UserDefaults, not sensitive)

    static var cgmSource: CGMSource {
        get {
            if let raw = UserDefaults.standard.string(forKey: "cgmSource"),
               let source = CGMSource(rawValue: raw) {
                return source
            }
            return .dexcom
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cgmSource")
        }
    }

    static var hasCGMSourceSelected: Bool {
        UserDefaults.standard.string(forKey: "cgmSource") != nil
    }
}
