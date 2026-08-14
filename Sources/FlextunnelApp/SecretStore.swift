import Foundation
import Security

/// Stores the app's secrets in the iOS Keychain — encrypted, OS-managed
/// storage. Everything else (server node id, port) is non-sensitive and lives
/// in UserDefaults via @AppStorage.
///
/// Accessibility is `…AfterFirstUnlockThisDeviceOnly`: readable after the first
/// unlock following a boot (so it survives backgrounding), never synced to
/// iCloud, and never restored onto another device.
enum SecretStore {
    private static let account = "default"

    /// The named client auth keys — the whole list as one JSON blob of
    /// {id, name, secret} records (see `AuthKeyStore`). The derived public
    /// halves are not stored: each is re-derived via the FFI on load.
    static let authKeyService = "com.example.flextunnel.authKey"
    /// The shared bearer token for custom relays — a separate secret so it
    /// survives launches alongside the auth key (custom relays only).
    static let relayTokenService = "com.example.flextunnel.relayAuthToken"

    /// Persist `secret` under `service`, replacing any existing value. Empty
    /// strings are treated as a clear so we never store a blank secret.
    static func save(_ secret: String, service: String) {
        guard !secret.isEmpty, let data = secret.data(using: .utf8) else {
            clear(service: service)
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

    /// Read back the secret stored under `service`, or nil if none is set.
    static func load(service: String) -> String? {
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
              let secret = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return secret
    }

    /// Remove the secret stored under `service`.
    static func clear(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
