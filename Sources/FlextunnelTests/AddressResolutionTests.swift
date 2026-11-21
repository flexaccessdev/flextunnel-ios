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
        let hosts = routes(domains: ["office", "nas"])
        func resolved(_ text: String) -> String? {
            BrowserModel.resolve(text, routes: hosts)?.absoluteString
        }
        XCTAssertEqual(resolved("http://office:8080/settings"), "http://office:8080/settings")
        XCTAssertEqual(resolved("https://Office/"), "https://Office/")
        XCTAssertEqual(resolved("office:8080/settings"), "https://office:8080/settings")
        XCTAssertEqual(resolved("nas"), "https://nas")
        // A name the session doesn't route is still a search.
        XCTAssertEqual(BrowserModel.resolve("http://intranet:8080/x", routes: hosts)?.host(), "duckduckgo.com")
        XCTAssertEqual(BrowserModel.resolve("intranet", routes: hosts)?.host(), "duckduckgo.com")
        XCTAssertEqual(BrowserModel.resolve("office hours", routes: hosts)?.host(), "duckduckgo.com")
        // A `://` in the query is no scheme.
        XCTAssertEqual(resolved("office/?next=http://wiki.example"), "https://office/?next=http://wiki.example")
    }

    /// A private address the URL parser refuses (an invalid IDNA label, say)
    /// is an error, not a search that would leak it.
    func testAnInvalidPrivateAddressIsNeverASearch() {
        let hosts = routes(domains: ["office"])
        for text in ["http://xn--a.localhost.flextunnel.internal:8080/settings",
                     "xn--a.localhost.flextunnel.internal:8080/settings",
                     "https://user@XN--A.localhost.flextunnel.internal./x",
                     "ftp://nas.localhost.flextunnel.internal",
                     "ftp://office/x",
                     // A space in the path, not the host, keeps it an address.
                     "http://office/a b",
                     "office/a b",
                     // A `://` after the host is no scheme.
                     "office/a b?next=http://elsewhere.example",
                     // However malformed the port.
                     "http://nas.localhost.flextunnel.internal: 8080/settings",
                     "http://nas.localhost.flextunnel.internal::8080/settings",
                     "office: 8080/x"] {
            XCTAssertNil(BrowserModel.resolve(text, routes: hosts), text)
        }
        // A space in what would be the host makes it a search.
        XCTAssertEqual(BrowserModel.resolve("office hours/x", routes: hosts)?.host(), "duckduckgo.com")
        XCTAssertEqual(
            BrowserModel.resolve("http://nas.localhost.flextunnel.internal:8080/x")?.absoluteString,
            "http://nas.localhost.flextunnel.internal:8080/x")
    }

    /// Any rule counts, not just an exact name: a URL whose host a wildcard
    /// or an IP range routes is an error when it doesn't parse. A single word
    /// under `*`, or a number, is still a search.
    func testAURLAWildcardOrRangeRoutesIsNeverASearch() {
        let table = routes(domains: ["*.corp.example"], cidrs: ["10.0.0.0/8"])
        for text in ["http://wiki.corp.example/a b", "wiki.corp.example/a b",
                     "http://10.1.2.3/a b", "10.1.2.3: 80/x"] {
            XCTAssertNil(BrowserModel.resolve(text, routes: table), text)
        }
        for text in ["http://wiki.other.example/a b", "http://8.8.8.8/a b"] {
            XCTAssertEqual(BrowserModel.resolve(text, routes: table)?.host(), "duckduckgo.com", text)
        }
        let everything = routes(domains: ["*"])
        for text in ["intranet", "office hours", "3.14", "intranet/a b"] {
            XCTAssertEqual(BrowserModel.resolve(text, routes: everything)?.host(), "duckduckgo.com", text)
        }
        XCTAssertNil(BrowserModel.resolve("http://intranet/a b", routes: everything))
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

    /// One destination routing `domains` and `cidrs`.
    private func routes(domains: [String], cidrs: [String] = []) -> RouteTable {
        RouteTable(entries: [.init(name: "lab", domains: domains, cidrs: cidrs)])
    }
}
