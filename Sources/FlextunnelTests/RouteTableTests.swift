import XCTest
@testable import Flextunnel

/// `RouteTable` must agree with flextunnel-core's routing — the table in
/// `crates/flextunnel-core/src/proxy/route_table.rs`, the rule matching in
/// `routed_set.rs` and the reserved namespace in `reserved.rs`; the cases
/// mirror their tests — so the browser's route labels, its proxy scoping and
/// the port-forward badges never report the opposite of the route the core
/// takes.
final class RouteTableTests: XCTestCase {
    // MARK: - The table (route_table.rs)

    func testOwnHostIsThatDestination() {
        let t = table(("machine1.internal", [], []), ("machine2.internal", [], []))
        XCTAssertEqual(t.route(host: "machine1.internal"), .destination("machine1.internal"))
        XCTAssertEqual(t.route(host: "Machine2.Internal"), .destination("machine2.internal"))
        // A subdomain of a destination is not the destination.
        XCTAssertEqual(t.route(host: "a.machine1.internal"), .direct)
    }

    func testReservedNamespaceIsAnsweredByTheClient() {
        // Even a catch-all route never captures the reserved names.
        let t = table(("m1.internal", ["*"], ["0.0.0.0/0"]))
        XCTAssertEqual(t.route(host: "flextunnel.internal"), .status)
        XCTAssertEqual(t.route(host: "FlexTunnel.Internal"), .status)
        XCTAssertEqual(t.route(host: "x.flextunnel.internal"), .reserved)
        XCTAssertEqual(t.route(host: "localhost.flextunnel.internal"), .reserved)
        XCTAssertEqual(t.route(host: "a.b.flextunnel.internal"), .reserved)
        // Not the namespace: an empty label, and a name that only contains it.
        XCTAssertEqual(t.route(host: ".flextunnel.internal"), .destination("m1.internal"))
        XCTAssertEqual(t.route(host: "flextunnel.internal.evil.com"), .destination("m1.internal"))
        XCTAssertEqual(table().route(host: "flextunnel.internal"), .status)
    }

    func testRoutedRulesPickTheirDestination() {
        let t = table(
            ("m1.internal", ["*.corp.example", "db.internal"], ["10.0.0.0/8"]),
            ("m2.internal", ["wiki.example"], ["192.168.7.0/24"]))
        XCTAssertEqual(t.route(host: "api.corp.example"), .destination("m1.internal"))
        XCTAssertEqual(t.route(host: "DB.internal"), .destination("m1.internal"))
        XCTAssertEqual(t.route(host: "wiki.example"), .destination("m2.internal"))
        XCTAssertEqual(t.route(host: "192.168.7.9"), .destination("m2.internal"))
        XCTAssertEqual(t.route(host: "10.1.2.3"), .destination("m1.internal"))
        // Off every list: direct.
        XCTAssertEqual(t.route(host: "example.org"), .direct)
        XCTAssertEqual(t.route(host: "8.8.8.8"), .direct)
        XCTAssertEqual(t.destination(for: "wiki.example"), "m2.internal")
        XCTAssertNil(t.destination(for: "example.org"))
        XCTAssertNil(t.destination(for: "flextunnel.internal"))
    }

    func testTheMostSpecificRuleWinsAcrossDestinations() {
        let t = table(
            ("m1.internal", ["*", "*.corp.example"], ["10.0.0.0/8"]),
            ("m2.internal", ["*.dev.corp.example", "exact.corp.example"], ["10.1.0.0/16"]))
        XCTAssertEqual(t.route(host: "anything.example"), .destination("m1.internal"), "only the catch-all matches")
        XCTAssertEqual(t.route(host: "api.corp.example"), .destination("m1.internal"), "the shorter suffix")
        XCTAssertEqual(t.route(host: "x.dev.corp.example"), .destination("m2.internal"), "the longer suffix beats it")
        XCTAssertEqual(t.route(host: "exact.corp.example"), .destination("m2.internal"), "an exact name beats a suffix")
        XCTAssertEqual(t.route(host: "10.2.0.1"), .destination("m1.internal"))
        XCTAssertEqual(t.route(host: "10.1.0.1"), .destination("m2.internal"), "the longer prefix")
        // `*` is a hostname catch-all only: an unlisted IP still goes direct.
        XCTAssertEqual(t.route(host: "8.8.8.8"), .direct)
    }

    func testOwnHostBeatsAWildcardThatCoversIt() {
        let t = table(("m1.internal", [], []), ("m2.internal", ["*.internal"], []))
        XCTAssertEqual(t.route(host: "m1.internal"), .destination("m1.internal"))
        XCTAssertEqual(t.route(host: "nas.internal"), .destination("m2.internal"))
    }

