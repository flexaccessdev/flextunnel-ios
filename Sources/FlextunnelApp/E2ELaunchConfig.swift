#if DEBUG
import Foundation

/// Debug-only hook for the UI tests (`ci/e2e.sh`): when the launch environment
/// names a server and a client secret, the setup screen is pointed at them —
/// an "E2E" auth key and profile, selected — so a test can tap the CTA instead
/// of typing a node id and pasting a key — and every launch starts with an
/// empty library, so one test's visits and bookmarks don't leak into the next.
/// Release builds never compile it.
enum E2ELaunchConfig {
    static let name = "E2E"

    struct Values {
        var serverNodeID: String
        var authSecret: String
        var relayURLs: String
    }

    static var current: Values? {
        let env = ProcessInfo.processInfo.environment
        guard let node = env["FLEXTUNNEL_E2E_SERVER_NODE_ID"], !node.isEmpty,
              let secret = env["FLEXTUNNEL_E2E_AUTH_SECRET"], !secret.isEmpty else { return nil }
        return Values(serverNodeID: node, authSecret: secret, relayURLs: env["FLEXTUNNEL_E2E_RELAY_URLS"] ?? "")
    }

    /// Seeds and selects the E2E key and profile. The simulator's Keychain
    /// outlives an uninstall, so a key left by an earlier run is reused when it
    /// holds the same secret and replaced when it doesn't (each run generates
    /// a fresh keypair).
    @MainActor
    static func apply(_ values: Values, profiles: ProfileStore, authKeys: AuthKeyStore, library: BrowserLibrary) {
        library.clearHistory()
        library.bookmarks.forEach(library.removeBookmark)

        let publicKey = AuthKey.publicKey(forSecret: values.authSecret)
        for stale in authKeys.keys where stale.name == name && stale.publicKey != publicKey {
            _ = authKeys.delete(id: stale.id)
        }
        let key: AuthKeyStore.Key
        if let existing = authKeys.keys.first(where: { $0.publicKey == publicKey }) {
            key = existing
        } else {
            switch authKeys.add(name: name, secret: values.authSecret) {
            case .success(let added): key = added
            case .failure(let error): fatalError("E2E auth key rejected: \(error.message)")
            }
        }

        if let existing = profiles.profiles.first(where: { $0.name == name }) {
            profiles.selectedID = existing.id
        } else if case .failure(let error) = profiles.add(name: name) {
            fatalError("E2E profile rejected: \(error.message)")
        }
        var profile = profiles.selected
        profile.serverNodeID = values.serverNodeID
        profile.authKeyID = key.id
        profile.relayURLs = values.relayURLs
        profiles.selected = profile
    }
}
#endif
