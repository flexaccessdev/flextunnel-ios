import XCTest

/// End-to-end browser tests against real flextunnel servers on this Mac.
///
/// `ci/e2e.sh` starts three servers — one routing a fixture site behind its
/// host alias `e2e.flextunnel.test`, a name only that server resolves, so a
/// page that loads came through it; a plain one that routes nothing; and one
/// whose set is a CIDR — plus a control endpoint that stops and restarts a
/// server, and passes their ids, a client secret and the site URL in through
/// `TEST_RUNNER_FLEXTUNNEL_E2E_*`. Each test picks the destinations the app
/// starts with: routing is the client's own configuration. Run directly from
/// Xcode without them, every test skips.
final class BrowserE2ETests: XCTestCase {
    /// One of `ci/e2e.sh`'s servers.
    private enum Server {
        /// Routes the fixture site's host alias, and `localhost`.
        case routed
        /// Routes nothing. Its own loopback is still reachable, by the
        /// loopback name of the destination that points at it.
        case plain
        /// Routes a CIDR (TEST-NET-3).
        case cidr

        /// Its name on `ci/e2e.sh`'s control endpoint, for one it can stop.
        var controlName: String? {
            switch self {
            case .routed: "routed"
            case .cidr: "cidr"
            case .plain: nil
            }
        }
    }

    /// The destinations a session is started with.
    private enum Destinations {
        /// `siteName` for the routed server, with the names it routes, and
        /// `plainName` for the plain one: hostname rules only, so the browser
        /// scopes its proxy to them.
        case names
        /// `cidrName` for the CIDR server, with its network: the browser sends
        /// every page to the in-app proxy.
        case network
    }

    private static let siteName = "site"
    private static let plainName = "plain"
    /// The plain server's own loopback: in the address bar it has to load as
    /// an address rather than go out as a search.
    private static let plainLoopback = "plain.localhost.flextunnel.internal"
    private static let cidrName = "cidr"

    private var app: XCUIApplication!
    private var nodes: [Server: String] = [:]
    private var site: String!
    /// A loopback port nothing listens on, for a direct connection that fails.
    private var closedPort: String!
    /// `ci/e2e.sh`'s control endpoint, which stops and restarts a server.
    private var control: String!
    /// Where the app writes its core's log (see `E2ELaunchConfig.redirectLog`),
    /// which says how the in-app proxy routed each request that reached it.
    private var appLog: URL!
    /// A free loopback port for the app to forward. The simulator shares this
    /// Mac's loopback, so the test reaches the forward itself.
    private var forwardPort: String!

    private static let startTimeout: TimeInterval = 30
    /// A destination's first load connects its server through iroh discovery,
    /// so allow it some time.
    private static let loadTimeout: TimeInterval = 60
    /// The core holds a tunneled request up to 45s for its destination to
    /// connect before failing it, and the page's error comes after that.
    private static let outageFailureTimeout: TimeInterval = 90

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let node = env["FLEXTUNNEL_E2E_SERVER_NODE_ID"],
              let plainNode = env["FLEXTUNNEL_E2E_PLAIN_SERVER_NODE_ID"],
              let cidrNode = env["FLEXTUNNEL_E2E_CIDR_SERVER_NODE_ID"],
              let control = env["FLEXTUNNEL_E2E_CONTROL"],
              let secret = env["FLEXTUNNEL_E2E_AUTH_SECRET"],
              let site = env["FLEXTUNNEL_E2E_SITE"],
              let closedPort = env["FLEXTUNNEL_E2E_CLOSED_PORT"],
              let forwardPort = env["FLEXTUNNEL_E2E_FORWARD_PORT"] else {
            throw XCTSkip("Run through ci/e2e.sh, which starts the local flextunnel servers.")
        }
        nodes = [.routed: node, .plain: plainNode, .cidr: cidrNode]
        self.site = site
        self.closedPort = closedPort
        self.forwardPort = forwardPort
        self.control = control
        app = XCUIApplication()
        app.launchEnvironment["FLEXTUNNEL_E2E_AUTH_SECRET"] = secret
        let appLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("flextunnel-e2e-app-\(UUID().uuidString).log")
        self.appLog = appLog
        addTeardownBlock { try? FileManager.default.removeItem(at: appLog) }
        app.launchEnvironment["FLEXTUNNEL_E2E_APP_LOG"] = appLog.path
        app.launchEnvironment["RUST_LOG"] = "warn,flextunnel_core=debug"
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
        waitForTunnelStatus("Connected")

