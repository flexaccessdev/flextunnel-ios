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
