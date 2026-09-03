import Foundation
import Security

enum KeychainStore {
    private static let service = "com.personal.OfflineTube"
    private static let adminAccount = "api-access-token"
    private static let deviceAccount = "device-access-token-v2"
    private static let installAccount = "device-install-id"
    private static let lyricsAccount = "lyrics-provider-api-key"

    static func saveToken(_ token: String) throws {
        try save(token, account: adminAccount)
    }

    static func saveDeviceToken(_ token: String) throws {
        try save(token, account: deviceAccount)
    }

    static func saveLyricsAPIKey(_ key: String) throws {
        try save(key, account: lyricsAccount)
    }

    private static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func token() -> String? {
        read(account: deviceAccount)
    }

    static func adminToken() -> String? {
        read(account: adminAccount)
    }

    static func installID() throws -> String {
        if let existing = read(account: installAccount), !existing.isEmpty { return existing }
        let value = UUID().uuidString.lowercased()
        try save(value, account: installAccount)
        return value
    }

    static func deleteDeviceToken() {
        delete(account: deviceAccount)
    }

    static func lyricsAPIKey() -> String? {
        read(account: lyricsAccount)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