        snapshot("page")
        app.buttons["browser.siteSecurity"].tap()
        let route = app.staticTexts.matching(identifier: "browser.siteRoute").firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        XCTAssertEqual(route.label, "Through \(Self.siteName)")
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

    func testTunnelStatusSheetShowsDestinationsAndThisPage() {
        connect()
        open(site + "/")
        waitForPageText("flextunnel e2e home")
        waitForTunnelStatus("Connected")

        app.buttons["browser.tunnelStatus"].tap()
        let title = app.staticTexts["tunnelStatus.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Connected")
        XCTAssertTrue(app.staticTexts["e2e.flextunnel.test"].exists)
        XCTAssertTrue(app.staticTexts["Through \(Self.siteName)"].exists)
        snapshot("tunnel-status")

        // Only the destination the page went through is connected.
        XCTAssertEqual(destinationState(Self.siteName), "Connected")
        XCTAssertEqual(destinationState(Self.plainName), "Idle")
        snapshot("tunnel-status-destinations")

        let path = app.buttons["tunnelStatus.connectionPath.\(Self.siteName)"]
        reveal(path)
        path.tap()
        XCTAssertTrue(app.navigationBars["Connection path"].waitForExistence(timeout: 5))
        app.navigationBars["Connection path"].buttons["Done"].tap()
        app.navigationBars["Tunnel"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["browser.address"].waitForExistence(timeout: 5))
    }

