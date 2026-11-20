import Foundation
import Combine

/// The client's saved setup: its **destinations** and the settings they share.
///
/// A destination is a host name for one flextunnel server: `<host>:<port>`
/// through the client is that port on the server's own loopback, and the
/// destination's routed domains and IP ranges are the further targets sent
/// through that server. One session serves every destination at once, and a
/// server is only connected when something is first sent to it — so, unlike a
/// list of profiles, nothing here is picked before starting.
///
/// The auth key and the relays belong to the client, not to a destination: one
/// keypair identifies this device to every server, and one relay list carries
/// every connection.
///
/// Everything here is non-secret and persists as one JSON document in
/// Application Support. The secrets stay in the Keychain: the auth keys in
/// `AuthKeyStore` (this only references one by id), and the relay auth token
/// under `SecretStore.relayTokenService`, written once it has been used for a
/// connection.
@MainActor
final class ClientStore: ObservableObject {
    /// One server this client reaches. Everything here is safe to write in
    /// plaintext.
    struct Destination: Identifiable, Codable, Equatable {
        let id: String
        /// The name the server goes by on this client, lowercased.
        var host: String
        var serverNodeID: String
        /// Exact names, `*.suffix` or `*`, sent through this server.
        var routedDomains: [String]
        /// Networks or bare IPs sent through this server.
        var routedCIDRs: [String]

        /// The routing input the core is given for this destination.
        var routeEntry: RouteTable.Entry {
            RouteTable.Entry(host: host, domains: routedDomains, cidrs: routedCIDRs)
        }
    }

    /// A user-facing reason a destination can't be saved.
    struct ValidationError: Error, Equatable {
        let message: String
    }

    /// The persisted shape.
    private struct Document: Codable {
        var authKeyID: String
        var relayURLs: String
        var destinations: [Destination]
    }

    @Published private(set) var destinations: [Destination]

    /// Which key from the shared `AuthKeyStore` list this client authenticates
    /// with; empty when none is picked. A plain reference, not a secret.
    @Published var authKeyID: String {
        didSet { if authKeyID != oldValue { persist() } }
    }

    /// The relay URLs as typed — comma-separated, split when a session starts.
    @Published var relayURLs: String {
        didSet { if relayURLs != oldValue { persist() } }
    }

    private let fileURL: URL

    init(directory: URL? = nil) {
        fileURL = (directory ?? JSONStore.directory(named: "Client"))
            .appendingPathComponent("client.json")
        let document = JSONStore.load(Document.self, from: fileURL)
        destinations = document?.destinations ?? []
        authKeyID = document?.authKeyID ?? ""
        relayURLs = document?.relayURLs ?? ""
    }

    /// The routing table these destinations make, for labels before a session
    /// has started.
    var routeTable: RouteTable {
        RouteTable(entries: destinations.map(\.routeEntry))
    }

    /// Add `destination`, or replace the one with its id. The fields are
    /// normalized first; returns why it can't be saved, leaving the list as it
    /// was.
    func save(_ destination: Destination) -> ValidationError? {
        let normalized: Destination
        switch validated(destination) {
        case .success(let valid): normalized = valid
        case .failure(let error): return error
        }
        if let index = destinations.firstIndex(where: { $0.id == normalized.id }) {
            guard destinations[index] != normalized else { return nil }
            destinations[index] = normalized
        } else {
            destinations.append(normalized)
        }
        persist()
        return nil
    }

