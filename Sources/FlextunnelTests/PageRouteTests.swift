import XCTest
@testable import Flextunnel

final class PageRouteTests: XCTestCase {
    private let set = routes(domains: ["*.corp.example"], cidrs: ["10.0.0.0/8", "fd00::/8"])

    func testTunneledAndDirectHosts() {
        XCTAssertEqual(PageRoute.resolve(URL(string: "https://wiki.corp.example/page"), routes: set), .tunnel)
        XCTAssertEqual(PageRoute.resolve(URL(string: "https://corp.example/"), routes: set), .direct)
        XCTAssertEqual(PageRoute.resolve(URL(string: "https://www.apple.com/"), routes: set), .direct)
    }

    func testIPLiteralURLs() {
        XCTAssertEqual(PageRoute.resolve(URL(string: "http://10.1.2.3:8080/"), routes: set), .tunnel)
        XCTAssertEqual(PageRoute.resolve(URL(string: "http://127.0.0.1:9/"), routes: set), .direct)
        XCTAssertEqual(PageRoute.resolve(URL(string: "https://[fd00::5]:8006/"), routes: set), .tunnel)
        XCTAssertEqual(PageRoute.resolve(URL(string: "https://[2001:db8::5]/"), routes: set), .direct)
    }

    func testReservedNamespaceIsAlwaysTunneled() {
        XCTAssertEqual(PageRoute.resolve(URL(string: "http://flextunnel.internal"), routes: set), .tunnel)
        XCTAssertEqual(PageRoute.resolve(URL(string: "http://status.flextunnel.internal/"), routes: set), .tunnel)
    }

    func testUnknownWithoutAKnownTunnelSetOrHost() {
        XCTAssertNil(PageRoute.resolve(URL(string: "https://wiki.corp.example/"), routes: nil))
        XCTAssertNil(PageRoute.resolve(URL(string: "https://wiki.corp.example/"), routes: routes()),
                     "an empty set is not known yet, not 'nothing routed'")
        XCTAssertNil(PageRoute.resolve(URL(string: "about:blank"), routes: set))
        XCTAssertNil(PageRoute.resolve(nil, routes: set))
    }
}
