import Network
import XCTest
@testable import Flextunnel

/// Loads through the browser's `ProxyConfiguration.loopbackSocks5` with
/// nothing listening on the proxy port — the browser's state across a relaunch
/// gap or a suspension — against a site on loopback that answers directly, so
/// a request that fell back to a direct connection would load.
final class ProxyConfigurationTests: XCTestCase {
    private var site: LoopbackSite!
    private var closedProxyPort: UInt16!

    override func setUp() async throws {
        site = try await LoopbackSite.start()
        closedProxyPort = try unusedLoopbackPort()
    }

    override func tearDown() {
        site?.stop()
        super.tearDown()
    }

    func testFailoverIsOffWhetherScopedOrNot() {
        let scoped = ProxyConfiguration.loopbackSocks5(port: 1080, matchDomains: ["corp.example"])
        XCTAssertFalse(scoped.allowFailover)
        XCTAssertEqual(scoped.matchDomains, ["corp.example"])

        let everything = ProxyConfiguration.loopbackSocks5(port: 1080, matchDomains: nil)
        XCTAssertFalse(everything.allowFailover)
        XCTAssertEqual(everything.matchDomains, [])
    }

    /// A tunnel-set host fails while the proxy is unreachable, although it
    /// answers directly: it never flaps onto the direct path.
    func testTunnelSetHostNeverFallsBackDirect() async {
        let config = ProxyConfiguration.loopbackSocks5(port: closedProxyPort, matchDomains: ["localhost"])
        let body = await load("http://localhost:\(site.port)/", through: config)
        XCTAssertNil(body, "a tunnel-set host loaded without the proxy")
    }

    /// Control for the test above: with failover allowed, the same request
    /// reaches the site directly, so that test would catch a fallback.
    func testFailoverWouldReachTheSiteDirectly() async {
        var config = ProxyConfiguration.loopbackSocks5(port: closedProxyPort, matchDomains: ["localhost"])
        config.allowFailover = true
        let body = await load("http://localhost:\(site.port)/", through: config)
        XCTAssertEqual(body, LoopbackSite.body)
    }

    /// An off-list host never touches the proxy, so it loads directly while the
    /// proxy is down.
    func testOffListHostBypassesTheProxy() async {
        let config = ProxyConfiguration.loopbackSocks5(port: closedProxyPort, matchDomains: ["corp.example"])
        let body = await load("http://localhost:\(site.port)/", through: config)
        XCTAssertEqual(body, LoopbackSite.body)
    }

    /// Unscoped (a full-tunnel or CIDR set), every host goes to the proxy, so an
    /// off-list host fails too while the proxy is down: the core is what dials
    /// it directly, and the core isn't listening.
    func testUnscopedProxyHoldsOffListHostsToo() async {
        let config = ProxyConfiguration.loopbackSocks5(port: closedProxyPort, matchDomains: nil)
        let body = await load("http://localhost:\(site.port)/", through: config)
        XCTAssertNil(body, "an unscoped proxy let a host bypass it")
    }

    /// Unscoped, an IP-address URL goes to the proxy too, which is how a CIDR
    /// in the set reaches the core's CIDR check. (The system never proxies
    /// loopback or this device's own addresses, so those can't stand in here.)
    func testUnscopedProxyTakesIPAddressURLs() async {
        // The site stands in for the proxy: it counts the connections, and its
        // HTTP reply to the SOCKS greeting fails the load.
        let config = ProxyConfiguration.loopbackSocks5(port: site.port, matchDomains: nil)
        for address in ["http://10.99.99.99/", "http://[2001:db8::9]/"] {
            let before = site.connections
            _ = await load(address, through: config)
            XCTAssertGreaterThan(site.connections, before, "\(address) skipped the proxy")
        }
    }

    // MARK: - Helpers

    /// The response body, or nil when the load failed.
    private func load(_ address: String, through proxy: ProxyConfiguration) async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [proxy]
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: URL(string: address)!) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A loopback TCP port nothing listens on (bound, read back, released).
    private func unusedLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return UInt16(bigEndian: addr.sin_port)
    }
}

/// A one-page HTTP site on 127.0.0.1 that answers every request with `body`
/// and counts the connections it accepts.
private final class LoopbackSite: @unchecked Sendable {
    static let body = "direct"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-site")
    private let lock = NSLock()
    private var accepted = 0

    var port: UInt16 { listener.port!.rawValue }

    var connections: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    private init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    static func start() async throws -> LoopbackSite {
        let site = try LoopbackSite()
        try await site.run()
        return site
    }

    private func run() async throws {
        listener.newConnectionHandler = { [self] connection in
            lock.lock()
            accepted += 1
            lock.unlock()
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let body = Self.body
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}
