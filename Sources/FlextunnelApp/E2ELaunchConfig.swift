#if DEBUG
import Foundation

/// Debug-only hook for the UI tests (`ci/e2e.sh`): when the launch environment
/// names destinations and a client secret, the setup screen is pointed at them
/// — an "E2E" auth key, picked, and exactly those destinations — so a test can
/// tap the CTA instead of typing node ids and pasting a key — and every launch
/// starts with an empty library, so one test's visits and bookmarks don't leak
/// into the next. Release builds never compile it.
enum E2ELaunchConfig {
    static let name = "E2E"

    /// One destination as the test passes it, in the FFI's own spelling.
    struct Destination: Decodable {
        var host: String
        var serverNodeID: String
        var routedDomains: [String]
        var routedCIDRs: [String]

        private enum CodingKeys: String, CodingKey {
            case host
            case serverNodeID = "server_node_id"
            case routedDomains = "routed_domains"
            case routedCIDRs = "routed_cidrs"
        }
    }

    struct Values {
        var destinations: [Destination]
        var authSecret: String
        var relayURLs: String
    }

    /// `FLEXTUNNEL_E2E_DESTINATIONS` is a JSON array of
    /// `{host, server_node_id, routed_domains, routed_cidrs}`.
    static var current: Values? {
        let env = ProcessInfo.processInfo.environment
        guard let json = env["FLEXTUNNEL_E2E_DESTINATIONS"], !json.isEmpty,
              let secret = env["FLEXTUNNEL_E2E_AUTH_SECRET"], !secret.isEmpty else { return nil }
        guard let destinations = try? JSONDecoder().decode([Destination].self, from: Data(json.utf8)) else {
            fatalError("FLEXTUNNEL_E2E_DESTINATIONS is not a destination list: \(json)")
        }
        return Values(
            destinations: destinations,
            authSecret: secret,
            relayURLs: env["FLEXTUNNEL_E2E_RELAY_URLS"] ?? "")
    }

    /// Seeds and picks the E2E key, and replaces the destinations. The
    /// simulator's Keychain outlives an uninstall, so a key left by an earlier
    /// run is reused when it holds the same secret and replaced when it doesn't
    /// (each run generates a fresh keypair).
    @MainActor
    static func apply(_ values: Values, client: ClientStore, authKeys: AuthKeyStore, library: BrowserLibrary) {
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

        client.authKeyID = key.id
        client.relayURLs = values.relayURLs
        client.destinations.map(\.id).forEach(client.delete)
        for destination in values.destinations {
            let saved = client.save(ClientStore.Destination(
                id: UUID().uuidString,
                host: destination.host,
                serverNodeID: destination.serverNodeID,
                routedDomains: destination.routedDomains,
                routedCIDRs: destination.routedCIDRs))
            if let error = saved {
                fatalError("E2E destination \(destination.host) rejected: \(error.message)")
            }
        }
    }
}
#endif
