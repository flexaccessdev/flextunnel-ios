import Foundation
import Security

/// Stores the app's secrets in the iOS Keychain — encrypted, OS-managed
/// storage. Everything else (profile names, server node ids, relay URLs,
/// forwards) is non-sensitive and lives in plain JSON via `JSONStore`, or in
/// UserDefaults via @AppStorage.
///
/// Accessibility is `…AfterFirstUnlockThisDeviceOnly`: readable after the first
/// unlock following a boot (so it survives backgrounding), never synced to
/// iCloud, and never restored onto another device.
enum SecretStore {
    /// The account for secrets there is only ever one of. Per-profile secrets
    /// pass the profile id instead, so each profile keeps its own.
    static let defaultAccount = "default"

    /// The named client auth keys — the whole list as one JSON blob of
    /// {id, name, secret} records (see `AuthKeyStore`). The derived public
    /// halves are not stored: each is re-derived via the FFI on load. One
    /// shared list, so several profiles can authenticate with the same keypair.
    static let authKeyService = "com.example.flextunnel.authKey"
    /// The bearer token for custom relays, stored per profile: the account is
    /// the profile id (custom relays only).
    static let relayTokenService = "com.example.flextunnel.relayAuthToken"

    /// Persist `secret` under `service`/`account`, replacing any existing
    /// value. Empty strings are treated as a clear so we never store a blank
    /// secret. Returns the Keychain status, so callers that must not silently
    /// lose a secret can report a failed write.
    @discardableResult
    static func save(
        _ secret: String, service: String, account: String = defaultAccount
    ) -> OSStatus {
        guard !secret.isEmpty, let data = secret.data(using: .utf8) else {
            let status = clear(service: service, account: account)
            // Nothing stored is the intended end state of a clear.
            return status == errSecItemNotFound ? errSecSuccess : status
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
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status
    }

    /// Read back the secret stored under `service`/`account`, or nil if none
    /// is set.
    static func load(service: String, account: String = defaultAccount) -> String? {
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

    /// Remove the secret stored under `service`/`account`.
    @discardableResult
    static func clear(service: String, account: String = defaultAccount) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
