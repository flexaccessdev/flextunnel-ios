import Foundation
import Observation
import Security
import UIKit
import WebKit
import os.log

/// A single browser tab: an iOS 26 `WebPage` sharing `BrowserModel`'s data
/// store, whose `proxyConfigurations` routes tunnel-set hosts through the
/// in-app flextunnel SOCKS5 listener and lets everything else connect directly.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let page: WebPage

    /// Address-bar text for the active navigation. This intentionally does not
    /// mirror `page.url` blindly because provisional navigation failures can
    /// leave WebKit without a committed URL.
    var addressText = ""
    var loadFailure: BrowserLoadFailure?
    var certificateWarning: BrowserCertificateWarning?

    private let log = Logger(subsystem: "com.example.flextunnel", category: "webview")
    private let certificateTrustStore: BrowserCertificateTrustStore
    private let navigationDecider: BrowserNavigationDecider
    private let library: BrowserLibrary
    private var lastAttemptedURL: URL?

    /// When true, the home view is shown even though `page` still holds a loaded
    /// document — set by `goBack()` stepping off the first page, cleared by any
    /// load or by `goForward()` returning to the page.
    private var presentingHome = false

    /// Whether the current navigation has committed. WebKit publishes the target
    /// URL as soon as the provisional navigation starts — before any TLS
    /// handshake — so the security indicator must not trust `page.url` until the
    /// response has actually arrived over the negotiated connection.
    private var hasCommittedNavigation = false
    /// The document whose commit this tab last processed, so a commit the
    /// navigation stream dropped can be told apart from one already handled
    /// (see `recoverMissedCommit`).
    private var committedURL: URL?
    private var certificateWarningContinuation: CheckedContinuation<Bool, Never>?

    /// The host:port whose certificate warning the user declined (or that a
    /// newer navigation superseded). WebKit reports the cancelled challenge as
    /// a navigation failure; that failure is ours, not the page's, so it must
    /// not raise the failure screen — the tab has already returned to whatever
    /// it was showing. Consumed by the first matching error.
    private var declinedCertificateChallenge: (host: String, port: Int)?

    /// Drains `page.navigations` for the tab's whole lifetime, independent of
    /// which tab is selected. Cancelled when the tab is closed.
    private var observationTask: Task<Void, Never>?

    private init(
        page: WebPage,
        certificateTrustStore: BrowserCertificateTrustStore,
        navigationDecider: BrowserNavigationDecider,
        library: BrowserLibrary
    ) {
        self.page = page
        self.certificateTrustStore = certificateTrustStore
        self.navigationDecider = navigationDecider
        self.library = library
    }

    /// Build a tab on the shared data store, so cookies and logins carry across
    /// tabs and survive relaunch — and so the store's proxy configuration
    /// (owned by `BrowserModel`) applies to it.
    static func make(
        websiteDataStore: WKWebsiteDataStore,
        certificateTrustStore: BrowserCertificateTrustStore,
        library: BrowserLibrary,
        downloads: BrowserDownloadManager
    ) -> BrowserTab {
        var config = WebPage.Configuration()
        config.websiteDataStore = websiteDataStore

        let navigationDecider = BrowserNavigationDecider(certificateTrustStore: certificateTrustStore)
        let tab = BrowserTab(
            page: WebPage(configuration: config, navigationDecider: navigationDecider),
            certificateTrustStore: certificateTrustStore,
            navigationDecider: navigationDecider,
            library: library)
        navigationDecider.certificateWarningHandler = { [weak tab] warning in
            await tab?.requestCertificateWarning(warning) ?? false
        }
        navigationDecider.downloadHandler = { request, response in
            Task { await downloads.requestDownload(request, response: response) }
        }
        tab.observationTask = Task { [weak tab] in await tab?.observeNavigations() }
        return tab
    }

    /// Cancels the lifetime navigation observer. Called when the tab is closed.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        resolveCertificateWarning(allow: false)
    }

    // MARK: - Derived state (reads WebPage's @Observable properties)

    /// Page title, falling back to the host, then a placeholder.
    var displayTitle: String {
        if loadFailure != nil {
            return "Problem Loading Page"
        }
        let title = page.title
        if !title.isEmpty { return title }
        if let host = page.url?.host() { return host }
        if !addressText.isEmpty { return addressText }
        return "New Tab"
    }

    var displaySubtitle: String {
        if let host = loadFailure?.url.host() { return host }
        if let host = page.url?.host() { return host }
        return addressText.isEmpty ? "New Tab" : addressText
    }

    /// Back is enabled whenever we're off the home view: it either steps through
    /// the page's web history or, on the first page, returns to home.
    var canGoBack: Bool { !isHome }
    var canGoForward: Bool {
        if presentingHome && page.url != nil { return true }
        return !page.backForwardList.forwardList.isEmpty
    }

    var visibleURL: URL? {
        if presentingHome { return nil }
        return loadFailure?.url ?? page.url ?? lastAttemptedURL
    }

    /// True before the tab has navigated anywhere — no committed page, no
    /// attempted load, no failure. Drives the placeholder home view.
    var isHome: Bool {
        visibleURL == nil
    }

    var siteSecurity: BrowserSiteSecurity? {
        guard let url = page.url ?? loadFailure?.url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        guard scheme == "https" else {
            return .notSecure
        }

        if loadFailure != nil {
            return .notSecure
        }
        // No lock until the response has committed: only then has the TLS
        // handshake been confirmed for the URL in the address bar.
        guard hasCommittedNavigation else {
            return nil
        }

        let port = url.port ?? 443
        if certificateTrustStore.isTrusted(host: host, port: port) {
            return .certificateException
        }
        return .secure
    }

    // MARK: - Navigation

    func load(_ url: URL, displayAddress: String? = nil) {
        // A certificate interstitial still waiting on an answer belongs to the
        // navigation this one replaces; leaving it up would shadow the new page.
        resolveCertificateWarning(allow: false)
        presentingHome = false
        lastAttemptedURL = url
        addressText = displayAddress ?? url.absoluteString
        loadFailure = nil
        hasCommittedNavigation = false
        log.info("loading host \(Self.logHost(for: url), privacy: .public)")
        page.load(URLRequest(url: url))
    }

    func goBack() {
        // A failure or certificate screen sits over a document WebKit still
        // displays (a provisional failure never unloads the current page), and
        // that document is not in the back list — it is the current entry. So
        // back first uncovers it, like leaving Safari's error page, instead of
        // skipping past it into history.
        if loadFailure != nil || certificateWarning != nil {
            returnToDisplayedPage()
            return
        }
        // On the first page there's no web history to step into, so back
        // returns to the home view instead.
        guard let item = page.backForwardList.backList.last else {
            goHome()
            return
        }
        resolveCertificateWarning(allow: false)
        presentingHome = false
        lastAttemptedURL = item.url
        addressText = item.url.absoluteString
        loadFailure = nil
        page.load(item)
    }

    func goForward() {
        // Returning from home re-reveals the already-loaded page.
        if presentingHome, let url = page.url {
            presentingHome = false
            lastAttemptedURL = url
            addressText = url.absoluteString
            loadFailure = nil
            return
        }
        guard let item = page.backForwardList.forwardList.first else { return }
        resolveCertificateWarning(allow: false)
        lastAttemptedURL = item.url
        addressText = item.url.absoluteString
        loadFailure = nil
        page.load(item)
    }

    /// Reveals the home view without unloading `page`, so `goForward()` can
    /// return to it.
    private func goHome() {
        presentingHome = true
        loadFailure = nil
        addressText = ""
    }

    func reload() {
        if let failedURL = loadFailure?.url ?? lastAttemptedURL, loadFailure != nil {
            load(failedURL, displayAddress: addressText)
        } else {
            loadFailure = nil
            page.reload()
        }
    }

    func stop() {
        page.stopLoading()
    }

    func retryFailedLoad() {
        guard let url = loadFailure?.url ?? lastAttemptedURL else { return }
        load(url, displayAddress: addressText)
    }

    /// Dismisses the failure or certificate screen and returns to what WebKit
    /// still shows underneath: the last committed document, or the home view
    /// when the tab never committed one. The address bar follows, so it stops
    /// naming the URL that failed.
    func returnToDisplayedPage() {
        resolveCertificateWarning(allow: false)
        loadFailure = nil
        if let url = page.url {
            presentingHome = false
            lastAttemptedURL = url
            addressText = url.absoluteString
            hasCommittedNavigation = true
        } else {
            lastAttemptedURL = nil
            addressText = ""
            hasCommittedNavigation = false
        }
    }

    func resolveCertificateWarning(allow: Bool) {
        guard let continuation = certificateWarningContinuation else {
            certificateWarning = nil
            return
        }
        if !allow, let warning = certificateWarning {
            declinedCertificateChallenge = (warning.host, warning.port)
        }
        certificateWarning = nil
        certificateWarningContinuation = nil
        continuation.resume(returning: allow)
    }

    /// Drains the page's navigation events for this tab's lifetime, logging
    /// outcomes and recording failures into `loadFailure`. Started in `make` and
    /// cancelled in `stopObserving`, so it runs regardless of tab selection.
    ///
    /// `WebPage.navigations` terminates on every error, so the loop re-subscribes
    /// after each one. Events WebKit delivers between the error and the
    /// re-subscription — the rest of the same IPC batch — reach no stream and
    /// are lost, which `recoverMissedCommit` compensates for from page state.
    private func observeNavigations() async {
        while !Task.isCancelled {
            do {
                for try await event in page.navigations {
                    handleNavigationEvent(event)
                }
                log.info("navigations stream ended for host \(Self.logHost(for: self.page.url), privacy: .public)")
                return
            } catch is CancellationError {
                return
            } catch {
                handleNavigationError(error)
                recoverMissedCommit()
            }
        }
    }

    /// Recovers a `.committed` event the stream dropped. The common case: leaving
    /// a page that is still loading makes WebKit cancel the old document's load
    /// and commit the new one in the same batch, so the cancellation kills the
    /// stream and the commit that follows it is never delivered — leaving the
    /// address bar and lock on the old page until `.finished`, or for good on a
    /// page that never finishes. WebKit's own state still says what happened: a
    /// document is committed once it is the current back-forward item and the
    /// page's URL, and if that is not the document whose commit was last
    /// processed, the commit was missed.
    private func recoverMissedCommit() {
        guard let url = page.url, url != committedURL,
              page.backForwardList.currentItem?.url == url else { return }
        log.info("recovering missed commit for host \(Self.logHost(for: url), privacy: .public)")
        didCommit(url)
    }

    private func handleNavigationEvent(_ event: WebPage.NavigationEvent) {
        switch event {
        case .committed, .finished:
            if let url = page.url {
                didCommit(url)
            } else {
                hasCommittedNavigation = true
                loadFailure = nil
                declinedCertificateChallenge = nil
            }
            // Record into history once the page has fully loaded, so the title
            // (which arrives with the document) is available.
            if case .finished = event, let url = page.url {
                library.recordVisit(title: page.title, url: url)
            }
        case .startedProvisionalNavigation:
            // Covers link clicks and reloads too, which never go through
            // `load(_:)` — the indicator resets for every fresh navigation.
            hasCommittedNavigation = false
        case .receivedServerRedirect:
            // `page.url` already names the redirect target; track it so a
            // failure or declined certificate at the target is matched to this
            // navigation, and the address bar follows the redirect as in Safari.
            if let url = page.url, url != lastAttemptedURL {
                lastAttemptedURL = url
                addressText = url.absoluteString
            }
        @unknown default:
            break
        }
    }

    /// The document at `url` is committed: it is what the page displays now, so
    /// any failure screen is stale and the address bar and lock follow it.
    private func didCommit(_ url: URL) {
        hasCommittedNavigation = true
        committedURL = url
        loadFailure = nil
        declinedCertificateChallenge = nil
        addressText = url.absoluteString
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = underlyingNSError(from: error)
        let failing = failingURL(from: error)

        // The failure WebKit reports for a certificate challenge we cancelled
        // (user chose Go Back, or a newer navigation superseded the warning):
        // the tab already shows what it should, so this must not raise the
        // failure screen over it.
        if let declined = declinedCertificateChallenge {
            declinedCertificateChallenge = nil
            if failing == nil
                || failing.flatMap { $0.host() }.map(BrowserNavigationDecider.normalizedHost) == BrowserNavigationDecider.normalizedHost(declined.host) {
                return
            }
        }

        // Cancellations: our own stop, a navigation replaced by a newer one, a
        // response handed off as a download (policy interruption, WebKit 102),
        // or a link opened in another app. Not failures — but when nothing
        // else is loading, the aborted URL must not stay in the address bar
        // over the page WebKit kept displaying.
        if Self.isCancellation(nsError) {
            if loadFailure == nil, certificateWarning == nil, !page.isLoading {
                returnToDisplayedPage()
            }
            return
        }

        let attemptedURL = failing ?? lastAttemptedURL ?? page.url
        let message = Self.userFacingMessage(for: nsError)
        log.error("navigation failed: \(nsError.localizedDescription, privacy: .private)")

        if let attemptedURL {
            let previousAttempt = lastAttemptedURL
            lastAttemptedURL = attemptedURL
            if addressText.isEmpty || previousAttempt != attemptedURL {
                addressText = attemptedURL.absoluteString
            }
            loadFailure = BrowserLoadFailure(
                url: attemptedURL,
                message: message,
                reason: nsError.localizedDescription)
        }
    }

    private static func isCancellation(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
        // WebKitErrorFrameLoadInterruptedByPolicyChange: a navigation our
        // decider answered with `.cancel`.
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return true }
        return false
    }

    private func failingURL(from error: Error) -> URL? {
        if case WebPage.NavigationError.failedProvisionalNavigation(let underlying) = error {
            let nsError = underlying as NSError
            return nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        }

        let nsError = error as NSError
        return nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
    }

    private func underlyingNSError(from error: Error) -> NSError {
        if case WebPage.NavigationError.failedProvisionalNavigation(let underlying) = error {
            return underlying as NSError
        }
        return error as NSError
    }

    private static func userFacingMessage(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else {
            return "The page could not be loaded."
        }

        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "The server could not be found."
        case NSURLErrorTimedOut:
            return "The connection timed out."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "The network connection was lost."
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            return "A secure connection could not be established."
        default:
            return "The page could not be loaded."
        }
    }

    private static func logHost(for url: URL?) -> String {
        url?.host() ?? "unknown"
    }

    private func requestCertificateWarning(_ warning: BrowserCertificateWarning) async -> Bool {
        certificateWarningContinuation?.resume(returning: false)
        certificateWarningContinuation = nil

        return await withCheckedContinuation { continuation in
            certificateWarning = warning
            certificateWarningContinuation = continuation
        }
    }
}