    func delete(id: String) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations.remove(at: index)
        persist()
    }

    /// Normalize `destination` and check it against the others. These are the
    /// core's own rules for a destination (`route_table.rs`), repeated here so a
    /// mistake is reported next to the field instead of when a session starts;
    /// the core checks again at start and is the authority — the server node id
    /// in particular is only parsed there.
    func validated(_ destination: Destination) -> Result<Destination, ValidationError> {
        var result = destination
        switch Self.validatedHost(destination.host) {
        case .success(let host): result.host = host
        case .failure(let error): return .failure(error)
        }
        result.serverNodeID = destination.serverNodeID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result.routedDomains = Self.cleaned(destination.routedDomains)
        result.routedCIDRs = Self.cleaned(destination.routedCIDRs)

        if result.serverNodeID.isEmpty {
            return .failure(.init(message: "Server node id is required."))
        }
        let others = destinations.filter { $0.id != destination.id }
        if others.contains(where: { $0.host == result.host }) {
            return .failure(.init(message: "Another destination is already named \(result.host)."))
        }
        if let other = others.first(where: { $0.serverNodeID.lowercased() == result.serverNodeID.lowercased() }) {
            return .failure(.init(message: "\(other.host) already reaches that server."))
        }

        for domain in result.routedDomains {
            let rule = Self.ruleKey(domain)
            let name = rule.hasPrefix("*.") ? String(rule.dropFirst(2)) : rule
            if RouteTable.addressBytes(Self.unbracketed(name)) != nil {
                return .failure(.init(message: "\(domain) is an IP address — list it under IP ranges."))
            }
            if rule != "*", name.isEmpty || name.contains("*") || Self.hostnameProblem(name) != nil {
                return .failure(.init(message: "\(domain) is not a domain rule. Use a name, *.suffix or *."))
            }
            if name == RouteTable.statusHost || RouteTable.isReserved(name) {
                return .failure(.init(message: "\(domain) is in the reserved flextunnel.internal namespace."))
            }
            if rule == result.host || others.contains(where: { $0.host == rule }) {
                return .failure(.init(
                    message: "\(domain) is a destination's own name, which always means that server itself."))
            }
            if let other = others.first(where: { $0.routedDomains.contains { Self.ruleKey($0) == rule } }) {
                return .failure(.init(message: "\(domain) is already routed through \(other.host)."))
            }
        }
        for cidr in result.routedCIDRs {
            if !RouteTable.isNetwork(cidr) {
                return .failure(.init(
                    message: "\(cidr) is not an IP range. Use a network like 10.0.0.0/8, or one address."))
            }
            if let other = others.first(where: { $0.routedCIDRs.contains { $0.lowercased() == cidr.lowercased() } }) {
                return .failure(.init(message: "\(cidr) is already routed through \(other.host)."))
            }
        }
        return .success(result)
    }

    /// Split a rules field — one rule per line, or separated by commas or
    /// spaces — into its entries.
    nonisolated static func splitRules(_ text: String) -> [String] {
        text.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    // MARK: - Rules

    /// The core's `validate_destination_host`: a hostname the routing table
    /// can own — not an IP literal, not `localhost` (which every app resolves
    /// itself), not in the reserved namespace. Returns it lowercased.
    private static func validatedHost(_ raw: String) -> Result<String, ValidationError> {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.isEmpty {
            return .failure(.init(message: "Host name is required."))
        }
        if RouteTable.addressBytes(unbracketed(host)) != nil {
            return .failure(.init(message: "\(host) is an IP address; use a host name."))
        }
        if let problem = hostnameProblem(host) {
            return .failure(.init(message: "Host name \(problem)."))
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            return .failure(.init(message: "\(host) is this device's own loopback name; pick another."))
        }
        if host == RouteTable.statusHost || RouteTable.isReserved(host) {
            return .failure(.init(message: "\(host) is in the reserved flextunnel.internal namespace."))
        }
        return .success(host)
    }

    /// The core's hostname rules (`forwards::validate_remote_host`):
    /// permissive (underscores allowed for internal names) but catching real
    /// typos. Returns what is wrong, phrased to follow the field's name.
    private static func hostnameProblem(_ host: String) -> String? {
        if host.utf8.count > 253 { return "is too long (253 characters max)" }
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            if label.isEmpty { return "has an empty label — check the dots" }
            if label.utf8.count > 63 { return "has a label longer than 63 characters" }
            if label.hasPrefix("-") || label.hasSuffix("-") {
                return "labels can't start or end with a hyphen"
            }
            let allowed = label.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
            }
            if !allowed { return "may only contain letters, digits, dots, hyphens and underscores" }
        }
        return nil
    }

    private static func unbracketed(_ text: String) -> String {
        text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text
    }

    /// A domain rule as the core compares it.
    private static func ruleKey(_ raw: String) -> String {
        RouteTable.routingKey(raw.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
    }

    /// Trimmed, without blanks or repeats, in the order given.
    private static func cleaned(_ rules: [String]) -> [String] {
        var seen = Set<String>()
        return rules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func persist() {
        JSONStore.save(
            Document(authKeyID: authKeyID, relayURLs: relayURLs, destinations: destinations),
            to: fileURL)
    }
}
