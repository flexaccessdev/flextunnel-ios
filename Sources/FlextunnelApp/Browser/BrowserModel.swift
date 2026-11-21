import Foundation
import Network
import Observation
import WebKit

/// Owns the browser's tab list, the shared SOCKS5 port, and the shared data
/// store's proxy configuration. Every tab shares the same in-app listener
/// (flextunnel allows one instance at a time), scoped to the routed hosts via
/// `matchDomains` so traffic on no destination's route skips the proxy
/// entirely.
@MainActor
@Observable
final class BrowserModel {
    let socksPort: UInt16
    /// The session's routes: typed into the address bar, a name routed by
    /// exact match is an address, never a search, and so is anything shaped
    /// like a URL whose host is routed.
    let routes: RouteTable
    let library: BrowserLibrary
    let downloads: BrowserDownloadManager
    private(set) var tabs: [BrowserTab]
    var selectedID: BrowserTab.ID?
    // Persistent (default) store so cookies, logins, and cache survive across
    // launches like a mainstream browser. (Downloads stay session-only by design.)
    private let websiteDataStore = WKWebsiteDataStore.default()
    private let certificateTrustStore = BrowserCertificateTrustStore()

    init(
        socksPort: UInt16, proxyMatchDomains: [String]?, routes: RouteTable,
        library: BrowserLibrary
    ) {
        self.socksPort = socksPort
        self.routes = routes
        self.library = library
        websiteDataStore.proxyConfigurations = [
            .loopbackSocks5(port: socksPort, matchDomains: proxyMatchDomains)
        ]
        let downloads = BrowserDownloadManager(
            socksPort: socksPort,
            proxyMatchDomains: proxyMatchDomains,
            websiteDataStore: websiteDataStore)
        self.downloads = downloads
        let first = BrowserTab.make(
            websiteDataStore: websiteDataStore,
            certificateTrustStore: certificateTrustStore,
            library: library,
            downloads: downloads)
        self.tabs = [first]
        self.selectedID = first.id
    }

    /// Reloads the tabs whose last load failed on a URL `shouldRetry` accepts —
    /// the ones routed through a destination that has just connected — the way
    /// a mainstream browser reloads its offline pages when the network returns. Only idempotent
    /// requests: a retry reloads the URL, which would turn a failed form POST
    /// into a GET.
    func retryFailedLoads(where shouldRetry: (URL) -> Bool) {
        for tab in tabs {
            guard let failure = tab.loadFailure, failure.isIdempotent,
                  shouldRetry(failure.url) else { continue }
            tab.retryFailedLoad()
        }
    }

    var selectedTab: BrowserTab? {
        if let selectedID, let selected = tabs.first(where: { $0.id == selectedID }) {
            return selected
        }
        return tabs.first
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
    }

    /// Opens a fresh proxied tab at the home page and selects it.
    @discardableResult
    func addTab() -> BrowserTab {
        let tab = BrowserTab.make(
            websiteDataStore: websiteDataStore,
            certificateTrustStore: certificateTrustStore,
            library: library,
            downloads: downloads)
        tabs.append(tab)
        selectedID = tab.id
        return tab
    }

