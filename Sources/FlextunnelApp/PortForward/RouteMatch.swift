import Foundation
import Network

/// Advisory-only mirror of the core's split-tunnel decision (`RoutedSet` in
/// flextunnel-core), used to badge a forward target and label a browser page as
/// tunneled or direct. The core (and the server) remain the authority, but the
/// rules here follow it exactly so a label never reports the opposite route.
enum RouteMatch {
    /// Whether `host` (hostname or IP literal, optionally bracketed) falls in
    /// the routed tunnel set. As in the core, a hostname is matched only against
    /// the domain rules and an IP literal only against the CIDRs: `*` never
    /// covers an IP, and a default-route CIDR never covers a hostname.
    static func isTunneled(host: String, routes: ProxyController.ForwardedRoutes) -> Bool {
        var normalized = host.lowercased()
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }

        if let ip = IPv4Address(normalized) {
            return routes.cidrs.contains { cidrContains($0, ip.rawValue) }
        }
        if let ip = IPv6Address(normalized) {
            return routes.cidrs.contains { cidrContains($0, ip.rawValue) }
        }

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