    /// Starting a session connects nothing; a destination's server is
    /// connected by the first request to it — here to the destination's
    /// loopback name, which is the server's loopback whatever that server
    /// routes.
    func testDestinationConnectsWhenFirstUsedAndItsLoopbackNameIsTheServersLoopback() {
        connect()
        XCTAssertEqual(app.buttons["browser.tunnelStatus"].value as? String, "Ready")
        app.buttons["browser.tunnelStatus"].tap()
        let title = app.staticTexts["tunnelStatus.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Ready")
        XCTAssertEqual(destinationState(Self.siteName), "Idle")
        XCTAssertEqual(destinationState(Self.plainName), "Idle")
        snapshot("tunnel-status-ready")
        app.navigationBars["Tunnel"].buttons["Done"].tap()

        // The fixture site listens only on the Mac's loopback, which is the
        // plain server's own — a server that routes nothing at all.
        open("http://\(Self.plainLoopback):\(sitePort)/")
        waitForPageText("flextunnel e2e home")
        waitForTunnelStatus("Connected")

        app.buttons["browser.tunnelStatus"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Through \(Self.plainName)"].exists, "this page's route")
        XCTAssertEqual(destinationState(Self.plainName), "Connected")
        XCTAssertEqual(destinationState(Self.siteName), "Idle", "a destination nothing used was connected")
        app.navigationBars["Tunnel"].buttons["Done"].tap()

        // Using the other destination connects it alongside the first: one
        // session holds both servers at once.
        open(site + "/page2.html")
        waitForPageText("flextunnel e2e page two")
        app.buttons["browser.tunnelStatus"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        waitForDestinationState(Self.siteName, "Connected")
        waitForDestinationState(Self.plainName, "Connected")
        snapshot("tunnel-status-both-connected")
        app.navigationBars["Tunnel"].buttons["Done"].tap()

        // And the first is still usable, on the connection it already has.
        open("http://\(Self.plainLoopback):\(sitePort)/")
        waitForPageText("flextunnel e2e home")
    }

    /// `flextunnel.internal` is the client's own status page, answered by the
    /// in-app proxy without connecting anything; a destination server's page
    /// is fetched through it, which connects that destination.
    func testStatusPagesAreAnsweredByTheClientAndFetchedFromAServer() {
        connect()
        open("http://flextunnel.internal/")
        waitForPageText("flextunnel client status")
        for host in [Self.siteName, Self.plainName] {
            let listed = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
            XCTAssertTrue(listed.waitForExistence(timeout: 5), "\(host) is not on the client status page")
        }
        snapshot("client-status-page")
        XCTAssertEqual(app.buttons["browser.tunnelStatus"].value as? String, "Ready",
                       "reading the client's status connected a destination")

        app.buttons["browser.tunnelStatus"].tap()
        let serverPage = app.buttons["tunnelStatus.serverStatusPage.\(Self.plainName)"]
        XCTAssertTrue(app.staticTexts["tunnelStatus.title"].waitForExistence(timeout: 5))
        reveal(serverPage)
        serverPage.tap()
        waitForPageText("flextunnel server status")
        XCTAssertTrue(app.webViews.staticTexts[nodes[.plain]!].waitForExistence(timeout: 5),
                      "the page is not the plain server's")
        snapshot("server-status-page")
        waitForTunnelStatus("Connected")
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

        // Routed through the site destination, but its server can't resolve it.
        open(site.replacingOccurrences(of: "://e2e.", with: "://missing.e2e.") + "/")
        let hint = app.staticTexts.matching(identifier: "browser.failureRoute").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: Self.loadTimeout))
        // The page can fail within a moment of its destination connecting,
        // before the app's next status poll shows it connected: the hint
        // settles then.
        let reached = NSPredicate(format: "label CONTAINS %@", "Reached through \(Self.siteName)")
        expectation(for: reached, evaluatedWith: hint)
        waitForExpectations(timeout: Self.loadTimeout)
        snapshot("failure-tunneled")

        // On no destination's route: goes out directly, and nothing listens there.
        open("http://127.0.0.1:\(closedPort!)/")
        XCTAssertTrue(hint.waitForExistence(timeout: Self.loadTimeout))
        let direct = NSPredicate(format: "label CONTAINS 'Connected directly'")
        expectation(for: direct, evaluatedWith: hint)
        waitForExpectations(timeout: Self.loadTimeout)
        snapshot("failure-direct")
    }

