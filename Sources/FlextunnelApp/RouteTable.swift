import Foundation
import Network

/// Where the client sends a host.
enum Route: Equatable {
    /// `flextunnel.internal`: the client's own status endpoint, answered by the
    /// in-app proxy without any connection.
    case status
    /// Another `*.flextunnel.internal` name: reserved, answered with a 404 by
    /// the in-app proxy.
    case reserved
    /// Tunneled through the destination with this host name.
    case destination(String)
    /// On no destination's list: the browser connects directly from the
    /// device, and a port forward is refused.
    case direct
}

/// Advisory-only mirror of the core's routing table (`route_table.rs`, with
/// the rule matching of `routed_set.rs` and the reserved namespace of
/// `reserved.rs` in flextunnel-core), used to scope the browser's proxy, label
/// a page and badge a forward target. The core makes the real call per
/// connection, and each server still enforces its own routed set, but the
/// rules here follow the core exactly so a label never reports the opposite
/// route.
///
/// A client holds several *destinations*, each a host name for one server.
/// Precedence, most specific first: the reserved `flextunnel.internal`
/// namespace; a destination's own host (that server's loopback); then the rule
/// that matches most specifically across all destinations — an exact domain,
/// the longest `*.suffix`, `*`, or for an IP target the longest network
/// prefix. A hostname is matched only against domain rules and an IP literal
/// only against the networks: `*` never covers an IP, and a default route
/// never covers a hostname.
struct RouteTable: Equatable {
    /// One destination's routing input, as configured.
    struct Entry: Equatable {
        var host: String
        var domains: [String]
        var cidrs: [String]
    }

    var entries: [Entry]

    /// Route `host` — a hostname or an IP literal, optionally bracketed. As in
    /// the core, brackets are stripped only to read an IP literal; a bracketed
    /// hostname is matched as it is, so only `*` covers it.
    func route(host: String) -> Route {
        let lowered = host.lowercased()
        let unbracketed = lowered.hasPrefix("[") && lowered.hasSuffix("]")
            ? String(lowered.dropFirst().dropLast())
            : lowered

        if let address = Self.addressBytes(unbracketed) {
            return best(entries.map { entry in
                entry.cidrs
                    .compactMap { Self.parseCIDR($0) }
                    .filter { Self.network($0, contains: address) }
                    .map { Specificity.network($0.bits) }
                    .max()
            })
        }

        let name = Self.routingKey(lowered)
        if name == Self.statusHost { return .status }
        if Self.isReserved(name) { return .reserved }
        if let own = entries.first(where: { Self.routingKey($0.host.lowercased()) == name }) {
            return .destination(own.host)
        }
        return best(entries.map { Self.specificity(of: name, in: $0.domains) })
    }

    /// The host of the destination `host` is tunneled through, or nil when it
    /// is not tunneled (direct, or answered by the client itself).
    func destination(for host: String) -> String? {
        if case .destination(let name) = route(host: host) { return name }
        return nil
    }

    /// The destination whose `*` rule takes every hostname no other rule
    /// claims, so nothing by name is left to connect directly.
    var catchAllDestination: String? {
        entries.first { $0.domains.contains { Self.rule($0) == "*" } }?.host
    }

    /// Whether any destination routes IP networks.
    var routesNetworks: Bool {
        entries.contains { !$0.cidrs.isEmpty }
    }

    /// Host patterns for WebKit-level split-tunneling
    /// (`ProxyConfiguration.matchDomains`): matching hosts go through the
    /// SOCKS5 proxy, everything else connects directly from the network
    /// process (local DNS, HTTP/3, no loopback hop). Nil means the whole
    /// optimization is off and every host goes through the proxy — required
    /// when a destination routes `*` or any network, which hostname patterns
    /// can't express (an IP-literal URL must still reach the proxy's network
    /// check).
    ///
    /// WebKit suffix-matches each entry (apex + all subdomains), a superset of
    /// the core's exact/`*.` rules, so both rule forms map to the bare domain.
    /// Over-matching is safe: the in-app proxy makes the exact tunnel-vs-direct
    /// call for whatever reaches it. Under-matching would break private hosts,
    /// so the list must cover everything the core would not send directly —
    /// every destination's own host, and the `flextunnel.internal` namespace
    /// the proxy answers itself.
    var proxyMatchDomains: [String]? {
        guard catchAllDestination == nil, !routesNetworks else { return nil }
        var bases: Set<String> = [Self.statusHost]
        for entry in entries {
            bases.insert(Self.routingKey(entry.host.lowercased()))
            for domain in entry.domains {
                let rule = Self.rule(domain)
                bases.insert(rule.hasPrefix("*.") ? String(rule.dropFirst(2)) : rule)
            }
        }
        return bases.sorted()
    }