struct BrowserLoadFailure {
    let url: URL
    /// Friendly one-line summary mapped from the error code.
    let message: String
    /// The underlying system error description — the specific reason the load
    /// failed, shown when it adds detail beyond `message`.
    let reason: String
}

enum BrowserSiteSecurity: Equatable {
    case secure
    case notSecure
    case certificateException
}

struct BrowserCertificateWarning: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let port: Int
    /// Why trust evaluation failed (e.g. "certificate has expired"), surfaced
    /// in the interstitial so the user can see the cause like Chrome does.
    let reason: String

    var displayHost: String {
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port == 443 ? bracketed : "\(bracketed):\(port)"
    }
}

@MainActor
final class BrowserCertificateTrustStore {
    private var trustedHosts = Set<String>()

    func isTrusted(host: String, port: Int) -> Bool {
        trustedHosts.contains(key(host: host, port: port))
    }

    func trust(host: String, port: Int) {
        trustedHosts.insert(key(host: host, port: port))
    }

    private func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }
}

@MainActor
final class BrowserNavigationDecider: WebPage.NavigationDeciding {
    var certificateWarningHandler: ((BrowserCertificateWarning) async -> Bool)?
    /// Invoked with the request (and the navigation response when one exists)
    /// when a navigation turns out to be a download. iOS 26's `WebPage` can't
    /// deliver the download itself, so we cancel the navigation and fetch it
    /// separately.
    var downloadHandler: ((URLRequest, URLResponse?) -> Void)?