    /// `localhost` is routed through the site destination and also answers
    /// directly. While that server is down a page routed through it fails
    /// rather than falling back to the direct path, and a host on no route
    /// keeps loading; once the server is back, trying again loads the page.
    func testRoutedHostNeverFallsBackDirectWhileItsServerIsDown() {
        connect()
        let tunneled = "http://localhost:\(sitePort)"
        open(tunneled + "/")
        waitForPageText("flextunnel e2e home")
        waitForTunnelStatus("Connected")

        takeDown(.routed)
        // On no route (an IP literal, and no destination routes a network): unaffected.
        open("http://127.0.0.1:\(sitePort)/page2.html")
        waitForPageText("flextunnel e2e page two")

        // A URL never loaded before, so no cached copy can stand in for it.
        open(tunneled + "/?during-outage")
        let hint = app.staticTexts.matching(identifier: "browser.failureRoute").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: Self.outageFailureTimeout), "the routed page never failed")
        XCTAssertTrue(hint.label.contains("\(Self.siteName), which isn't connected right now"), hint.label)
        XCTAssertFalse(app.webViews.staticTexts["flextunnel e2e home"].exists, "the routed page loaded directly")
        snapshot("failure-outage")

        // Nothing reconnects a server on its own: the destination is tried
        // again when the page is.
        bringBack(.routed)
        let home = app.webViews.staticTexts["flextunnel e2e home"]
        for _ in 0..<3 where !home.exists {
            let retry = app.buttons["Try Again"]
            if retry.waitForExistence(timeout: 5) { retry.tap() }
            _ = home.waitForExistence(timeout: Self.outageFailureTimeout)
        }
        XCTAssertTrue(home.exists, "the page never loaded once its server was back")
        waitForTunnelStatus("Connected")
    }

    /// With a network among the routes the tunnel status says what IP ranges
    /// cover, and every page goes through the in-app proxy — which still dials
    /// hosts on no route directly while the server is down, and holds an
    /// address in the range for its destination: the server's log shows it
    /// arriving once the server is back. (The range is TEST-NET-3, which
    /// nothing answers, so the log is the only evidence of the path: loopback
    /// and this device's own addresses are never proxied, so no local IP can
    /// stand in.)
    ///
    /// A page on no route loads the same whether WebKit sent it to the proxy
    /// or went around it, so that it loads proves nothing about the path: the
    /// app's own log does, where the proxy records each request it sends out
    /// directly. The name `localhost` is proxied like any other hostname — it
    /// is the loopback *addresses* the system keeps to itself.
    func testNetworkRouteTunnelsItsIPRangeAndKeepsOtherHostsLoading() {
        connect(with: .network)

        app.buttons["browser.tunnelStatus"].tap()
        XCTAssertTrue(app.staticTexts["tunnelStatus.title"].waitForExistence(timeout: 5))
        let note = app.staticTexts["tunnelStatus.unscopedNote"]
        reveal(note)
        XCTAssertTrue(note.label.contains("IP-address URLs"), note.label)
        snapshot("tunnel-status-network-route")
        app.navigationBars["Tunnel"].buttons["Done"].tap()

        let unrouted = "http://localhost:\(sitePort)"
        open(unrouted + "/")
        waitForPageText("flextunnel e2e home")
        XCTAssertTrue(
            waitForDirectRequests(to: "localhost", atLeast: 1),
            "the page on no route did not go through the in-app proxy")

        let tunneledAddress = "203.0.113.9"
        XCTAssertFalse(serverLog(.cidr).contains(tunneledAddress))

        takeDown(.cidr)
        let before = directRequests(to: "localhost")
        open(unrouted + "/page2.html")
        waitForPageText("flextunnel e2e page two")
        XCTAssertTrue(
            waitForDirectRequests(to: "localhost", atLeast: before + 1),
            "with its server down, the page on no route did not go through the in-app proxy")

        open("http://\(tunneledAddress)/")
        bringBack(.cidr)
        XCTAssertTrue(
            waitForServerLog(.cidr, toContain: tunneledAddress, timeout: Self.outageFailureTimeout),
            "\(tunneledAddress) never came through \(Self.cidrName)")
    }

    /// The setup screen lists the destinations, and its editor checks a new
    /// one against the others before it can be saved.
    func testAddingADestinationValidatesItAgainstTheOthers() {
        launch(with: .names)
        XCTAssertTrue(app.navigationBars["flextunnel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["setup.destination.\(Self.siteName)"].exists)
        XCTAssertTrue(app.buttons["setup.destination.\(Self.plainName)"].exists)

        app.buttons["setup.addDestination"].tap()
        let name = app.textFields["destination.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let save = app.buttons["destination.save"]
        XCTAssertFalse(save.isEnabled, "an empty destination can be saved")

        let node = app.textFields["destination.serverNodeID"]
        node.tap()
        node.typeText(nodes[.cidr]!)

        // A name another destination already has.
        name.tap()
        name.typeText(Self.siteName)
        let error = app.staticTexts["destination.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("already named"), error.label)
        XCTAssertFalse(save.isEnabled)
        snapshot("destination-editor-error")

        // Typing on makes it a name of its own.
        name.typeText("-lab")
        // A multi-line field isn't a plain text field to the test runner.
        let ranges = app.descendants(matching: .any)["destination.routedCIDRs"]
        ranges.tap()
        ranges.typeText("203.0.113.0/24")
        XCTAssertFalse(error.exists)
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let added = app.buttons["setup.destination.\(Self.siteName)-lab"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        snapshot("setup-destinations")
    }

    /// The editor fills a destination's routes from the server it names: the
    /// server is asked once, before the destination exists and with no
    /// session running, and what it routes lands in the fields to be saved.
    func testFetchFromServerFillsInWhatTheServerRoutes() {
        launch(with: .names)
        XCTAssertTrue(app.navigationBars["flextunnel"].waitForExistence(timeout: 10))
        app.buttons["setup.addDestination"].tap()
        let node = app.textFields["destination.serverNodeID"]
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        let fetch = app.buttons["destination.fetchRoutes"]
        XCTAssertFalse(fetch.isEnabled, "there is no server to ask yet")

        node.tap()
        node.typeText(nodes[.cidr]!)
        XCTAssertTrue(fetch.isEnabled)
        fetch.tap()

        // A multi-line field isn't a plain text field to the test runner.
        let ranges = app.descendants(matching: .any)["destination.routedCIDRs"]
        let filled = NSPredicate(format: "value == %@", "203.0.113.0/24")
        wait(for: [expectation(for: filled, evaluatedWith: ranges)], timeout: Self.loadTimeout)
        let note = app.staticTexts["destination.fetchRoutesNote"]
        XCTAssertTrue(note.label.contains("0 domain(s) and 1 IP range(s)"), note.label)
        snapshot("destination-editor-fetched")

        let name = app.textFields["destination.name"]
        name.tap()
        name.typeText(Self.cidrName)
        app.buttons["destination.save"].tap()
        XCTAssertTrue(app.buttons["setup.destination.\(Self.cidrName)"].waitForExistence(timeout: 5))
    }

    /// A port forward goes through the destination that routes its host — here
    /// a destination's loopback name, which is the server's loopback — and one to a
    /// host no destination routes is switched back off, saying so.
    func testPortForwardGoesThroughTheDestinationThatRoutesItsHost() {
        launch(with: .names)
        XCTAssertTrue(app.navigationBars["flextunnel"].waitForExistence(timeout: 10))
        let mode = app.buttons["setup.mode.proxyOnly"]
        for _ in 0..<5 where !mode.isHittable {
            app.swipeUp()
        }
        mode.tap()
        let start = app.buttons["setup.start"]
        for _ in 0..<5 where !start.isHittable {
            app.swipeUp()
        }
        start.tap()
        XCTAssertTrue(app.navigationBars["Port Forwarding"].waitForExistence(timeout: Self.startTimeout))

        // Nothing routes this host, so the forward never binds.
        addForward(localPort: closedPort, host: "unrouted.example.com", port: "\(sitePort)")
        // The forwards are below the session and its destinations, in a lazy
        // list: a row isn't in the hierarchy until it is scrolled into view.
        let route = app.staticTexts["forward.route"]
        scrollTo(route)
        XCTAssertEqual(route.label, "no route")
        let refused = NSPredicate(format: "label CONTAINS 'no destination routes unrouted.example.com'")
        expectation(for: refused, evaluatedWith: app.staticTexts["forward.status"])
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.switches["forward.enabled"].value as? String, "0", "an unrouted forward stayed on")
        snapshot("forward-no-route")

        // The fixture site listens on the Mac's loopback: the plain server's own.
        addForward(localPort: forwardPort, host: Self.plainLoopback, port: "\(sitePort)")
        scrollTo(app.staticTexts["via \(Self.plainName)"])
        XCTAssertTrue(
            waitForBody(of: "http://127.0.0.1:\(forwardPort!)/", toContain: "flextunnel e2e home"),
            "the forward never served the site")
        snapshot("forward-serving")

        let stop = app.buttons["Stop Forwarding"]
        scrollTo(stop)
        stop.tap()
        XCTAssertTrue(app.navigationBars["flextunnel"].waitForExistence(timeout: 10))
    }

    /// With custom relays the setup screen offers to turn their QUIC address
    /// discovery off, and the session started then says so of its relays.
    /// Nothing is loaded: the session starts without contacting a relay or a
    /// server.
    func testQuicAddrDiscoveryTurnedOffForCustomRelaysReachesTheSession() {
        launch(with: .names, relayURLs: "https://relay.e2e.flextunnel.test")
        XCTAssertTrue(app.navigationBars["flextunnel"].waitForExistence(timeout: 10))
        let discovery = app.switches["setup.relayQuicAddrDiscovery"]
        scrollTo(discovery)
        XCTAssertEqual(discovery.value as? String, "1", "on unless turned off")
        discovery.switches.firstMatch.tap()
        XCTAssertEqual(discovery.value as? String, "0")
        snapshot("setup-relay-quic-addr-discovery-off")

        startSession()
        app.buttons["browser.tunnelStatus"].tap()
        let relays = app.staticTexts["tunnelStatus.relays"]
        reveal(relays)
        XCTAssertTrue(relays.label.contains("https://relay.e2e.flextunnel.test"), relays.label)
        XCTAssertTrue(relays.label.contains("(no QUIC address discovery)"), relays.label)
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

    /// Stops `server` and waits for the browser to see no destination
    /// connected any more. The server is started again when the test ends,
    /// should it fail first.
    private func takeDown(_ server: Server) {
        controlServer(server, "stop")
        addTeardownBlock { [self] in controlServer(server, "start") }
        expectation(for: NSPredicate(format: "value != 'Connected'"), evaluatedWith: app.buttons["browser.tunnelStatus"])
        waitForExpectations(timeout: Self.loadTimeout)
    }

    /// Starts `server` again. Nothing connects to it until it is next used.
    private func bringBack(_ server: Server) {
        controlServer(server, "start")
    }

    /// Waits for the browser's tunnel button to read `value`.
    private func waitForTunnelStatus(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let reads = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: app.buttons["browser.tunnelStatus"])
        XCTAssertEqual(
            XCTWaiter().wait(for: [reads], timeout: Self.loadTimeout), .completed,
            "tunnel status never read \(value)", file: file, line: line)
    }

    /// The state the open tunnel status sheet shows for the destination `host`.
    private func destinationState(_ host: String) -> String {
        let state = app.staticTexts["tunnelStatus.state.\(host)"]
        reveal(state)
        return state.label
    }

    /// Waits for the open tunnel status sheet to show `state` for the
    /// destination `host`: the sheet follows the app's status poll, which can
    /// trail the page that connected the destination by a moment.
    private func waitForDestinationState(
        _ host: String, _ state: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let element = app.staticTexts["tunnelStatus.state.\(host)"]
        reveal(element, file: file, line: line)
        let shows = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", state), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [shows], timeout: Self.loadTimeout), .completed,
            "\(host) never read \(state)", file: file, line: line)
    }

    /// Scrolls the open tunnel status sheet until `element` is laid out: the
    /// sheet opens at half height over a lazy list, so what is below the fold
    /// isn't in the hierarchy until it has been scrolled into view.
    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = app.collectionViews["tunnelStatus.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<6 where !element.exists {
            sheet.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) never scrolled into view", file: file, line: line)
    }

    /// Scrolls the screen up until `element` is laid out and can be tapped.
    private func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) never scrolled into view", file: file, line: line)
    }

    /// Adds a port forward on the forwarding screen, switched on.
    private func addForward(localPort: String, host: String, port: String) {
        app.buttons["Add port forward"].tap()
        let local = app.textFields["forward.localPort"]
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        local.tap()
        local.typeText(localPort)
        let remoteHost = app.textFields["forward.remoteHost"]
        remoteHost.tap()
        remoteHost.typeText(host)
        let remotePort = app.textFields["forward.remotePort"]
        remotePort.tap()
        remotePort.typeText(port)
        let save = app.buttons["forward.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
    }

    /// Fetches `address` from the test runner, again and again until its body
    /// contains `text`: the first connection through a forward waits for the
    /// destination's server to connect.
    private func waitForBody(of address: String, toContain text: String) -> Bool {
        let deadline = Date().addingTimeInterval(Self.loadTimeout)
        repeat {
            let done = expectation(description: "GET \(address)")
            var body = ""
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.loadTimeout
            let session = URLSession(configuration: config)
            session.dataTask(with: URL(string: address)!) { data, _, _ in
                body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: Self.loadTimeout + 5)
            session.invalidateAndCancel()
            if body.contains(text) { return true }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return false
    }

    /// How many requests for `host` the in-app proxy has sent out directly so
    /// far, by the core's own account of each one.
    private func directRequests(to host: String) -> Int {
        let log = (try? String(contentsOf: appLog, encoding: .utf8)) ?? ""
        return log.components(separatedBy: "Direct (no destination routes it): Domain(\"\(host)\"").count - 1
    }

    /// Waits for the in-app proxy to have sent `count` requests for `host` out
    /// directly.
    private func waitForDirectRequests(to host: String, atLeast count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while directRequests(to: host) < count {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }

    /// Stops or starts `server` through `ci/e2e.sh`'s control endpoint, and
    /// waits until it has.
    private func controlServer(_ server: Server, _ action: String) {
        _ = controlRequest("POST", server, action)
    }

    /// `server`'s log so far, read through the control endpoint.
    private func serverLog(_ server: Server) -> String {
        controlRequest("GET", server, "log")
    }

    /// Polls `server`'s log until it contains `text`.
    private func waitForServerLog(_ server: Server, toContain text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !serverLog(server).contains(text) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 1)
        }
        return true
    }

    /// Sends `method` to the control endpoint's `/<server>/<action>` and
    /// returns the response body, asserting a 200.
    private func controlRequest(_ method: String, _ server: Server, _ action: String) -> String {
        var request = URLRequest(url: URL(string: "\(control!)/\(server.controlName!)/\(action)")!)
        request.httpMethod = method
        let done = expectation(description: "\(method) \(action) \(server)")
        var code = 0
        var body = ""
        URLSession.shared.dataTask(with: request) { data, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        XCTAssertEqual(code, 200, "control \(method) \(action) \(server)")
        return body
    }

    /// Launches the app with `destinations` (the app's E2E launch hook fills
    /// the setup screen in) and starts a browser session.
    private func connect(with destinations: Destinations = .names) {
        launch(with: destinations)
        startSession()
    }

    /// Launches the app with `destinations` on its setup screen, and
    /// `relayURLs` (comma-separated) in its relay field.
    private func launch(with destinations: Destinations, relayURLs: String = "") {
        let list: [[String: Any]]
        switch destinations {
        case .names:
            list = [
                [
                    "name": Self.siteName,
                    "server_node_id": nodes[.routed]!,
                    "routed_domains": ["e2e.flextunnel.test", "*.e2e.flextunnel.test", "localhost"],
                    "routed_cidrs": [String](),
                ],
                [
                    "name": Self.plainName,
                    "server_node_id": nodes[.plain]!,
                    "routed_domains": [String](),
                    "routed_cidrs": [String](),
                ],
            ]
        case .network:
            list = [
                [
                    "name": Self.cidrName,
                    "server_node_id": nodes[.cidr]!,
                    "routed_domains": [String](),
                    "routed_cidrs": ["203.0.113.0/24"],
                ],
            ]
        }
        let json = try! JSONSerialization.data(withJSONObject: list)
        app.launchEnvironment["FLEXTUNNEL_E2E_DESTINATIONS"] = String(decoding: json, as: UTF8.self)
        app.launchEnvironment["FLEXTUNNEL_E2E_RELAY_URLS"] = relayURLs
        app.launch()
    }

    /// Taps the setup screen's Start and waits for the browser. The session is
    /// running as soon as its listener is bound: no server is connected yet.
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
        XCTAssertTrue(status.waitForExistence(timeout: Self.startTimeout))
        waitForTunnelStatus("Ready")
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