    /// Closes a tab. Reselects a neighbor if the closed tab was active, or leaves
    /// the browser with no selected tab when the last tab is closed.
    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.stopObserving()
        tabs.remove(at: index)
        if selectedID == tab.id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Resolves address-bar text and loads it in the selected tab.
    /// - URL-like input (no spaces, contains a dot, or already has a scheme) loads
    ///   directly; a missing scheme is prepended (`http://` for `.onion`, else `https://`).
    /// - So does a name the session routes by exact match, dot or no dot.
    /// - A private address that can't be opened raises `addressError`.
    /// - Anything else is treated as a query and sent to DuckDuckGo.
    func navigate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = Self.resolve(trimmed, routes: routes) else {
            addressError = trimmed
            return
        }
        let tab = selectedTab ?? addTab()
        tab.load(url, displayAddress: trimmed)
    }

    /// Address-bar text naming a private address that isn't a valid URL —
    /// shown as an error, never searched.
    var addressError: String?

    func stopAll() {
        tabs.forEach { $0.stop() }
        downloads.shutdown()
    }

    /// A name the session routes by exact match (`routes.exactNames`) is an
    /// address even as a single label, which otherwise reads as a search term
    /// — and a search would send the name, port and path of a private address
    /// to a search engine. For the same reason, nil when the text is shaped
    /// like a URL whose host is not on the direct path — routed through a
    /// destination by any rule, or in `flextunnel.internal` — but is not a
    /// valid URL.
    static func resolve(_ text: String, routes: RouteTable = RouteTable(entries: [])) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let privateHosts = routes.exactNames

        if let url = webURL(from: trimmed, privateHosts: privateHosts) {
            return url
        }

        if let typed = typedHost(of: trimmed) {
            let host = RouteTable.routingKey(typed.host)
            // A scheme, a dot (but not a number like 3.14), an IPv6 literal or
            // an exact private name: a single word under a `*` route is still
            // a search.
            let urlShaped = typed.hasScheme
                || (host.contains(".") && Double(host) == nil)
                || host.hasPrefix("[") || privateHosts.contains(host)
            if urlShaped && routes.route(host: host) != .direct {
                return nil
            }
        }

        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    /// The host the text starts with, read without a URL parser (the text may
    /// be one no parser takes) and lowercased — past a scheme that starts the
    /// text and any user info, up to the first colon (a port, however
    /// malformed) or a path, query or fragment; an IPv6 literal keeps its
    /// brackets — and whether a scheme came first. Nil when that host has a
    /// space, which makes the text a search (`office hours`); a space after
    /// it (`http://office/a b`, `office: 8080`) does not.
    private static func typedHost(of text: String) -> (host: String, hasScheme: Bool)? {
        let scheme = leadingScheme(of: text)
        var rest = scheme?.rest ?? Substring(text)
        rest = rest.prefix { !"/?#".contains($0) }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = rest[...close]
        } else {
            rest = rest.prefix { $0 != ":" }
        }
        guard !rest.isEmpty, !rest.contains(where: \.isWhitespace) else { return nil }
        return (rest.lowercased(), scheme != nil)
    }

    /// The URL scheme that starts the text (RFC 3986: a letter, then letters,
    /// digits, `+`, `-` or `.`, before `://`) and what follows it — so a `://`
    /// later in a path or query (`office/?next=http://x`) is not taken for
    /// one.
    private static func leadingScheme(of text: String) -> (scheme: String, rest: Substring)? {
        guard let delimiter = text.range(of: "://") else { return nil }
        let scheme = text[..<delimiter.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
            return nil
        }
        return (scheme.lowercased(), text[delimiter.upperBound...])
    }

    private static func webURL(from text: String, privateHosts: Set<String>) -> URL? {
        if let localhostURL = localhostURL(from: text) {
            return localhostURL
        }

        switch leadingScheme(of: text)?.scheme {
        case "http", "https":
            return validHTTPURL(from: text, privateHosts: privateHosts)
        case nil:
            return bareHostURL(from: text, privateHosts: privateHosts)
        default:
            return nil
        }
    }

    private static func localhostURL(from text: String) -> URL? {
        guard !text.contains(" ") else { return nil }
        guard let components = URLComponents(string: "http://\(text)"),
              components.host?.lowercased() == "localhost" else {
            return nil
        }
        return components.url
    }

    private static func validHTTPURL(from text: String, privateHosts: Set<String>) -> URL? {
        guard !text.contains(" "),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              hostIsNavigable(host, privateHosts: privateHosts) else {
            return nil
        }
        return components.url
    }

    private static func bareHostURL(from text: String, privateHosts: Set<String>) -> URL? {
        guard !text.contains(" "), Double(text) == nil else { return nil }

        // Parse with a default scheme so the host is isolated from any port or
        // path, then pick the real scheme from the parsed host. Onion services
        // are served over plain HTTP (the onion layer handles encryption /
        // authentication; CA certs for .onion are rare), so any `.onion` host —
        // regardless of case or port — uses http; everything else stays https.
        guard var components = URLComponents(string: "https://\(text)"),
              let host = components.host,
              // A bracketed IPv6 literal (`[fdb8::1]:8006`) is an address even
              // though it has no dot, and so is a private name (`office:8080`).
              text.contains(".") || text.hasPrefix("[") || privateHosts.contains(host.lowercased()),
              hostIsNavigable(host, privateHosts: privateHosts) else {
            return nil
        }
        if host.lowercased().hasSuffix(".onion") {
            components.scheme = "http"
        }
        return components.url
    }

    private static func hostIsNavigable(_ host: String, privateHosts: Set<String>) -> Bool {
        // A colon in the parsed host means an IPv6 literal (URLComponents keeps
        // the port separate), e.g. https://[fdb8:d92a:f690:1abf::1]:8006.
        host == "localhost" || host.contains(".") || host.contains(":")
            || privateHosts.contains(host.lowercased())
    }
}

extension ProxyConfiguration {
    /// The browser's loopback SOCKS5 proxy. With `matchDomains` set, WebKit
    /// only proxies matching hosts (suffix match: apex + subdomains) and
    /// connects to everything else directly; nil/empty proxies every host.
    /// SOCKS5 passes matched hostnames to the proxy (ATYP_DOMAIN), so DNS for
    /// routed names still resolves on the destination's server.
    ///
    /// Failover is pinned off: a proxied (routed) host whose proxy connection
    /// fails — listener closed across a relaunch, server unreachable — fails
    /// the load instead of being retried directly. A private host that
    /// also happens to resolve and answer off-tunnel would otherwise flap
    /// between the tunnel and a direct path with every link blip, and a
    /// direct retry leaks the request past the server's routing.
    static func loopbackSocks5(port: UInt16, matchDomains: [String]?) -> ProxyConfiguration {
        var config = ProxyConfiguration(socksv5Proxy: .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!))
        config.matchDomains = matchDomains ?? []
        config.allowFailover = false
        return config
    }
}