    private let certificateTrustStore: BrowserCertificateTrustStore
    private let log = Logger(subsystem: "com.example.flextunnel", category: "webview")
    /// The most recent navigation action's request, kept so the response path can
    /// preserve the original method/body/headers — `NavigationResponse` doesn't
    /// expose the request, and rebuilding from the URL alone would drop them.
    private var lastNavigationRequest: URLRequest?
    /// The main frame's in-flight (or committed) URL, so a TLS challenge can be
    /// told apart from a subresource's: only the page itself gets the
    /// interstitial. Updated for redirects too, since WebKit re-asks policy.
    private var mainFrameURL: URL?

    /// Schemes WebKit renders itself. Anything else (`mailto:`, `tel:`, app
    /// links) can only fail inside the web view — with a failure screen whose
    /// Try Again fails the same way — so it is handed to the system instead.
    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]

    init(certificateTrustStore: BrowserCertificateTrustStore) {
        self.certificateTrustStore = certificateTrustStore
    }

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        lastNavigationRequest = action.request
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           !Self.webSchemes.contains(scheme) {
            // Only a user gesture may launch another app; a script redirect
            // to an app scheme is dropped silently, as mainstream browsers do.
            switch action.navigationType {
            case .linkActivated, .formSubmitted, .formResubmitted:
                log.info("opening external scheme \(scheme, privacy: .public)")
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            default:
                log.info("dropping non-user navigation to scheme \(scheme, privacy: .public)")
            }
            return .cancel
        }
        if action.target?.isMainFrame == true {
            mainFrameURL = action.request.url
        }
        if action.shouldPerformDownload {
            downloadHandler?(action.request, nil)
            return .cancel
        }
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        // A response WebKit can't display is a download. Cancel here (otherwise
        // the navigation hangs, since WebPage has no download delegate) and hand
        // it to the proxied downloader.
        guard response.canShowMimeType else {
            if let url = response.response.url {
                // Reuse the original request when it's for this URL (preserving
                // method/body/headers); after a redirect the URL differs, so fall
                // back to a plain GET on the final URL.
                let request = lastNavigationRequest.flatMap { $0.url == url ? $0 : nil }
                    ?? URLRequest(url: url)
                downloadHandler?(request, response.response)
            }
            return .cancel
        }
        return .allow
    }

    func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port
        guard let reason = Self.serverTrustFailureReason(serverTrust) else {
            return (.performDefaultHandling, nil)
        }

        if certificateTrustStore.isTrusted(host: host, port: port) {
            return (.useCredential, URLCredential(trust: serverTrust))
        }

        // A subresource (image, script, XHR, iframe) on an untrusted host is
        // blocked without asking — as Chrome and Safari do — rather than
        // throwing a full-screen interstitial over a page that is otherwise
        // fine, on every poll. Navigate to that host directly to trust it.
        guard isMainFrameChallenge(host: host, port: port) else {
            log.info("blocking subresource with untrusted certificate on \(host, privacy: .private)")
            return (.cancelAuthenticationChallenge, nil)
        }

        let warning = BrowserCertificateWarning(host: host, port: port, reason: reason)
        guard await certificateWarningHandler?(warning) == true else {
            return (.cancelAuthenticationChallenge, nil)
        }

        certificateTrustStore.trust(host: host, port: port)
        return (.useCredential, URLCredential(trust: serverTrust))
    }

    private func isMainFrameChallenge(host: String, port: Int) -> Bool {
        guard let url = mainFrameURL, let mainHost = url.host() else { return false }
        let mainPort = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
        return Self.normalizedHost(mainHost) == Self.normalizedHost(host) && mainPort == port
    }

    /// Case-folded, with the brackets an IPv6 literal carries in a URL but not
    /// in a protection space.
    static func normalizedHost(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    /// Evaluates the server trust: nil when valid, otherwise a human-readable
    /// reason (e.g. "certificate has expired", hostname mismatch) from the
    /// trust evaluation error.
    private static func serverTrustFailureReason(_ serverTrust: SecTrust) -> String? {
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            return nil
        }
        if let error {
            return (error as Error).localizedDescription
        }
        return "The certificate could not be verified."
    }
}
