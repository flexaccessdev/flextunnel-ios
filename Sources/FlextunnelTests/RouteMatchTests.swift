import XCTest
@testable import Flextunnel

/// `RouteMatch` must agree with flextunnel-core's `RoutedSet` (the cases mirror
/// its tests in `crates/flextunnel-core/src/proxy/routed_set.rs`), so the
/// browser's route labels and the port-forward badges never report the
/// opposite of the route the core takes. The reserved-namespace cases mirror
/// `crates/flextunnel-core/src/proxy/reserved.rs`.
final class RouteMatchTests: XCTestCase {
    func testReservedNamespaceIsTunneledEvenWithAnEmptySet() {
        let empty = routes()
        XCTAssertTrue(tunneled("flextunnel.internal", empty))
        XCTAssertTrue(tunneled("localhost.flextunnel.internal", empty))
        XCTAssertTrue(tunneled("LocalHost.FlexTunnel.Internal", empty))
        XCTAssertTrue(tunneled("a.b.flextunnel.internal", empty))
        XCTAssertFalse(tunneled(".flextunnel.internal", empty))
        XCTAssertFalse(tunneled("flextunnel.internal.evil.com", empty))
        XCTAssertFalse(tunneled("localhost", empty))
    }

    func testBracketsAreStrippedOnlyFromIPLiterals() {
        // The core unbrackets only to parse an IP; a bracketed hostname is
        // matched as it is: not reserved, on no named rule, but still under `*`.
        XCTAssertFalse(tunneled("[localhost.flextunnel.internal]", routes()))
        XCTAssertFalse(tunneled("[example.com]", routes(domains: ["example.com"])))
        XCTAssertTrue(tunneled("[example.com]", routes(domains: ["*"])))
        XCTAssertTrue(tunneled("[10.1.2.3]", routes(cidrs: ["10.0.0.0/8"])))
    }

    func testStarMatchesEveryHostnameButNoIP() {
        let star = routes(domains: ["*"])
        XCTAssertTrue(tunneled("anything.example", star))
        XCTAssertFalse(tunneled("10.0.0.1", star))
        XCTAssertFalse(tunneled("fd00::1", star))
    }

    func testDefaultRoutesMatchEveryIPOfTheirFamilyButNoHostname() {
        let v4 = routes(cidrs: ["0.0.0.0/0"])
        XCTAssertTrue(tunneled("10.1.2.3", v4))
        XCTAssertFalse(tunneled("2001:db8::1", v4))
        XCTAssertFalse(tunneled("example.com", v4))

        let v6 = routes(cidrs: ["::/0"])
        XCTAssertTrue(tunneled("2001:db8::1", v6))
        XCTAssertFalse(tunneled("10.1.2.3", v6))
    }

    func testExactDomainMatchesOnlyItself() {
        let exact = routes(domains: ["example.com"])
        XCTAssertTrue(tunneled("example.com", exact))
        XCTAssertFalse(tunneled("www.example.com", exact))
        XCTAssertFalse(tunneled("badexample.com", exact))
    }

    func testWildcardMatchesSubdomainsButNotTheApex() {
        let wildcard = routes(domains: ["*.example.com"])
        XCTAssertTrue(tunneled("a.example.com", wildcard))
        XCTAssertTrue(tunneled("a.b.example.com", wildcard))
        XCTAssertFalse(tunneled("example.com", wildcard))
        XCTAssertFalse(tunneled("badexample.com", wildcard))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(tunneled("A.Example.COM", routes(domains: ["*.EXAMPLE.com"])))
        XCTAssertTrue(tunneled("Example.com", routes(domains: ["example.COM"])))
    }

    func testIPv4CIDRsAndBareIPs() {
        let set = routes(cidrs: ["10.0.0.0/9", "192.168.1.5"])
        XCTAssertTrue(tunneled("10.0.0.1", set))
        XCTAssertFalse(tunneled("10.128.0.1", set))
        XCTAssertTrue(tunneled("192.168.1.5", set))
        XCTAssertFalse(tunneled("192.168.1.6", set))
    }

    func testIPv6CIDRsAndBareIPs() {
        let set = routes(cidrs: ["fd12:3400::/23", "::1"])
        XCTAssertTrue(tunneled("fd12:3456::1", set))
        XCTAssertFalse(tunneled("fd12:3600::1", set))
        XCTAssertTrue(tunneled("::1", set))
        XCTAssertTrue(tunneled("[fd12:3456::1]", set), "bracketed literal")
    }

    func testIPLiteralIsGatedByCIDRsEvenWithMatchingDomainRules() {
        let set = routes(domains: ["*", "10.0.0.1"], cidrs: ["192.168.0.0/16"])
        XCTAssertFalse(tunneled("10.0.0.1", set))
        XCTAssertTrue(tunneled("192.168.3.4", set))
    }

    func testRulesAreTrimmedLikeTheCore() {
        let set = routes(domains: [" *.corp.example ", "\twiki.example\n"], cidrs: [" 10.0.0.0/8 ", " fd00::1 "])
        XCTAssertTrue(tunneled("a.corp.example", set))
        XCTAssertFalse(tunneled("corp.example", set))
        XCTAssertTrue(tunneled("wiki.example", set))
        XCTAssertTrue(tunneled("10.1.2.3", set))
        XCTAssertTrue(tunneled("fd00::1", set))
        XCTAssertTrue(tunneled("anything.example", routes(domains: [" * "])))
    }

    func testMalformedCIDRsMatchNothing() {
        let set = routes(cidrs: ["10.0.0.0/33", "not-an-ip", "10.0.0.0/8/1", "fd00::/129"])
        XCTAssertFalse(tunneled("10.0.0.1", set))
        XCTAssertFalse(tunneled("fd00::1", set))
    }

    // MARK: - Helpers

    private func tunneled(_ host: String, _ routes: ProxyController.ForwardedRoutes) -> Bool {
        RouteMatch.isTunneled(host: host, routes: routes)
    }
}

/// A tunnel set with only the routing rules filled in.
func routes(domains: [String] = [], cidrs: [String] = [], known: Bool = true) -> ProxyController.ForwardedRoutes {
    ProxyController.ForwardedRoutes(
        connected: known, isKnown: known, domains: domains, cidrs: cidrs,
        hostAliases: [], dnsForwards: [], bridges: [])
}
