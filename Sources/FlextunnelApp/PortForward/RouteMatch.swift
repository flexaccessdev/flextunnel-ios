import Foundation
import Network

/// Advisory-only mirror of the core's split-tunnel decision (the reserved
/// namespace, then `RoutedSet` in flextunnel-core), used to badge a forward
/// target and label a browser page as tunneled or direct. The core (and the
/// server) remain the authority, but the rules here follow it exactly so a
/// label never reports the opposite route.
enum RouteMatch {
    /// Whether `host` (hostname or IP literal, optionally bracketed) goes
    /// through the tunnel. The reserved `flextunnel.internal` namespace always
    /// does, whatever the set. Otherwise, as in the core, a hostname is matched
    /// only against the domain rules and an IP literal only against the CIDRs:
    /// `*` never covers an IP, and a default-route CIDR never covers a hostname.
    /// As in the core, brackets are stripped only to read an IP literal; a
    /// bracketed hostname is matched as it is, so it matches nothing.
    static func isTunneled(host: String, routes: ProxyController.ForwardedRoutes) -> Bool {
        let normalized = host.lowercased()
        let unbracketed = normalized.hasPrefix("[") && normalized.hasSuffix("]")
            ? String(normalized.dropFirst().dropLast())
            : normalized

        if let ip = IPv4Address(unbracketed) {
            return routes.cidrs.contains { cidrContains($0, ip.rawValue) }
        }
        if let ip = IPv6Address(unbracketed) {
            return routes.cidrs.contains { cidrContains($0, ip.rawValue) }
        }

        if isReserved(normalized) { return true }

        // The core trims each rule but publishes the raw arrays, so trim here too.
        return routes.domains.contains { pattern in
            let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern == "*" { return true }
            if pattern.hasPrefix("*.") {
                // Subdomains only — the core excludes the bare apex.
                return normalized.hasSuffix(String(pattern.dropFirst()))
            }
            return normalized == pattern
        }
    }

    /// `flextunnel.internal` or any subdomain of it, like the core's
    /// `reserved::is_reserved_host` (`host` already lowercased): an empty label
    /// (`.flextunnel.internal`) is not reserved.
    private static func isReserved(_ host: String) -> Bool {
        let suffix = ".flextunnel.internal"
        return host == "flextunnel.internal" || (host.hasSuffix(suffix) && host.count > suffix.count)
    }

    /// CIDR containment for either family (`10.0.0.0/8`, `fd00::/8`); a bare IP
    /// matches as a single host. Never true across families.
    private static func cidrContains(_ cidr: String, _ address: Data) -> Bool {
        let parts = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let first = parts.first else { return false }
        let base: Data
        if let v4 = IPv4Address(String(first)) {
            base = v4.rawValue
        } else if let v6 = IPv6Address(String(first)) {
            base = v6.rawValue
        } else {
            return false
        }
        guard base.count == address.count else { return false }

        let maxBits = base.count * 8
        let bits: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (0...maxBits).contains(parsed) else { return false }
            bits = parsed
        } else {
            bits = maxBits
        }

        let baseBytes = [UInt8](base)
        let addressBytes = [UInt8](address)
        var remaining = bits
        for index in 0..<baseBytes.count where remaining > 0 {
            let mask: UInt8 = remaining >= 8 ? 0xFF : ~(0xFF >> UInt8(remaining))
            if baseBytes[index] & mask != addressBytes[index] & mask { return false }
            remaining -= 8
        }
        return true
    }
}
