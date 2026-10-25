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
