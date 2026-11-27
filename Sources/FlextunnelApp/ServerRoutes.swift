import Foundation

/// What a server routes — its own domain and IP-range lists — asked of the
/// server itself through the Rust FFI (`flextunnel_fetch_server_routes`).
///
/// A destination is only useful for what both sides carry: the client sends
/// what the destination lists, and the server allows what its own lists hold.
/// This reads the server's half so a destination's editor can offer it. It is
/// one connection made for the question and closed again, apart from any
/// session, so it works for a destination that is not saved yet; the server
/// has to authorize the client's key already, as for any use. The answer is a
/// copy as of the request — nothing applies it, and nothing follows the server
/// afterwards.
struct ServerRoutes: Equatable, Sendable {
    var domains: [String]
    var cidrs: [String]

    /// What the client reaches every server with: its key and its relays.
    struct Access: Equatable, Sendable {
        /// The auth key's secret ("ed25519-sec:…").
        var authKey: String
        var relayURLs: [String]
        var relayAuthToken: String
        var relayQuicAddrDiscovery: Bool
    }

    /// Why a server gave no routes, as the core put it.
    struct Failure: Error, Equatable, Sendable {
        let message: String
    }

    /// Ask the server `serverNodeID`. One attempt, a few seconds as a rule and
    /// about a minute against a server that never answers; the blocking call
    /// runs off the main thread.
    static func fetch(serverNodeID: String, access: Access) async -> Result<ServerRoutes, Failure> {
        guard let request = requestJSON(serverNodeID: serverNodeID, access: access) else {
            return .failure(Failure(message: "The request could not be put together."))
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // The call returns the bytes its answer needs, or -1 with the
                // reason in the buffer. An answer larger than the buffer means
                // asking the server again — a second connection, which can
                // fail where the first was answered — so the first one holds
                // the largest there can be: the lists are part of a status
                // page, and the core takes none over this size.
                var buf = [CChar](repeating: 0, count: largestAnswer)
                var needed = request.withCString { flextunnel_fetch_server_routes($0, &buf, buf.count) }
                if needed > buf.count {
                    buf = [CChar](repeating: 0, count: needed)
                    needed = request.withCString { flextunnel_fetch_server_routes($0, &buf, buf.count) }
                }
                let output = String(cString: buf)
                if needed < 0 {
                    continuation.resume(returning: .failure(Failure(message: output)))
                } else if needed <= buf.count, let routes = parse(output) {
                    continuation.resume(returning: .success(routes))
                } else {
                    continuation.resume(returning: .failure(
                        Failure(message: "The server's answer could not be read.")))
                }
            }
        }
    }

    /// The core's limit on a server's status page (`SERVER_STATUS_LIMIT`),
    /// and so on the routes read out of one.
    static let largestAnswer = 1024 * 1024

    /// The FFI's request: the server, and the key and relays to reach it with.
    static func requestJSON(serverNodeID: String, access: Access) -> String? {
        let token = access.relayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let request: [String: Any] = [
            "auth_key": access.authKey,
            "server_node_id": serverNodeID.trimmingCharacters(in: .whitespacesAndNewlines),
            "relay_urls": access.relayURLs,
            "relay_auth_token": token.isEmpty ? NSNull() : token,
            "relay_quic_addr_discovery": ClientStore.quicAddrDiscoverySetting(
                relayURLs: access.relayURLs, enabled: access.relayQuicAddrDiscovery),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The FFI's answer, `{"routed_domains":[…],"routed_cidrs":[…]}`; nil when
    /// it is anything else. A server reports its entries as configured and
    /// trims them itself, so padding around one is dropped here, by the
    /// server's own measure of it (`serverTrimmed`): it is not part of the
    /// rule.
    static func parse(_ json: String) -> ServerRoutes? {
        struct Answer: Decodable {
            let routed_domains: [String]
            let routed_cidrs: [String]
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)) else {
            return nil
        }
        return ServerRoutes(
            domains: answer.routed_domains.map(serverTrimmed),
            cidrs: answer.routed_cidrs.map(serverTrimmed))
    }

    /// `rule` without the whitespace around it, as the server's `str::trim`
    /// takes it off: Unicode `White_Space`, scalar by scalar. Foundation's
    /// whitespace set is not the same one — it holds U+200B, which the server
    /// keeps as part of the name — so trimming with it would turn one of the
    /// server's rules into a name the server does not route.
    static func serverTrimmed(_ rule: String) -> String {
        let scalars = rule.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
            let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
        else { return "" }
        return String(scalars[first...last])
    }

    /// The first entry the editor's fields would not hold as the one rule it
    /// is, if any. The fields are text split on commas and whitespace, and a
    /// server takes any text as an exact domain: one like
    /// `a.example, b.example` would be saved here as two rules the server
    /// does not have. Nor is an entry held that saving would change — one
    /// the store trims further than the server did.
    var entryThatIsNotOneRule: String? {
        (domains + cidrs).first {
            ClientStore.splitRules($0) != [$0] || ClientStore.cleaned([$0]) != [$0]
        }
    }

    /// What to say once the lists have been put in the editor.
    var filledNote: String {
        if domains.isEmpty && cidrs.isEmpty {
            return "The server routes nothing beyond itself."
        }
        return "Filled in the server's \(domains.count) domain(s) and \(cidrs.count) IP range(s)."
    }
}