    func testTheRootDotSelectsTheSameRoute() {
        let t = table(("a.internal", ["db.example"], []), ("b.internal", ["*"], []))
        for host in ["db.example", "db.example.", "DB.Example."] {
            XCTAssertEqual(t.route(host: host), .destination("a.internal"), host)
        }
        for host in ["a.internal", "a.internal."] {
            XCTAssertEqual(t.route(host: host), .destination("a.internal"), host)
        }
        XCTAssertEqual(t.route(host: "unrelated.example."), .destination("b.internal"))
        XCTAssertEqual(t.route(host: "flextunnel.internal."), .status)
        XCTAssertEqual(t.route(host: "x.flextunnel.internal."), .reserved)
        // A rule written with the root dot is the same rule.
        XCTAssertEqual(table(("a.internal", ["db.example."], [])).route(host: "db.example"), .destination("a.internal"))
    }

    // MARK: - Rule matching (routed_set.rs)

    func testBracketsAreStrippedOnlyFromIPLiterals() {
        // The core unbrackets only to parse an IP; a bracketed hostname is
        // matched as it is: not reserved, on no named rule, but still under `*`.
        XCTAssertFalse(tunneled("[localhost.flextunnel.internal]", domains: ["example.com"]))
        XCTAssertFalse(tunneled("[example.com]", domains: ["example.com"]))
        XCTAssertTrue(tunneled("[example.com]", domains: ["*"]))
        XCTAssertTrue(tunneled("[10.1.2.3]", cidrs: ["10.0.0.0/8"]))
    }

    func testStarMatchesEveryHostnameButNoIP() {
        XCTAssertTrue(tunneled("anything.example", domains: ["*"]))
        XCTAssertFalse(tunneled("10.0.0.1", domains: ["*"]))
        XCTAssertFalse(tunneled("fd00::1", domains: ["*"]))
    }

    func testDefaultRoutesMatchEveryIPOfTheirFamilyButNoHostname() {
        XCTAssertTrue(tunneled("10.1.2.3", cidrs: ["0.0.0.0/0"]))
        XCTAssertFalse(tunneled("2001:db8::1", cidrs: ["0.0.0.0/0"]))
        XCTAssertFalse(tunneled("example.com", cidrs: ["0.0.0.0/0"]))

        XCTAssertTrue(tunneled("2001:db8::1", cidrs: ["::/0"]))
        XCTAssertFalse(tunneled("10.1.2.3", cidrs: ["::/0"]))
    }

    func testExactDomainMatchesOnlyItself() {
        XCTAssertTrue(tunneled("example.com", domains: ["example.com"]))
        XCTAssertFalse(tunneled("www.example.com", domains: ["example.com"]))
        XCTAssertFalse(tunneled("badexample.com", domains: ["example.com"]))
    }

    func testWildcardMatchesSubdomainsButNotTheApex() {
        XCTAssertTrue(tunneled("a.example.com", domains: ["*.example.com"]))
        XCTAssertTrue(tunneled("a.b.example.com", domains: ["*.example.com"]))
        XCTAssertFalse(tunneled("example.com", domains: ["*.example.com"]))
        XCTAssertFalse(tunneled("badexample.com", domains: ["*.example.com"]))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(tunneled("A.Example.COM", domains: ["*.EXAMPLE.com"]))
        XCTAssertTrue(tunneled("Example.com", domains: ["example.COM"]))
    }

    func testIPv4CIDRsAndBareIPs() {
        let cidrs = ["10.0.0.0/9", "192.168.1.5"]
        XCTAssertTrue(tunneled("10.0.0.1", cidrs: cidrs))
        XCTAssertFalse(tunneled("10.128.0.1", cidrs: cidrs))
        XCTAssertTrue(tunneled("192.168.1.5", cidrs: cidrs))
        XCTAssertFalse(tunneled("192.168.1.6", cidrs: cidrs))
    }

    func testIPv6CIDRsAndBareIPs() {
        let cidrs = ["fd12:3400::/23", "::1"]
        XCTAssertTrue(tunneled("fd12:3456::1", cidrs: cidrs))
        XCTAssertFalse(tunneled("fd12:3600::1", cidrs: cidrs))
        XCTAssertTrue(tunneled("::1", cidrs: cidrs))
        XCTAssertTrue(tunneled("[fd12:3456::1]", cidrs: cidrs), "bracketed literal")
    }

    func testIPLiteralIsGatedByCIDRsEvenWithMatchingDomainRules() {
        XCTAssertFalse(tunneled("10.0.0.1", domains: ["*"], cidrs: ["192.168.0.0/16"]))
        XCTAssertTrue(tunneled("192.168.3.4", domains: ["*"], cidrs: ["192.168.0.0/16"]))
    }

    func testRulesAreTrimmedLikeTheCore() {
        let domains = [" *.corp.example ", "\twiki.example\n"]
        let cidrs = [" 10.0.0.0/8 ", " fd00::1 "]
        XCTAssertTrue(tunneled("a.corp.example", domains: domains, cidrs: cidrs))
        XCTAssertFalse(tunneled("corp.example", domains: domains, cidrs: cidrs))
        XCTAssertTrue(tunneled("wiki.example", domains: domains, cidrs: cidrs))
        XCTAssertTrue(tunneled("10.1.2.3", domains: domains, cidrs: cidrs))
        XCTAssertTrue(tunneled("fd00::1", domains: domains, cidrs: cidrs))
        XCTAssertTrue(tunneled("anything.example", domains: [" * "]))
    }

