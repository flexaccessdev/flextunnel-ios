import XCTest
@testable import Flextunnel

/// What the address bar does with typed text (`BrowserModel.resolve`).
@MainActor
final class AddressResolutionTests: XCTestCase {
    func testBareHostGetsHTTPS() {
        XCTAssertEqual(resolved("wiki.corp.example"), "https://wiki.corp.example")
        XCTAssertEqual(resolved("wiki.corp.example:8443/path?q=1"), "https://wiki.corp.example:8443/path?q=1")
    }

    func testExplicitSchemesAreKept() {
        XCTAssertEqual(resolved("http://intranet.example/"), "http://intranet.example/")
        XCTAssertEqual(resolved("  https://example.com  "), "https://example.com")
    }

    func testOnionUsesHTTP() {
        XCTAssertEqual(resolved("abc.onion"), "http://abc.onion")
        XCTAssertEqual(resolved("ABC.ONION:8080/x"), "http://ABC.ONION:8080/x")
    }

    func testLocalhostAndIPLiterals() {
        XCTAssertEqual(resolved("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(resolved("10.0.0.5:8080"), "https://10.0.0.5:8080")
        XCTAssertEqual(resolved("[fdb8::1]:8006"), "https://[fdb8::1]:8006")
    }

    /// A destination may be named with a single label. Typed with or without
    /// a scheme it is an address: as a search, the name, port and path of a
    /// private address would go to the search engine.
    func testANameTheSessionRoutesIsAnAddressNotASearch() {
        let hosts: Set<String> = ["office", "nas"]
        func resolved(_ text: String) -> String? {
            BrowserModel.resolve(text, privateHosts: hosts)?.absoluteString
        }
        XCTAssertEqual(resolved("http://office:8080/settings"), "http://office:8080/settings")
        XCTAssertEqual(resolved("https://Office/"), "https://Office/")
        XCTAssertEqual(resolved("office:8080/settings"), "https://office:8080/settings")
        XCTAssertEqual(resolved("nas"), "https://nas")
        // A name the session doesn't route is still a search.
        XCTAssertEqual(BrowserModel.resolve("http://intranet:8080/x", privateHosts: hosts)?.host(), "duckduckgo.com")
        XCTAssertEqual(BrowserModel.resolve("intranet", privateHosts: hosts)?.host(), "duckduckgo.com")
        XCTAssertEqual(BrowserModel.resolve("office hours", privateHosts: hosts)?.host(), "duckduckgo.com")
    }

    /// A private address the URL parser refuses (an invalid IDNA label, say)
    /// is an error, not a search that would leak it.
    func testAnInvalidPrivateAddressIsNeverASearch() {
        let hosts: Set<String> = ["office"]
        for text in ["http://xn--a.localhost.flextunnel.internal:8080/settings",
                     "xn--a.localhost.flextunnel.internal:8080/settings",
                     "https://user@XN--A.localhost.flextunnel.internal./x",
                     "ftp://nas.localhost.flextunnel.internal",
                     "ftp://office/x"] {
            XCTAssertNil(BrowserModel.resolve(text, privateHosts: hosts), text)
        }
        XCTAssertEqual(
            BrowserModel.resolve("http://nas.localhost.flextunnel.internal:8080/x")?.absoluteString,
            "http://nas.localhost.flextunnel.internal:8080/x")
    }

    func testAnythingElseIsASearch() throws {
        for query in ["flextunnel docs", "intranet", "3.14", "ftp://files.example"] {
            let url = try XCTUnwrap(BrowserModel.resolve(query), query)
            XCTAssertEqual(url.host(), "duckduckgo.com", query)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, query)
        }
    }

    func testBlankInputResolvesToNothing() {
        XCTAssertNil(BrowserModel.resolve(""))
        XCTAssertNil(BrowserModel.resolve("   "))
    }

    private func resolved(_ text: String) -> String? {
        BrowserModel.resolve(text)?.absoluteString
    }
}
