import XCTest
@testable import Flextunnel

/// The two ends of `flextunnel_fetch_server_routes` as the app spells them:
/// the request it sends and the answer it reads. The call itself needs a
/// server, and is covered by the e2e UI tests.
final class ServerRoutesTests: XCTestCase {
    private func request(_ access: ServerRoutes.Access, node: String = "node") throws -> [String: Any] {
        let json = try XCTUnwrap(ServerRoutes.requestJSON(serverNodeID: node, access: access))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testRequestNamesTheServerTheKeyAndTheRelays() throws {
        let sent = try request(
            ServerRoutes.Access(
                authKey: "ed25519-sec:abc",
                relayURLs: ["https://a.example", "https://b.example"],
                relayAuthToken: " token\n"),
            node: " abcdef\n")
        XCTAssertEqual(sent["auth_key"] as? String, "ed25519-sec:abc")
        XCTAssertEqual(sent["server_node_id"] as? String, "abcdef")
        XCTAssertEqual(sent["relay_urls"] as? [String], ["https://a.example", "https://b.example"])
        XCTAssertEqual(sent["relay_auth_token"] as? String, "token")
    }

    func testRequestLeavesOutAnEmptyRelayToken() throws {
        let sent = try request(
            ServerRoutes.Access(authKey: "ed25519-sec:abc", relayURLs: [], relayAuthToken: "  "))
        XCTAssertTrue(sent["relay_auth_token"] is NSNull, "the core refuses a token without relays")
        XCTAssertEqual(sent["relay_urls"] as? [String], [])
    }

    func testAnswerIsReadIntoTheTwoLists() {
        let routes = ServerRoutes.parse(
            #"{"routed_domains":["*.corp.example","wiki.example"],"routed_cidrs":["10.0.0.0/8"]}"#)
        XCTAssertEqual(
            routes, ServerRoutes(domains: ["*.corp.example", "wiki.example"], cidrs: ["10.0.0.0/8"]))
        XCTAssertEqual(routes?.filledNote, "Filled in the server's 2 domain(s) and 1 IP range(s).")

        let nothing = ServerRoutes.parse(#"{"routed_domains":[],"routed_cidrs":[]}"#)
        XCTAssertEqual(nothing, ServerRoutes(domains: [], cidrs: []))
        XCTAssertEqual(nothing?.filledNote, "The server routes nothing beyond itself.")
    }

    /// The editor's fields split on commas and whitespace, and a server takes
    /// any text as an exact domain: an entry that would come back out of a
    /// field as something other than itself is not one to fill in.
    func testAnEntryTheFieldsWouldSplitIsFound() {
        XCTAssertNil(ServerRoutes(domains: ["*.corp.example", "*"], cidrs: ["10.0.0.0/8", "::/0"])
            .entryThatIsNotOneRule)
        XCTAssertNil(ServerRoutes(domains: [], cidrs: []).entryThatIsNotOneRule)
        XCTAssertEqual(
            ServerRoutes(domains: ["ok.example", "db.example, api.example"], cidrs: [])
                .entryThatIsNotOneRule,
            "db.example, api.example")
        XCTAssertEqual(
            ServerRoutes(domains: ["ok.example"], cidrs: ["10.0.0.0/8 192.168.0.0/16"])
                .entryThatIsNotOneRule,
            "10.0.0.0/8 192.168.0.0/16")
        XCTAssertEqual(ServerRoutes(domains: [""], cidrs: []).entryThatIsNotOneRule, "")
    }

    /// Padding around an entry is not part of the rule — the server trims it
    /// away too — so a padded entry is the one rule it is, not one the fields
    /// cannot hold.
    func testPaddingAroundAnEntryIsDropped() {
        let routes = ServerRoutes.parse(
            #"{"routed_domains":[" padded.example ","nas.example"],"routed_cidrs":[" 10.0.0.0/8\t"]}"#)
        XCTAssertEqual(
            routes,
            ServerRoutes(domains: ["padded.example", "nas.example"], cidrs: ["10.0.0.0/8"]))
        XCTAssertNil(routes?.entryThatIsNotOneRule)
    }

    /// The padding dropped is what the server drops, and no more. A zero-width
    /// space is not whitespace to the server: it is part of the name there,
    /// and trimming it away — as Foundation's whitespace set does — would
    /// make a rule the server does not have. Such an entry is kept as it is,
    /// and is not one to fill in, since saving would trim it after all.
    func testOnlyTheServersWhitespaceIsDropped() {
        XCTAssertEqual(ServerRoutes.serverTrimmed(" \t\u{A0}\u{3000}a.example\u{2028}\n"), "a.example")
        XCTAssertEqual(ServerRoutes.serverTrimmed("\u{200B}a.example\u{200B}"), "\u{200B}a.example\u{200B}")
        XCTAssertEqual(ServerRoutes.serverTrimmed(" \n"), "")
        // What Foundation would have made of it.
        XCTAssertEqual("\u{200B}a.example".trimmingCharacters(in: .whitespacesAndNewlines), "a.example")

        let routes = ServerRoutes.parse(#"{"routed_domains":[" \u200Ba.example"],"routed_cidrs":[]}"#)
        XCTAssertEqual(routes?.domains, ["\u{200B}a.example"])
        XCTAssertEqual(routes?.entryThatIsNotOneRule, "\u{200B}a.example")
    }

    /// Anything else is no answer, never an empty one to fill the editor with.
    func testAnswerMissingAListIsNotRead() {
        for answer in [
            "", "{}", "Signaling error: timed out", #"{"routed_domains":["a.example"]}"#,
            #"{"routed_domains":"a.example","routed_cidrs":[]}"#,
        ] {
            XCTAssertNil(ServerRoutes.parse(answer), answer)
        }
    }
}
