import XCTest
@testable import Flextunnel

/// The destination rules `ClientStore` checks before saving. They repeat the
/// core's (`validate_destination_name` and the table checks in
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
            name: " Office ", node: " \(Self.nodeID("node-a"))\n",
            domains: [" *.corp.example ", "", "*.CORP.example", "wiki.example"],
            cidrs: [" 10.0.0.0/8 "])))
        let saved = store.destinations[0]
        XCTAssertEqual(saved.name, "office")
        XCTAssertEqual(saved.serverNodeID, Self.nodeID("node-a"))
        XCTAssertEqual(saved.routedDomains, ["*.corp.example", "wiki.example"], "blanks and repeats dropped")
        XCTAssertEqual(saved.routedCIDRs, ["10.0.0.0/8"])
        XCTAssertEqual(
            store.routeTable.route(host: "a.corp.example"), .destination("office"))
    }

    func testSaveReplacesByIDAndDeleteRemoves() {
        var first = destination(name: "a", node: "node-a")
        XCTAssertNil(store.save(first))
        XCTAssertNil(store.save(destination(name: "b", node: "node-b")))

        first.routedDomains = ["db.example"]
        XCTAssertNil(store.save(first), "a destination doesn't collide with itself")
        XCTAssertEqual(store.destinations.map(\.name), ["a", "b"])
        XCTAssertEqual(store.destinations[0].routedDomains, ["db.example"])

        store.delete(id: first.id)
        XCTAssertEqual(store.destinations.map(\.name), ["b"])
    }

    func testNameMustBeOneDNSLabel() {
        for name in ["", "  ", "10.0.0.1", "[fd00::1]", "a.localhost", "office.internal",
                     "flextunnel.internal", "my_nas", "-a", "a-", "has space", "*", "caf\u{e9}",
                     String(repeating: "a", count: 64)] {
            XCTAssertNotNil(store.save(destination(name: name, node: "node-a")), "\(name) was accepted")
        }
        XCTAssertTrue(store.destinations.isEmpty)
        XCTAssertNil(store.save(destination(name: "nas-2", node: "node-a")))
        XCTAssertNil(store.save(destination(name: String(repeating: "b", count: 63), node: "node-b")))
        XCTAssertNil(store.save(destination(name: "0", node: "node-c")))
    }

    func testServerNodeIDIsRequiredAndUnique() {
        XCTAssertEqual(
            store.save(destination(name: "a", node: " "))?.message, "Server node id is required.")
        XCTAssertNil(store.save(destination(name: "a", node: "node-a")))
        XCTAssertEqual(
            store.save(destination(name: "b", node: "node-a"))?.message,
            "a already reaches that server.")
        XCTAssertEqual(
            store.save(destination(name: "A", node: "node-b"))?.message,
            "Another destination is already named a.")
    }

    /// An id the core could not read stops every session from starting, so
    /// it is refused when saved — a new destination and an edit alike — and
    /// the list stays as it was.
    func testAServerNodeIDMustBeOneTheCoreReads() {
        let valid = Self.nodeID("node-a")
        for invalid in ["not-an-id", "office.internal", String(valid.dropLast()), valid + "0", valid.uppercased(),
                        String(repeating: "g", count: 64), String(repeating: "A", count: 51),
                        String(repeating: "A", count: 51) + "B", String(repeating: "1", count: 52)] {
            let refused = store.save(destination(name: "a", node: invalid))?.message ?? ""
            XCTAssertTrue(refused.hasPrefix("That is not a server node id."), "\(invalid) was accepted")
        }
        XCTAssertTrue(store.destinations.isEmpty)

        XCTAssertNil(store.save(destination(name: "a", node: valid)))
        var edited = store.destinations[0]
        edited.serverNodeID = "not-an-id"
        XCTAssertNotNil(store.save(edited))
        XCTAssertEqual(store.destinations[0].serverNodeID, valid)
        // Both of the core's spellings are accepted.
        XCTAssertNil(store.save(destination(name: "b", node: String(repeating: "a", count: 52))))
        XCTAssertNil(store.save(destination(name: "c", node: String(repeating: "B", count: 51) + "A")))
    }

    /// The core reads a node id as lowercase hex or as base32 in either case,
    /// and refuses the same key on two destinations however each is written.
    func testOneServerIsOneDestinationHoweverItsIDIsWritten() {
        let hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        let base32 = "AEBAGBAFAYDQQCIKBMGA2DQPCAIREEYUCULBOGAZDINRYHI6D4QA"
        XCTAssertEqual(ClientStore.nodeKey(base32), hex)
        XCTAssertEqual(ClientStore.nodeKey(" \(base32.lowercased())\n"), hex)
        XCTAssertEqual(ClientStore.nodeKey(hex), hex)

        XCTAssertNil(store.save(destination(name: "a", node: hex)))
        for same in [base32, base32.lowercased()] {
            XCTAssertEqual(
                store.save(destination(name: "b", node: same))?.message,
                "a already reaches that server.")
        }
        // Another key is another server.
        let other = String(repeating: "A", count: 52)
        XCTAssertEqual(ClientStore.nodeKey(other), String(repeating: "0", count: 64))
        XCTAssertNil(store.save(destination(name: "b", node: other)))
        // Text that is no key is never read as one: base32 with stray
        // trailing bits, the wrong length, uppercase hex.
        for invalid in [String(repeating: "A", count: 51) + "B", String(repeating: "A", count: 51), hex.uppercased()] {
            XCTAssertNil(ClientStore.nodeKey(invalid), invalid)
        }
    }

    func testDomainRulesAreNamesNotAddresses() {
        for rule in ["10.0.0.1", "[fd00::1]", "*.*.example", "a..b", "has space.example",
                     "flextunnel.internal", "*.flextunnel.internal", "a.localhost.flextunnel.internal"] {
            XCTAssertNotNil(
                store.save(destination(name: "a", node: "node-a", domains: [rule])),
                "\(rule) was accepted")
        }
        XCTAssertNil(store.save(destination(
            name: "a", node: "node-a", domains: ["*", "*.corp.example", "db.example."])))
    }

    /// The core reads the rule as saved, so it is checked as written: the
    /// Kelvin sign lowercases to an ASCII `k`, but the core refuses it.
    func testADomainRuleIsCheckedAsWritten() {
        for rule in ["\u{212A}.example", "*.\u{212A}.example"] {
            XCTAssertNotNil(
                store.save(destination(name: "a", node: "node-a", domains: [rule])),
                "\(rule) was accepted")
        }
        XCTAssertNil(store.save(destination(
            name: "a", node: "node-a", domains: ["K.example", "*.Corp.example"])))
    }

    func testIPRangesMustParse() {
        for rule in ["10.0.0.0/33", "not-an-ip", "corp.example", "fd00::/129", "10.1/16", "10.0.0.0/-0"] {
            XCTAssertNotNil(
                store.save(destination(name: "a", node: "node-a", cidrs: [rule])),
                "\(rule) was accepted")
        }
        XCTAssertNil(store.save(destination(
            name: "a", node: "node-a", cidrs: ["10.0.0.0/8", "192.168.1.5", "fd00::/8"])))
    }

    /// An IP range is written as the network it routes: address bits beyond
    /// the prefix are refused, with the standard spelling offered.
    func testIPRangesAreWrittenWithoutHostBits() {
        XCTAssertEqual(
            store.save(destination(name: "a", node: "node-a", cidrs: ["10.1.2.3/8"]))?.message,
            "10.1.2.3/8 has address bits beyond its prefix. Use 10.0.0.0/8.")
        XCTAssertEqual(
            store.save(destination(name: "a", node: "node-a", cidrs: ["192.168.1.5/24"]))?.message,
            "192.168.1.5/24 has address bits beyond its prefix. Use 192.168.1.0/24.")
        XCTAssertEqual(
            store.save(destination(name: "a", node: "node-a", cidrs: ["fd00::1/8"]))?.message,
            "fd00::1/8 has address bits beyond its prefix. Use fd00::/8.")
        XCTAssertTrue(store.destinations.isEmpty)
        // One address is its own network.
        XCTAssertNil(store.save(destination(
            name: "a", node: "node-a", cidrs: ["192.168.1.5", "192.168.2.5/32", "fd00::1"])))
    }

    func testARuleBelongsToOneDestination() {
        XCTAssertNil(store.save(destination(
            name: "a", node: "node-a", domains: ["*.corp.example"], cidrs: ["10.0.0.0/8"])))
        XCTAssertEqual(
            store.save(destination(name: "b", node: "node-b", domains: ["*.Corp.Example."]))?.message,
            "*.Corp.Example. is already routed through a.")
        XCTAssertEqual(
            store.save(destination(name: "b", node: "node-b", cidrs: ["10.0.0.0/8"]))?.message,
            "10.0.0.0/8 is already routed through a.")
        // A destination's loopback name is in the reserved namespace, so no
        // rule may claim it; the bare name is just another host.
        XCTAssertNotNil(store.save(destination(
            name: "b", node: "node-b", domains: ["a.localhost.flextunnel.internal"])))
        // Nesting is fine: the more specific rule wins.
        XCTAssertNil(store.save(destination(
            name: "b", node: "node-b", domains: ["*.dev.corp.example"], cidrs: ["10.1.0.0/16"])))
        XCTAssertEqual(store.routeTable.route(host: "x.dev.corp.example"), .destination("b"))
        XCTAssertEqual(store.routeTable.route(host: "x.corp.example"), .destination("a"))
    }

    /// A name is only a label: a rule may name the same word, and a
    /// destination may be called what another routes — the loopback name is
    /// under `flextunnel.internal`, which no rule can reach.
    func testADestinationsNameNeverClashesWithARule() {
        XCTAssertNil(store.save(destination(name: "a", node: "node-a", domains: ["db", "*.lab.example"])))
        XCTAssertNil(store.save(destination(name: "db", node: "node-b", domains: ["a"])))
        XCTAssertEqual(store.routeTable.route(host: "db"), .destination("a"))
        XCTAssertEqual(store.routeTable.route(host: "a"), .destination("db"))
        XCTAssertEqual(store.routeTable.route(host: "db.localhost.flextunnel.internal"), .destination("db"))
        XCTAssertEqual(store.routeTable.route(host: "pi.lab.example"), .destination("a"))

        // Renaming onto another destination's name is refused, in any case.
        var renamed = store.destinations[1]
        renamed.name = "A"
        XCTAssertEqual(store.save(renamed)?.message, "Another destination is already named a.")
        XCTAssertEqual(store.destinations.map(\.name), ["a", "db"])
    }

    func testOneNetworkBelongsToOneDestinationHoweverItIsSpelled() {
        XCTAssertNil(store.save(destination(
            name: "a", node: "node-a",
            cidrs: ["10.0.0.0/8", "192.168.1.5", "fd00::/8", "2001:db8::1"])))
        for same in [" 10.0.0.0/8", "192.168.1.5/32", "FD00:0:0::/8", "2001:DB8:0:0:0:0:0:1/128"] {
            XCTAssertEqual(
                store.save(destination(name: "b", node: "node-b", cidrs: [same]))?.message,
                "\(same.trimmingCharacters(in: .whitespaces)) is already routed through a.")
        }
        // Distinct nested prefixes are different rules: the longer one wins.
        XCTAssertNil(store.save(destination(
            name: "b", node: "node-b", cidrs: ["10.1.0.0/16", "192.168.1.0/24", "fd00:1::/32"])))
        XCTAssertEqual(store.routeTable.route(host: "10.1.2.3"), .destination("b"))
        XCTAssertEqual(store.routeTable.route(host: "10.2.2.3"), .destination("a"))
        XCTAssertEqual(store.routeTable.route(host: "192.168.1.5"), .destination("a"))
    }

    func testRulesFieldSplitsOnLinesCommasAndSpaces() {
        XCTAssertEqual(
            ClientStore.splitRules("*.corp.example\n db.example, wiki.example  10.0.0.0/8\n\n"),
            ["*.corp.example", "db.example", "wiki.example", "10.0.0.0/8"])
        XCTAssertEqual(ClientStore.splitRules("  \n"), [])
    }

    // MARK: - Helpers

    private func destination(
        name: String, node: String, domains: [String] = [], cidrs: [String] = []
    ) -> ClientStore.Destination {
        ClientStore.Destination(
            id: UUID().uuidString, name: name,
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