    // MARK: - Matching

    /// How specifically a rule matched, ordered least to most specific like
    /// the core's `Specificity`. Hostname and network rules never compete: a
    /// target is one or the other.
    private enum Specificity: Comparable {
        case catchAll
        /// The length of the stored `.suffix`.
        case suffix(Int)
        case exact
        /// A network of this prefix length.
        case network(Int)
    }

    /// The destination with the most specific match. Validation in the core
    /// rules out a tie between two destinations; like the core's `max_by_key`,
    /// a tie would go to the later one.
    private func best(_ matches: [Specificity?]) -> Route {
        var winner: (specificity: Specificity, index: Int)?
        for (index, match) in matches.enumerated() {
            guard let match else { continue }
            if let current = winner, match < current.specificity { continue }
            winner = (match, index)
        }
        return winner.map { .destination(entries[$0.index].host) } ?? .direct
    }

    private static func specificity(of name: String, in domains: [String]) -> Specificity? {
        domains.compactMap { domain -> Specificity? in
            let rule = rule(domain)
            if rule == "*" { return .catchAll }
            if rule.hasPrefix("*.") {
                // Subdomains only — the core excludes the bare apex.
                let suffix = String(rule.dropFirst())
                return name.hasSuffix(suffix) ? .suffix(suffix.count) : nil
            }
            return name == rule ? .exact : nil
        }.max()
    }

    /// A domain rule as the core compares it: trimmed, without the DNS root
    /// dot, lowercased.
    private static func rule(_ raw: String) -> String {
        routingKey(raw.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
    }

    /// The form of a hostname that routing compares: without the DNS root dot
    /// (`db.internal.` and `db.internal` are one name). Only a dot that ends a
    /// label is the root — `*.` and `a..` stay as written — like the core's
    /// `routing_key`.
    static func routingKey(_ host: String) -> String {
        guard host.hasSuffix(".") else { return host }
        let name = host.dropLast()
        guard let last = name.last, last != ".", last != "*" else { return host }
        return String(name)
    }

    static let statusHost = "flextunnel.internal"

    /// A subdomain of `flextunnel.internal`, like the core's
    /// `reserved::is_reserved_host` (`name` already lowercased and without the
    /// root dot): an empty label (`.flextunnel.internal`) is not reserved.
    static func isReserved(_ name: String) -> Bool {
        let suffix = "." + statusHost
        return name.hasSuffix(suffix) && name.count > suffix.count
    }

    // MARK: - Networks

    /// The raw bytes of an IPv4 or IPv6 literal, or nil for a hostname.
    static func addressBytes(_ text: String) -> [UInt8]? {
        if let v4 = IPv4Address(text) { return [UInt8](v4.rawValue) }
        if let v6 = IPv6Address(text) { return [UInt8](v6.rawValue) }
        return nil
    }

    /// A network rule of either family (`10.0.0.0/8`, `fd00::/8`); a bare IP is
    /// a single-host network. Nil for a malformed rule, which matches nothing.
    private static func parseCIDR(_ rule: String) -> (base: [UInt8], bits: Int)? {
        let parts = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let first = parts.first,
              let base = addressBytes(String(first)) else { return nil }
        let maxBits = base.count * 8
        guard parts.count == 2 else { return (base, maxBits) }
        guard let bits = Int(parts[1]), (0...maxBits).contains(bits) else { return nil }
        return (base, bits)
    }

    /// The network `rule` names, in a spelling every equivalent rule shares —
    /// its family, masked address and prefix length, as the core normalizes a
    /// rule to compare two destinations' (`10.1.2.3/8` is `10.0.0.0/8`, a bare
    /// address is its own host network, and an IPv6 address has one form
    /// however it was written). Nil when `rule` is not a network rule.
    static func networkKey(_ rule: String) -> String? {
        guard let network = parseCIDR(rule) else { return nil }
        var remaining = network.bits
        let masked = network.base.map { byte -> UInt8 in
            defer { remaining -= 8 }
            if remaining >= 8 { return byte }
            return remaining > 0 ? byte & ~(0xFF >> UInt8(remaining)) : 0
        }
        // The byte count tells the families apart.
        return masked.map { String(format: "%02x", $0) }.joined() + "/\(network.bits)"
    }

    /// Network containment; never true across families.
    private static func network(_ network: (base: [UInt8], bits: Int), contains address: [UInt8]) -> Bool {
        guard network.base.count == address.count else { return false }
        var remaining = network.bits
        for index in 0..<address.count where remaining > 0 {
            let mask: UInt8 = remaining >= 8 ? 0xFF : ~(0xFF >> UInt8(remaining))
            if network.base[index] & mask != address[index] & mask { return false }
            remaining -= 8
        }
        return true
    }
}
