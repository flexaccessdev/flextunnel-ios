import Foundation
import Security

/// Stores the proxy auth token in the iOS Keychain — encrypted, OS-managed
/// storage for the one real secret in the app. Everything else (server node id,
/// port) is non-sensitive and lives in UserDefaults via @AppStorage.
///
/// Accessibility is `…AfterFirstUnlockThisDeviceOnly`: readable after the first
/// unlock following a boot (so it survives backgrounding), never synced to
/// iCloud, and never restored onto another device.
enum TokenStore {
    private static let service = "com.example.flextunnel.authToken"
    private static let account = "default"

    /// Persist `token`, replacing any existing value. Empty strings are treated
    /// as a clear so we never store a blank secret.
    static func save(_ token: String) {
        guard !token.isEmpty, let data = token.data(using: .utf8) else {
            clear()
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    /// Read back the stored token, or nil if none is set.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return token
    }

    /// Remove the stored token.
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
