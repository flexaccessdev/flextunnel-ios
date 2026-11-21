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
                var buf = [CChar](repeating: 0, count: 64 * 1024)
                let ok = request.withCString { flextunnel_fetch_server_routes($0, &buf, buf.count) }
                let output = String(cString: buf)
                if ok == 1, let routes = parse(output) {
                    continuation.resume(returning: .success(routes))
                } else if ok == 1 {
                    continuation.resume(returning: .failure(
                        Failure(message: "The server's answer could not be read.")))
                } else {
                    continuation.resume(returning: .failure(Failure(message: output)))
                }
            }
        }
    }

    /// The FFI's request: the server, and the key and relays to reach it with.
    static func requestJSON(serverNodeID: String, access: Access) -> String? {
        let token = access.relayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let request: [String: Any] = [
            "auth_key": access.authKey,
            "server_node_id": serverNodeID.trimmingCharacters(in: .whitespacesAndNewlines),
            "relay_urls": access.relayURLs,
            "relay_auth_token": token.isEmpty ? NSNull() : token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The FFI's answer, `{"routed_domains":[…],"routed_cidrs":[…]}`; nil when
    /// it is anything else.
    static func parse(_ json: String) -> ServerRoutes? {
        struct Answer: Decodable {
            let routed_domains: [String]
            let routed_cidrs: [String]
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)) else {
            return nil
        }
        return ServerRoutes(domains: answer.routed_domains, cidrs: answer.routed_cidrs)
    }

    /// What to say once the lists have been put in the editor.
    var filledNote: String {
        if domains.isEmpty && cidrs.isEmpty {
            return "The server routes nothing beyond itself."
        }
        return "Filled in the server's \(domains.count) domain(s) and \(cidrs.count) IP range(s)."
    }
}