    func testMalformedCIDRsMatchNothing() {
        let cidrs = ["10.0.0.0/33", "not-an-ip", "10.0.0.0/8/1", "fd00::/129"]
        XCTAssertFalse(tunneled("10.0.0.1", cidrs: cidrs))
        XCTAssertFalse(tunneled("fd00::1", cidrs: cidrs))
    }

    func testEquivalentNetworkRulesShareAKey() {
        // The core compares two destinations' networks as `network/prefix`.
        XCTAssertEqual(RouteTable.networkKey("10.1.2.3/8"), RouteTable.networkKey(" 10.0.0.0/8 "))
        XCTAssertEqual(RouteTable.networkKey("192.168.1.5"), RouteTable.networkKey("192.168.1.5/32"))
        XCTAssertEqual(RouteTable.networkKey("fd00::/8"), RouteTable.networkKey("FD00:0:0::1/8"))
        XCTAssertEqual(RouteTable.networkKey("fd00::1"), RouteTable.networkKey("fd00:0:0:0:0:0:0:1/128"))
        XCTAssertEqual(RouteTable.networkKey("10.9.9.9/0"), RouteTable.networkKey("0.0.0.0/0"))
        // A different prefix, address or family is a different rule.
        XCTAssertNotEqual(RouteTable.networkKey("10.0.0.0/8"), RouteTable.networkKey("10.0.0.0/16"))
        XCTAssertNotEqual(RouteTable.networkKey("10.0.0.0/8"), RouteTable.networkKey("11.0.0.0/8"))
        XCTAssertNotEqual(RouteTable.networkKey("0.0.0.0/0"), RouteTable.networkKey("::/0"))
        for malformed in ["10.0.0.0/33", "not-an-ip", "10.0.0.0/8/1", "fd00::/129", ""] {
            XCTAssertNil(RouteTable.networkKey(malformed), malformed)
        }
    }

    // MARK: - Browser proxy scoping

    func testScopingCoversEveryNameTheProxyMustSee() {
        let t = table(
            ("Office.Internal", ["*.corp.example", "Wiki.Example."], []),
            ("home.internal", [], []))
        XCTAssertEqual(
            t.proxyMatchDomains,
            ["corp.example", "flextunnel.internal", "home.internal", "office.internal", "wiki.example"])
        // No destination at all still scopes to the client's own namespace.
        XCTAssertEqual(table().proxyMatchDomains, ["flextunnel.internal"])
    }

    func testACatchAllOrANetworkTurnsScopingOff() {
        // Hostname patterns can't express either, so every host must reach the
        // proxy for the core to classify.
        XCTAssertNil(table(("a.internal", ["*"], [])).proxyMatchDomains)
        XCTAssertNil(table(("a.internal", ["corp.example"], []), ("b.internal", [], ["10.0.0.0/8"])).proxyMatchDomains)
        XCTAssertEqual(table(("a.internal", [], []), ("b.internal", [" * "], [])).catchAllDestination, "b.internal")
        XCTAssertNil(table(("a.internal", ["*.corp.example"], ["0.0.0.0/0"])).catchAllDestination)
    }

    // MARK: - Page routes

    func testPageRoutesFollowTheSessionsTable() {
        let t = table(("office.internal", ["*.corp.example"], ["10.0.0.0/8", "fd00::/8"]))
        func route(_ address: String) -> Route? {
            URL(string: address)?.host().map { t.route(host: BrowserNavigationDecider.normalizedHost($0)) }
        }
        XCTAssertEqual(route("https://wiki.corp.example/page"), .destination("office.internal"))
        XCTAssertEqual(route("http://office.internal:8080/"), .destination("office.internal"))
        XCTAssertEqual(route("https://corp.example/"), .direct)
        XCTAssertEqual(route("https://www.apple.com/"), .direct)
        XCTAssertEqual(route("http://10.1.2.3:8080/"), .destination("office.internal"))
        XCTAssertEqual(route("http://127.0.0.1:9/"), .direct)
        XCTAssertEqual(route("https://[fd00::5]:8006/"), .destination("office.internal"))
        XCTAssertEqual(route("https://[2001:db8::5]/"), .direct)
        XCTAssertEqual(route("http://flextunnel.internal/servers/office.internal/"), .status)
        XCTAssertEqual(route("http://status.flextunnel.internal/"), .reserved)
    }

    // MARK: - Helpers

    private func table(_ destinations: (String, [String], [String])...) -> RouteTable {
        RouteTable(entries: destinations.map {
            RouteTable.Entry(host: $0.0, domains: $0.1, cidrs: $0.2)
        })
    }

    /// Whether `host` is tunneled by a lone destination with these rules.
    private func tunneled(_ host: String, domains: [String] = [], cidrs: [String] = []) -> Bool {
        table(("only.internal", domains, cidrs)).destination(for: host) != nil
    }
}
