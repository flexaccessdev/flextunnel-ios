import XCTest
@testable import Flextunnel

/// The config `ProxyController` hands `flextunnel_start`, as built from a
/// session's settings. Starting a session needs the core, and is covered by
/// the e2e UI tests.
final class SessionConfigTests: XCTestCase {
    private func settings(relayURLs: [String], quicAddrDiscovery: Bool) -> ProxyController.Settings {
        ProxyController.Settings(
            destinations: [.init(
                name: "office", serverNodeID: "node",
                routedDomains: ["*.corp.example"], routedCIDRs: [])],
            authKey: "ed25519-sec:abc",
            socksPort: 0,
            relayURLs: relayURLs,
            relayAuthToken: "",
            relayQuicAddrDiscovery: quicAddrDiscovery)
    }

    /// The config as the core reads it: through JSON, as it is sent.
    private func sent(_ s: ProxyController.Settings) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ProxyController.configDict(s))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testQuicAddrDiscoveryTurnedOffForCustomRelaysIsSent() throws {
        let config = try sent(settings(relayURLs: ["https://relay.example"], quicAddrDiscovery: false))
        XCTAssertEqual(config["relay_urls"] as? [String], ["https://relay.example"])
        XCTAssertEqual(config["relay_quic_addr_discovery"] as? Bool, false)
    }

    func testQuicAddrDiscoveryOnIsLeftToTheCoresDefault() throws {
        let config = try sent(settings(relayURLs: ["https://relay.example"], quicAddrDiscovery: true))
        XCTAssertTrue(config["relay_quic_addr_discovery"] is NSNull)
    }

    func testQuicAddrDiscoveryIsNotSentWithTheDefaultRelays() throws {
        let config = try sent(settings(relayURLs: [], quicAddrDiscovery: false))
        XCTAssertTrue(
            config["relay_quic_addr_discovery"] is NSNull,
            "the core refuses the setting with the default relays")
    }
}
