import XCTest

/// End-to-end browser tests against a real flextunnel server on this Mac.
///
/// `ci/e2e.sh` starts the server and a fixture site behind its host alias
/// `e2e.flextunnel.test` — a name only the server resolves, so a page that
/// loads came through the tunnel — and passes the server id, a client secret
/// and the site URL in through `TEST_RUNNER_FLEXTUNNEL_E2E_*`, along with a
/// second server that has no routed set, a third whose set is a CIDR, and a
/// control endpoint that stops and restarts a server. Run directly from Xcode
/// without them, every test skips.
final class BrowserE2ETests: XCTestCase {
    /// Which of `ci/e2e.sh`'s servers a test connects to.
    private enum Server {
        /// Routes the fixture site's host alias.
        case routed
        /// Has no routed set, so only the reserved `flextunnel.internal`
        /// namespace goes through the tunnel.
        case emptySet
        /// Routes a CIDR (TEST-NET-3), so the browser sends every page to the
        /// in-app proxy.
        case cidr

        /// Its name on `ci/e2e.sh`'s control endpoint, for one it can stop.
        var controlName: String? {
            switch self {
            case .routed: "routed"
            case .cidr: "cidr"
            case .emptySet: nil
            }
        }
    }

    private var app: XCUIApplication!
    private var nodes: [Server: String] = [:]
    private var site: String!
    /// A loopback port nothing listens on, for a direct connection that fails.
    private var closedPort: String!
    /// `ci/e2e.sh`'s control endpoint, which stops and restarts a server.
    private var control: String!

    /// The handshake goes through iroh discovery, so allow it some time.
    private static let connectTimeout: TimeInterval = 90
    private static let loadTimeout: TimeInterval = 30
    /// The core holds a tunneled request up to 45s for a reconnect before
    /// failing it, and the page's error comes after that.
    private static let outageFailureTimeout: TimeInterval = 90

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let node = env["FLEXTUNNEL_E2E_SERVER_NODE_ID"],
              let emptyNode = env["FLEXTUNNEL_E2E_EMPTY_SERVER_NODE_ID"],
              let cidrNode = env["FLEXTUNNEL_E2E_CIDR_SERVER_NODE_ID"],
              let control = env["FLEXTUNNEL_E2E_CONTROL"],
              let secret = env["FLEXTUNNEL_E2E_AUTH_SECRET"],
              let site = env["FLEXTUNNEL_E2E_SITE"],
              let closedPort = env["FLEXTUNNEL_E2E_CLOSED_PORT"] else {
            throw XCTSkip("Run through ci/e2e.sh, which starts the local flextunnel server.")
        }
        nodes = [.routed: node, .emptySet: emptyNode, .cidr: cidrNode]
        self.site = site
        self.closedPort = closedPort
        self.control = control
        app = XCUIApplication()
        app.launchEnvironment["FLEXTUNNEL_E2E_AUTH_SECRET"] = secret
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Tests

    func testLoadsTunneledPageAndReportsItsRoute() {
        connect()
        open(site + "/")
        waitForPageText("flextunnel e2e home")

        snapshot("page")
        app.buttons["browser.siteSecurity"].tap()
        let route = app.staticTexts.matching(identifier: "browser.siteRoute").firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        XCTAssertEqual(route.label, "Through the tunnel")
    }

