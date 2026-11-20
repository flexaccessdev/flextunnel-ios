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
            host: " Office.Internal ", node: " \(Self.nodeID("node-a"))\n",
            domains: [" *.corp.example ", "", "*.CORP.example", "wiki.example"],
            cidrs: [" 10.0.0.0/8 "])))
        let saved = store.destinations[0]
        XCTAssertEqual(saved.host, "office.internal")
        XCTAssertEqual(saved.serverNodeID, Self.nodeID("node-a"))
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
        XCTAssertEqual(
            store.save(destination(host: "a.internal", node: " "))?.message, "Server node id is required.")
        XCTAssertNil(store.save(destination(host: "a.internal", node: "node-a")))
        XCTAssertEqual(
            store.save(destination(host: "b.internal", node: "node-a"))?.message,
            "a.internal already reaches that server.")
        XCTAssertEqual(
            store.save(destination(host: "A.Internal", node: "node-b"))?.message,
            "Another destination is already named a.internal.")
    }

    /// An id the core could not read stops every session from starting, so
    /// it is refused when saved — a new destination and an edit alike — and
    /// the list stays as it was.
    func testAServerNodeIDMustBeOneTheCoreReads() {
        let valid = Self.nodeID("node-a")
        for invalid in ["not-an-id", "office.internal", String(valid.dropLast()), valid + "0", valid.uppercased(),
                        String(repeating: "g", count: 64), String(repeating: "A", count: 51),
                        String(repeating: "A", count: 51) + "B", String(repeating: "1", count: 52)] {
            let refused = store.save(destination(host: "a.internal", node: invalid))?.message ?? ""
            XCTAssertTrue(refused.hasPrefix("That is not a server node id."), "\(invalid) was accepted")
        }
        XCTAssertTrue(store.destinations.isEmpty)

        XCTAssertNil(store.save(destination(host: "a.internal", node: valid)))
        var edited = store.destinations[0]
        edited.serverNodeID = "not-an-id"
        XCTAssertNotNil(store.save(edited))
        XCTAssertEqual(store.destinations[0].serverNodeID, valid)
        // Both of the core's spellings are accepted.
        XCTAssertNil(store.save(destination(host: "b.internal", node: String(repeating: "a", count: 52))))
        XCTAssertNil(store.save(destination(host: "c.internal", node: String(repeating: "B", count: 51) + "A")))
    }

    /// The core reads a node id as lowercase hex or as base32 in either case,
    /// and refuses the same key on two destinations however each is written.
    func testOneServerIsOneDestinationHoweverItsIDIsWritten() {
        let hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        let base32 = "AEBAGBAFAYDQQCIKBMGA2DQPCAIREEYUCULBOGAZDINRYHI6D4QA"
        XCTAssertEqual(ClientStore.nodeKey(base32), hex)
        XCTAssertEqual(ClientStore.nodeKey(" \(base32.lowercased())\n"), hex)
        XCTAssertEqual(ClientStore.nodeKey(hex), hex)

        XCTAssertNil(store.save(destination(host: "a.internal", node: hex)))
        for same in [base32, base32.lowercased()] {
            XCTAssertEqual(
                store.save(destination(host: "b.internal", node: same))?.message,
                "a.internal already reaches that server.")
        }
        // Another key is another server.
        let other = String(repeating: "A", count: 52)
        XCTAssertEqual(ClientStore.nodeKey(other), String(repeating: "0", count: 64))
        XCTAssertNil(store.save(destination(host: "b.internal", node: other)))
        // Text that is no key is never read as one: base32 with stray
        // trailing bits, the wrong length, uppercase hex.
        for invalid in [String(repeating: "A", count: 51) + "B", String(repeating: "A", count: 51), hex.uppercased()] {
            XCTAssertNil(ClientStore.nodeKey(invalid), invalid)
        }
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
        for rule in ["10.0.0.0/33", "not-an-ip", "corp.example", "fd00::/129", "10.1/16", "10.0.0.0/-0"] {
            XCTAssertNotNil(
                store.save(destination(host: "a.internal", node: "node-a", cidrs: [rule])),
                "\(rule) was accepted")
        }
        XCTAssertNil(store.save(destination(
            host: "a.internal", node: "node-a", cidrs: ["10.0.0.0/8", "192.168.1.5", "fd00::/8"])))
    }

    /// An IP range is written as the network it routes: address bits beyond
    /// the prefix are refused, with the standard spelling offered.
    func testIPRangesAreWrittenWithoutHostBits() {
        XCTAssertEqual(
            store.save(destination(host: "a.internal", node: "node-a", cidrs: ["10.1.2.3/8"]))?.message,
            "10.1.2.3/8 has address bits beyond its prefix. Use 10.0.0.0/8.")
        XCTAssertEqual(
            store.save(destination(host: "a.internal", node: "node-a", cidrs: ["192.168.1.5/24"]))?.message,
            "192.168.1.5/24 has address bits beyond its prefix. Use 192.168.1.0/24.")
        XCTAssertEqual(
            store.save(destination(host: "a.internal", node: "node-a", cidrs: ["fd00::1/8"]))?.message,
            "fd00::1/8 has address bits beyond its prefix. Use fd00::/8.")
        XCTAssertTrue(store.destinations.isEmpty)
        // One address is its own network.
        XCTAssertNil(store.save(destination(
            host: "a.internal", node: "node-a", cidrs: ["192.168.1.5", "192.168.2.5/32", "fd00::1"])))
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

    func testADestinationsNameAndAnExactRuleNeverCoincide() {
        // The rule first, then a destination by that name.
        XCTAssertNil(store.save(destination(host: "a.internal", node: "node-a", domains: ["DB.Example."])))
        XCTAssertEqual(
            store.save(destination(host: "db.example", node: "node-b"))?.message,
            "a.internal routes db.example as a domain, but a destination's own name always means that server itself.")

        // The destination first, then a rule naming it.
        XCTAssertNil(store.save(destination(host: "b.internal", node: "node-b")))
        XCTAssertNotNil(store.save(destination(host: "c.internal", node: "node-c", domains: ["b.internal"])))

        // Renaming an existing destination onto another's rule.
        var renamed = store.destinations[1]
        renamed.host = "Db.Example"
        XCTAssertNotNil(store.save(renamed))
        XCTAssertEqual(store.destinations.map(\.host), ["a.internal", "b.internal"])

        // A wildcard that covers a destination's name is fine: the name wins.
        XCTAssertNil(store.save(destination(host: "c.internal", node: "node-c", domains: ["*.lab.example"])))
        XCTAssertNil(store.save(destination(host: "nas.lab.example", node: "node-d")))
        XCTAssertEqual(store.routeTable.route(host: "nas.lab.example"), .destination("nas.lab.example"))
        XCTAssertEqual(store.routeTable.route(host: "pi.lab.example"), .destination("c.internal"))
    }

    func testOneNetworkBelongsToOneDestinationHoweverItIsSpelled() {
        XCTAssertNil(store.save(destination(
            host: "a.internal", node: "node-a",
            cidrs: ["10.0.0.0/8", "192.168.1.5", "fd00::/8", "2001:db8::1"])))
        for same in [" 10.0.0.0/8", "192.168.1.5/32", "FD00:0:0::/8", "2001:DB8:0:0:0:0:0:1/128"] {
            XCTAssertEqual(
                store.save(destination(host: "b.internal", node: "node-b", cidrs: [same]))?.message,
                "\(same.trimmingCharacters(in: .whitespaces)) is already routed through a.internal.")
        }
        // Distinct nested prefixes are different rules: the longer one wins.
        XCTAssertNil(store.save(destination(
            host: "b.internal", node: "node-b", cidrs: ["10.1.0.0/16", "192.168.1.0/24", "fd00:1::/32"])))
        XCTAssertEqual(store.routeTable.route(host: "10.1.2.3"), .destination("b.internal"))
        XCTAssertEqual(store.routeTable.route(host: "10.2.2.3"), .destination("a.internal"))
        XCTAssertEqual(store.routeTable.route(host: "192.168.1.5"), .destination("a.internal"))
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
            id: UUID().uuidString, host: host,
            serverNodeID: node.hasPrefix("node-") ? Self.nodeID(node) : node,
            routedDomains: domains, routedCIDRs: cidrs)
    }

    /// A well-formed node id for a test's `node-…` label: 32 bytes made of
    /// the label's own, as hex.
    private static func nodeID(_ label: String) -> String {
        let bytes = Array(label.utf8)
        return (0..<32).map { String(format: "%02x", bytes[$0 % bytes.count]) }.joined()
    }
}
