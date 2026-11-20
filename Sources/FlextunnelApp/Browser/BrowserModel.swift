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
    /// The names the session routes by exact match (`RouteTable.exactNames`):
    /// typed into the address bar, each is an address, never a search.
    let privateHosts: Set<String>
    let library: BrowserLibrary
    let downloads: BrowserDownloadManager
    private(set) var tabs: [BrowserTab]
    var selectedID: BrowserTab.ID?
    // Persistent (default) store so cookies, logins, and cache survive across
    // launches like a mainstream browser. (Downloads stay session-only by design.)
    private let websiteDataStore = WKWebsiteDataStore.default()
    private let certificateTrustStore = BrowserCertificateTrustStore()

    init(
        socksPort: UInt16, proxyMatchDomains: [String]?, privateHosts: Set<String>,
        library: BrowserLibrary
    ) {
        self.socksPort = socksPort
        self.privateHosts = privateHosts
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
    /// - Anything else is treated as a query and sent to DuckDuckGo.
    func navigate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = Self.resolve(trimmed, privateHosts: privateHosts) else { return }
        let tab = selectedTab ?? addTab()
        tab.load(url, displayAddress: trimmed)
    }

    func stopAll() {
        tabs.forEach { $0.stop() }
        downloads.shutdown()
    }

    /// `privateHosts` are the names the session routes by exact match
    /// (lowercased). A destination may be named with a single label, which
    /// otherwise reads as a search term — and a search would send the name,
    /// port and path of a private address to a search engine.
    static func resolve(_ text: String, privateHosts: Set<String> = []) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = webURL(from: trimmed, privateHosts: privateHosts) {
            return url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    private static func webURL(from text: String, privateHosts: Set<String>) -> URL? {
        if let localhostURL = localhostURL(from: text) {
            return localhostURL
        }

        let lowercased = text.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return validHTTPURL(from: text, privateHosts: privateHosts)
        }

        if lowercased.contains("://") {
            return nil
        }

        return bareHostURL(from: text, privateHosts: privateHosts)
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