    func testHideToolbarsGivesThePageTheScreenUntilTheStripIsTapped() {
        connect()
        open(site + "/")
        waitForPageText("flextunnel e2e home")
        app.webViews.links["Go to page two"].tap()
        waitForPageText("flextunnel e2e page two")

        chooseMenuItem("Hide Toolbars")

        let strip = app.buttons["browser.showToolbars"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        XCTAssertTrue((strip.value as? String ?? "").hasPrefix("e2e.flextunnel.test"), "strip shows the full host")
        snapshot("toolbars-hidden")
        XCTAssertFalse(app.buttons["browser.address"].exists)
        XCTAssertFalse(app.buttons["browser.back"].exists)
        XCTAssertFalse(app.buttons["browser.tunnelStatus"].exists)

        strip.tap()
        XCTAssertTrue(app.buttons["browser.address"].waitForExistence(timeout: 5))
        app.buttons["browser.back"].tap()
        waitForPageText("flextunnel e2e home")
    }

    func testBottomBarStepsAsideForTheKeyboard() {
        connect()
        open(site + "/")
        waitForPageText("flextunnel e2e home")
        XCTAssertTrue(app.buttons["browser.back"].exists)

        app.webViews.textFields.firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["browser.back"])
        waitForExpectations(timeout: 5)

        // Done (✓) on WebKit's form accessory bar ends editing; the bar returns.
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["browser.back"].waitForExistence(timeout: 5))
    }

    func testTunnelStatusSheetShowsTheTunnelSetAndThisPage() {
        connect()
        open(site + "/")
        waitForPageText("flextunnel e2e home")

        app.buttons["browser.tunnelStatus"].tap()
        let title = app.staticTexts["tunnelStatus.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Connected")
        XCTAssertTrue(app.staticTexts["e2e.flextunnel.test"].exists)
        XCTAssertTrue(app.staticTexts["Through the tunnel"].exists)
        snapshot("tunnel-status")

        app.buttons["tunnelStatus.connectionPath"].tap()
        XCTAssertTrue(app.navigationBars["Connection path"].waitForExistence(timeout: 5))
        app.navigationBars["Connection path"].buttons["Done"].tap()
        app.navigationBars["Tunnel"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["browser.address"].waitForExistence(timeout: 5))
    }

    func testLibraryCollectsBookmarksHistoryAndDownloads() {
        connect()
        open(site + "/")
        waitForPageText("flextunnel e2e home")

        // Bookmark the page from the menu.
        chooseMenuItem("Add Bookmark")
        let save = app.navigationBars["Add Bookmark"].buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        // Download the fixture archive through the prompt.
        app.webViews.links["Download archive"].tap()
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: Self.loadTimeout))
        download.tap()

        app.buttons["browser.library"].tap()
        let section = app.segmentedControls["library.section"]
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["E2E Home"].waitForExistence(timeout: 5), "bookmark listed")

        section.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 5))
        snapshot("library-history")
        XCTAssertTrue(app.staticTexts["E2E Home"].exists, "history entry listed")

        let search = app.searchFields.firstMatch
        search.tap()
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: search)
        waitForExpectations(timeout: 5)
        search.typeText("no-such-page")
        XCTAssertTrue(app.staticTexts["No Results for \u{201C}no-such-page\u{201D}"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["E2E Home"].exists, "search filters history")
        app.buttons["Close"].firstMatch.tap()

        section.buttons["Downloads"].tap()
        XCTAssertTrue(app.staticTexts["sample.zip"].waitForExistence(timeout: Self.loadTimeout))
    }

    func testFailurePageSaysHowTheHostIsRouted() {
        connect()

        // Tunneled, but the server can't resolve it.
        open(site.replacingOccurrences(of: "://e2e.", with: "://missing.e2e.") + "/")
        let hint = app.staticTexts.matching(identifier: "browser.failureRoute").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: Self.loadTimeout))
        XCTAssertTrue(hint.label.contains("Reached through the tunnel"), hint.label)
        snapshot("failure-tunneled")

        // Off the tunnel set: goes out directly, and nothing listens there.
        open("http://127.0.0.1:\(closedPort!)/")
        XCTAssertTrue(hint.waitForExistence(timeout: Self.loadTimeout))
        let direct = NSPredicate(format: "label CONTAINS 'Connected directly'")
        expectation(for: direct, evaluatedWith: hint)
        waitForExpectations(timeout: Self.loadTimeout)
        snapshot("failure-direct")
    }

    func testEmptyTunnelSetTunnelsOnlyTheReservedNamespace() {
        connect(to: .emptySet)

        // The server's built-in loopback name reaches the fixture site, which
        // listens only on the server's localhost.
        let port = URLComponents(string: site)!.port!
        open("http://localhost.flextunnel.internal:\(port)/")
        waitForPageText("flextunnel e2e home")

        app.buttons["browser.tunnelStatus"].tap()
        // The sheet opens at half height over a lazy list, so the tunnel set
        // section isn't laid out until it has been scrolled into view.
        let sheet = app.collectionViews["tunnelStatus.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let empty = app.staticTexts["tunnelStatus.emptyTunnelSet"]
        for _ in 0..<3 where !empty.exists {
            sheet.swipeUp()
        }
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(empty.label, "Nothing but flextunnel.internal")
        XCTAssertTrue(app.staticTexts["Through the tunnel"].exists, "this page's route")
        snapshot("tunnel-status-empty-set")
        app.navigationBars["Tunnel"].buttons["Done"].tap()

        // The routed server's alias is off this set: it goes out directly,
        // where the device's DNS can't resolve it.
        open(site + "/")
        let hint = app.staticTexts.matching(identifier: "browser.failureRoute").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: Self.loadTimeout))
        let direct = NSPredicate(format: "label CONTAINS 'Connected directly'")
        expectation(for: direct, evaluatedWith: hint)
        waitForExpectations(timeout: Self.loadTimeout)
    }

    /// `localhost` is in the tunnel set and also answers directly. While the
    /// tunnel is down a tunneled page fails rather than falling back to that
    /// direct path, and an off-list host keeps loading; once the tunnel is
    /// back the failed page reloads on its own.
    func testTunneledHostNeverFallsBackDirectWhileTheTunnelIsDown() {
        connect()
        let tunneled = "http://localhost:\(sitePort)"
        open(tunneled + "/")
        waitForPageText("flextunnel e2e home")

        takeDown(.routed)
        // Off the set (an IP literal, and the set has no CIDRs): unaffected.
        open("http://127.0.0.1:\(sitePort)/page2.html")
        waitForPageText("flextunnel e2e page two")

        // A URL never loaded before, so no cached copy can stand in for it.
        open(tunneled + "/?during-outage")
        let hint = app.staticTexts.matching(identifier: "browser.failureRoute").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: Self.outageFailureTimeout), "the tunneled page never failed")
        XCTAssertTrue(hint.label.contains("isn't connected right now"), hint.label)
        XCTAssertFalse(app.webViews.staticTexts["flextunnel e2e home"].exists, "the tunneled page loaded directly")
        snapshot("failure-outage")

        bringBack(.routed)
        waitForPageText("flextunnel e2e home")
    }

    /// With a CIDR in the set the tunnel status says what IP ranges cover, and
    /// every page goes through the in-app proxy — which still dials off-list
    /// hosts directly while the tunnel is down. (Loopback and this device's
    /// own addresses are never proxied, so no local IP can stand in for a
    /// tunneled one here; `ProxyConfigurationTests` covers IP-address URLs.)
    func testCIDRSetExplainsIPRangesAndKeepsOffListHostsLoading() {
        connect(to: .cidr)

        app.buttons["browser.tunnelStatus"].tap()
        let sheet = app.collectionViews["tunnelStatus.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let note = app.staticTexts["tunnelStatus.cidrNote"]
        for _ in 0..<3 where !note.exists {
            sheet.swipeUp()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.contains("IP-address URLs"), note.label)
        snapshot("tunnel-status-cidr-set")
        app.navigationBars["Tunnel"].buttons["Done"].tap()

        let offList = "http://localhost:\(sitePort)"
        open(offList + "/")
        waitForPageText("flextunnel e2e home")

        takeDown(.cidr)
        open(offList + "/page2.html")
        waitForPageText("flextunnel e2e page two")
        bringBack(.cidr)
    }

    func testDisconnectFromTunnelStatusReturnsToSetup() {
        connect()
        disconnect()
        XCTAssertFalse(app.buttons["browser.tunnelStatus"].exists)
    }

    func testStartingAgainRightAfterDisconnectConnects() {
        connect()
        disconnect()
        // Straight back in: the old session may still be tearing down, and the
        // core runs one instance at a time, so the new start must wait for that
        // rather than be refused.
        startSession()
        open(site + "/")
        waitForPageText("flextunnel e2e home")
    }

    // MARK: - Helpers

    private var sitePort: Int { URLComponents(string: site)!.port! }

    /// Stops `server` and waits for the browser to see its tunnel go down.
    /// The server is started again when the test ends, should it fail first.
    private func takeDown(_ server: Server) {
        controlServer(server, "stop")
        addTeardownBlock { [self] in controlServer(server, "start") }
        expectation(for: NSPredicate(format: "value != 'Connected'"), evaluatedWith: app.buttons["browser.tunnelStatus"])
        waitForExpectations(timeout: Self.connectTimeout)
    }

    /// Starts `server` again and waits for the tunnel to reconnect.
    private func bringBack(_ server: Server) {
        controlServer(server, "start")
        expectation(for: NSPredicate(format: "value == 'Connected'"), evaluatedWith: app.buttons["browser.tunnelStatus"])
        waitForExpectations(timeout: Self.connectTimeout)
    }

    /// Stops or starts `server` through `ci/e2e.sh`'s control endpoint, and
    /// waits until it has.
    private func controlServer(_ server: Server, _ action: String) {
        var request = URLRequest(url: URL(string: "\(control!)/\(server.controlName!)/\(action)")!)
        request.httpMethod = "POST"
        let done = expectation(description: "\(action) \(server)")
        var code = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        XCTAssertEqual(code, 200, "control \(action) \(server)")
    }

    /// Launches the app pointed at `server` (the app's E2E launch hook fills
    /// the setup screen in), starts a browser session and waits for the tunnel
    /// to come up.
    private func connect(to server: Server = .routed) {
        app.launchEnvironment["FLEXTUNNEL_E2E_SERVER_NODE_ID"] = nodes[server]
        app.launch()
        startSession()
    }

    /// Taps the setup screen's Start and waits for the tunnel to come up.
    private func startSession() {
        // The CTA sits below the fold, and the setup Form is lazy: the button
        // isn't in the hierarchy until it has been scrolled into view.
        let start = app.buttons["setup.start"]
        XCTAssertTrue(app.navigationBars["flextunnel"].waitForExistence(timeout: 10))
        for _ in 0..<5 where !start.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(start.isHittable, "Start button never scrolled into view")
        start.tap()

        let status = app.buttons["browser.tunnelStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: Self.connectTimeout))
        expectation(for: NSPredicate(format: "value == 'Connected'"), evaluatedWith: status)
        waitForExpectations(timeout: Self.connectTimeout)
    }

    /// Ends the session from the tunnel status sheet, back to the setup screen.
    private func disconnect() {
        app.buttons["browser.tunnelStatus"].tap()
        let disconnect = app.buttons["tunnelStatus.disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        disconnect.tap()
        XCTAssertTrue(app.navigationBars["flextunnel"].waitForExistence(timeout: 10))
    }

    /// Opens the ⋯ menu and picks `title` once the menu has finished
    /// animating in — a tap mid-animation is dropped.
    private func chooseMenuItem(_ title: String) {
        app.buttons["browser.menu"].tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: item)
        waitForExpectations(timeout: 5)
        item.tap()
    }

    /// Keeps a screenshot in the result bundle (build/e2e/run/results.xcresult)
    /// for reviewing the chrome by eye, in light and dark.
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func open(_ address: String) {
        app.buttons["browser.address"].tap()
        let field = app.textFields["browser.addressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Editing starts from the current page's address; clear it first.
        let clear = app.buttons["Clear address"]
        if clear.waitForExistence(timeout: 1) { clear.tap() }
        field.typeText(address + "\n")
    }

    private func waitForPageText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.webViews.staticTexts[text].waitForExistence(timeout: Self.loadTimeout),
            "page text \"\(text)\" never appeared",
            file: file, line: line)
    }
}
