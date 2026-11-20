import XCTest
@testable import Flextunnel

/// The destination rules `ClientStore` checks before saving. They repeat the
/// core's (`validate_destination_host` and the table checks in
/// `crates/flextunnel-core/src/proxy/route_table.rs`), so what the editor
/// accepts is what a session then starts with.
@MainActor
final class ClientStoreTests: XCTestCase {
    private var store: ClientStore!

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        store = ClientStore(directory: directory)
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.destinations.isEmpty)
        XCTAssertEqual(store.authKeyID, "")
        XCTAssertEqual(store.relayURLs, "")
    }

    func testSaveNormalizesTheFields() {
        XCTAssertNil(store.save(destination(
            host: " Office.Internal ", node: " node-a\n",
            domains: [" *.corp.example ", "", "*.CORP.example", "wiki.example"],
            cidrs: [" 10.0.0.0/8 "])))
        let saved = store.destinations[0]
        XCTAssertEqual(saved.host, "office.internal")
        XCTAssertEqual(saved.serverNodeID, "node-a")
        XCTAssertEqual(saved.routedDomains, ["*.corp.example", "wiki.example"], "blanks and repeats dropped")
        XCTAssertEqual(saved.routedCIDRs, ["10.0.0.0/8"])
        XCTAssertEqual(
            store.routeTable.route(host: "a.corp.example"), .destination("office.internal"))
    }

    func testSaveReplacesByIDAndDeleteRemoves() {
        var first = destination(host: "a.internal", node: "node-a")
        XCTAssertNil(store.save(first))
        XCTAssertNil(store.save(destination(host: "b.internal", node: "node-b")))

        first.routedDomains = ["db.example"]
        XCTAssertNil(store.save(first), "a destination doesn't collide with itself")
        XCTAssertEqual(store.destinations.map(\.host), ["a.internal", "b.internal"])
        XCTAssertEqual(store.destinations[0].routedDomains, ["db.example"])

        store.delete(id: first.id)
        XCTAssertEqual(store.destinations.map(\.host), ["b.internal"])
    }

    func testHostMustBeANameTheTableCanOwn() {
        for host in ["", "  ", "10.0.0.1", "[fd00::1]", "localhost", "a.localhost",
                     "flextunnel.internal", "x.flextunnel.internal",
                     "a..b", "office.internal.", "-a.internal", "has space.internal", "*.internal"] {
            XCTAssertNotNil(store.save(destination(host: host, node: "node-a")), "\(host) was accepted")
        }
        XCTAssertTrue(store.destinations.isEmpty)
        // Underscores are fine for internal names, as is a single label.
        XCTAssertNil(store.save(destination(host: "my_nas", node: "node-a")))
    }

    func testServerNodeIDIsRequiredAndUnique() {
        XCTAssertNotNil(store.save(destination(host: "a.internal", node: " ")))
        XCTAssertNil(store.save(destination(host: "a.internal", node: "node-a")))
        XCTAssertEqual(
            store.save(destination(host: "b.internal", node: "NODE-A"))?.message,
            "a.internal already reaches that server.")
        XCTAssertEqual(
            store.save(destination(host: "A.Internal", node: "node-b"))?.message,
            "Another destination is already named a.internal.")
    }

    func testDomainRulesAreNamesNotAddresses() {
        for rule in ["10.0.0.1", "[fd00::1]", "*.*.example", "a..b", "has space.example",
                     "flextunnel.internal", "*.flextunnel.internal", "a.internal"] {
            XCTAssertNotNil(
                store.save(destination(host: "a.internal", node: "node-a", domains: [rule])),
                "\(rule) was accepted")
        }
        XCTAssertNil(store.save(destination(
            host: "a.internal", node: "node-a", domains: ["*", "*.corp.example", "db.example."])))
    }

    func testIPRangesMustParse() {
        for rule in ["10.0.0.0/33", "not-an-ip", "corp.example", "fd00::/129"] {
            XCTAssertNotNil(
                store.save(destination(host: "a.internal", node: "node-a", cidrs: [rule])),
                "\(rule) was accepted")
        }
        XCTAssertNil(store.save(destination(
            host: "a.internal", node: "node-a", cidrs: ["10.0.0.0/8", "192.168.1.5", "fd00::/8"])))
    }

    func testARuleBelongsToOneDestination() {
        XCTAssertNil(store.save(destination(
            host: "a.internal", node: "node-a", domains: ["*.corp.example"], cidrs: ["10.0.0.0/8"])))
        XCTAssertEqual(
            store.save(destination(host: "b.internal", node: "node-b", domains: ["*.Corp.Example."]))?.message,
            "*.Corp.Example. is already routed through a.internal.")
        XCTAssertEqual(
            store.save(destination(host: "b.internal", node: "node-b", cidrs: ["10.0.0.0/8"]))?.message,
            "10.0.0.0/8 is already routed through a.internal.")
        // A destination's own name always means that server, so no rule may claim it.
        XCTAssertNotNil(store.save(destination(host: "b.internal", node: "node-b", domains: ["a.internal"])))
        // Nesting is fine: the more specific rule wins.
        XCTAssertNil(store.save(destination(
            host: "b.internal", node: "node-b", domains: ["*.dev.corp.example"], cidrs: ["10.1.0.0/16"])))
        XCTAssertEqual(store.routeTable.route(host: "x.dev.corp.example"), .destination("b.internal"))
        XCTAssertEqual(store.routeTable.route(host: "x.corp.example"), .destination("a.internal"))
    }

    func testRulesFieldSplitsOnLinesCommasAndSpaces() {
        XCTAssertEqual(
            ClientStore.splitRules("*.corp.example\n db.example, wiki.example  10.0.0.0/8\n\n"),
            ["*.corp.example", "db.example", "wiki.example", "10.0.0.0/8"])
        XCTAssertEqual(ClientStore.splitRules("  \n"), [])
    }

    // MARK: - Helpers

    private func destination(
        host: String, node: String, domains: [String] = [], cidrs: [String] = []
    ) -> ClientStore.Destination {
        ClientStore.Destination(
            id: UUID().uuidString, host: host, serverNodeID: node,
            routedDomains: domains, routedCIDRs: cidrs)
    }
}
