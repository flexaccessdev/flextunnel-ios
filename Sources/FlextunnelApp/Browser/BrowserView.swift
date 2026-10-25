import SwiftUI
import UIKit
import WebKit

/// Full-screen browser chrome over proxied `WebPage`s. The location surface
/// follows Firefox iOS: site identity/search, URL text, and stop/reload as the
/// trailing page action. Tunnel status is this app's custom action outside that
/// standard browser surface.
///
/// Pages that put their own controls along the bottom edge (a remote desktop's
/// docked soft keyboard) sit right above the bottom bar, so the chrome guards
/// against stray taps three ways: a dead band above the bar's buttons, the bar
/// hidden while the system keyboard is up (as Safari does), and Hide Toolbars,
/// which gives the page the whole screen behind a slim strip that restores them.
struct BrowserView: View {
    @State var model: BrowserModel
    @ObservedObject var proxy: ProxyController
    @Environment(\.dismiss) private var dismiss
    @State private var showingTunnelStatus = false
    @State private var showingTabTray = false
    @State private var showBookmarkSaved = false
    @State private var showingFind = false
    @State private var addressBarFocused = false
    @State private var addressQuery = ""
    /// Hide Toolbars, for this browser session only. Only takes effect over a
    /// page — a home tab always shows the address bar (see `toolbarsCollapsed`).
    @State private var toolbarsHidden = false
    @State private var keyboardVisible = false
    // The bottom bar's sheets live here, not on the bar: the bar leaves the
    // hierarchy while the keyboard is up or the toolbars are hidden, and a
    // sheet attached to it would be torn down the moment one of its own text
    // fields (Library search, the bookmark editor) raised the keyboard.
    @State private var library: LibraryRequest?
    @State private var shareItem: ShareItem?
    @State private var bookmarkDraft: BookmarkDraft?
    /// A draft requested from inside the share popout, applied once it dismisses
    /// so we never present two sheets at once.
    @State private var pendingShareDraft: BookmarkDraft?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if toolbarsCollapsed {
                CollapsedToolbarStrip(
                    tab: model.selectedTab,
                    tunnelStatusColor: tunnelStatusColor,
                    onShow: { toolbarsHidden = false })
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                AddressBarView(
                    model: model,
                    proxy: proxy,
                    tunnelStatusIcon: tunnelStatusIcon,
                    tunnelStatusColor: tunnelStatusColor,
                    tunnelStatusValue: tunnelStatusValue,
                    tunnelReconnecting: proxy.sessionAlive && !proxy.tunnelConnected && !proxy.tunnelStuck,
                    showingTunnelStatus: $showingTunnelStatus,
                    addressBarFocused: $addressBarFocused,
                    editText: $addressQuery)
                Divider()
            }

            if let tab = model.selectedTab {
                Group {
                    if tab.isHome {
                        BrowserHomeView(
                            onOpen: openFromHome)
                    } else {
                        // Keep the WebView mounted and layer the failure screen over
                        // it, so retrying toggles an overlay instead of tearing down
                        // and recreating the web view (which flickers).
                        WebView(tab.page)
                            .webViewBackForwardNavigationGestures(.enabled)
                            .findNavigator(isPresented: $showingFind)
                            .overlay(alignment: .top) { progressBar(for: tab.page) }
                            .overlay {
                                if let warning = tab.certificateWarning {
                                    BrowserCertificateWarningView(
                                        warning: warning,
                                        onProceed: { tab.resolveCertificateWarning(allow: true) },
                                        onGoBack: { tab.returnToDisplayedPage() })
                                } else if let failure = tab.loadFailure {
                                    BrowserLoadFailureView(
                                        failure: failure,
                                        route: proxy.pageRoute(for: failure.url),
                                        tunnelConnected: proxy.tunnelConnected,
                                        onRetry: { tab.retryFailedLoad() },
                                        onGoBack: { tab.returnToDisplayedPage() },
                                        onShowTunnelStatus: { showingTunnelStatus = true })
                                }
                            }
                            .overlay {
                                // Focusing the address bar over a loaded page shows
                                // the home shortcuts only when there's nothing to
                                // suggest — recents (or typed matches) take the
                                // overlay below whenever history has something.
                                if addressBarFocused && addressSuggestions.isEmpty {
                                    BrowserHomeView(
                                        onOpen: openFromHome)
                                        .transition(.opacity)
                                }
                            }
                    }
                }
                .overlay {
                    if addressBarFocused && !addressSuggestions.isEmpty {
                        AddressSuggestionsView(
                            entries: addressSuggestions,
                            onOpen: openFromHome)
                            .transition(.opacity)
                    }
                }
            } else {
                EmptyBrowserView(
                    onNewTab: { model.addTab() })
            }

            if showsBottomBar {
                BottomActionBar(
                    model: model,
                    showingTabTray: $showingTabTray,
                    showingFind: $showingFind,
                    onShowLibrary: { library = LibraryRequest(section: $0) },
                    onShare: { shareItem = ShareItem(url: $0) },
                    onAddBookmark: { bookmarkDraft = $0 },
                    onHideToolbars: { toolbarsHidden = true },
                    onDisconnect: stopAndDismiss)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            Group {
                if showBookmarkSaved {
                    BookmarkSavedToast()
                } else if let toast = model.downloads.toast {
                    DownloadStatusToast(toast: toast)
                }
            }
            .padding(.bottom, showsBottomBar ? 84 : 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .sheet(item: Bindable(model.downloads).pendingPrompt) { prompt in
            DownloadPromptView(
                prompt: prompt,
                onDownload: { model.downloads.confirm(prompt) },
                onCancel: { model.downloads.cancelPrompt() })
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $library) { request in
            LibraryView(model: model, section: request.section)
        }
        .sheet(item: $shareItem) { item in
            BrowserShareSheet(
                url: item.url,
                activities: [bookmarkActivity(for: item.url)],
                onDismiss: {
                    shareItem = nil
                    // Present the editor only after the popout has gone, so the
                    // two sheets never overlap.
                    if let draft = pendingShareDraft {
                        pendingShareDraft = nil
                        DispatchQueue.main.async { bookmarkDraft = draft }
                    }
                })
                .ignoresSafeArea()
        }
        .sheet(item: $bookmarkDraft) { draft in
            BookmarkEditView(draft: draft, isTaken: model.library.isBookmarked) { name, url in
                model.library.addBookmark(name: name, url: url)
                flashBookmarkSaved()
            }
        }
        .sheet(isPresented: $showingTunnelStatus) {
            TunnelStatusSheet(
                proxy: proxy,
                boundPort: model.socksPort,
                pageURL: model.selectedTab?.visibleURL,
                onReconnect: { proxy.retryNow() },
                onDisconnect: stopAndDismiss)
        }
        .animation(.easeInOut(duration: 0.25), value: model.downloads.toast)
        .animation(.easeInOut(duration: 0.18), value: addressBarFocused)
        .animation(.easeInOut(duration: 0.22), value: toolbarsCollapsed)
        .animation(.easeInOut(duration: 0.18), value: keyboardVisible)
        .onChange(of: model.downloads.toast) {
            // Auto-clear the terminal download toast after a moment.
            guard let shown = model.downloads.toast else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if model.downloads.toast == shown { model.downloads.toast = nil }
            }
        }
        .onChange(of: model.selectedTab?.isHome ?? true) { _, isHome in
            // Back to a home tab (or no tab): bring the bars back for good, so
            // the next page doesn't open hidden without the user asking again.
            if isHome { toolbarsHidden = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .fullScreenCover(isPresented: $showingTabTray) {
            TabTrayView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding dismisses the keyboard and resigns the address bar's
            // first responder, but SwiftUI's focus `.onChange` handlers are paused
            // while backgrounded — so `addressBarFocused` (which drives the home
            // overlay over a loaded page) can get stuck `true` and keep covering
            // the page on resume until a back/forward toggle re-fires the sync.
            // The address bar is never actually focused right after foregrounding,
            // so clear the flag to match reality and drop the stale overlay.
            if phase == .active { addressBarFocused = false }
        }
    }

    /// Hide Toolbars is on and there's a page to give the screen to.
    private var toolbarsCollapsed: Bool {
        toolbarsHidden && model.selectedTab.map { !$0.isHome } == true
    }

    /// The bottom bar steps aside for the system keyboard instead of riding on
    /// top of it, right under the keys being typed on.
    private var showsBottomBar: Bool {
        !toolbarsCollapsed && !keyboardVisible
    }

    private func openFromHome(_ address: String) {
        addressBarFocused = false
        model.navigate(address)
    }

    /// Address-bar autosuggestions: recently visited pages — history is recorded
    /// only when a load finishes successfully — whose host or URL matches what's
    /// being typed. Host-prefix matches rank above substring matches; within each
    /// group the store's newest-first order is preserved. De-duplicated by
    /// host+path so query-string variants of one page collapse to the latest,
    /// capped at a handful so the list stays a quick pick, not a history browser.
    /// With nothing typed the list falls back to the most recent pages.
    private var addressSuggestions: [HistoryEntry] {
        let query = addressQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return recentPages }

        var seen = Set<String>()
        var prefixMatches: [HistoryEntry] = []
        var substringMatches: [HistoryEntry] = []
        for entry in model.library.history {
            guard let host = entry.url.host?.lowercased() else { continue }
            let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            // Match case-insensitively, but de-dup on the case-sensitive path so
            // distinct resources like /Account and /account stay separate.
            let path = entry.url.path
            let isPrefix = host.hasPrefix(query) || bareHost.hasPrefix(query)
            let isSubstring = host.contains(query) || path.lowercased().contains(query)
                || entry.url.absoluteString.lowercased().contains(query)
            guard isPrefix || isSubstring else { continue }
            guard seen.insert(host + path).inserted else { continue }
            if isPrefix { prefixMatches.append(entry) } else { substringMatches.append(entry) }
        }
        return Array((prefixMatches + substringMatches).prefix(Self.suggestionLimit))
    }

    /// Most recently visited pages, shown as soon as the address bar is focused
    /// (or cleared) with nothing typed — the standard browser behavior of
    /// offering where you've been rather than the new-tab shortcuts. De-duplicated
    /// and capped like the typed-match list above.
    private var recentPages: [HistoryEntry] {
        var seen = Set<String>()
        var recents: [HistoryEntry] = []
        for entry in model.library.history {
            guard let host = entry.url.host?.lowercased() else { continue }
            guard seen.insert(host + entry.url.path).inserted else { continue }
            recents.append(entry)
            if recents.count == Self.suggestionLimit { break }
        }
        return recents
    }

    private static let suggestionLimit = 6

    private var tunnelStatusIcon: String {
        if proxy.socksPort == nil { return "bolt.horizontal.circle" }
        return proxy.tunnelStuck ? "bolt.slash.circle.fill" : "bolt.horizontal.circle.fill"
    }

    /// Green when the tunnel link is up; red when it's stuck disconnected or the
    /// set is full-tunnel (nothing browses without it); orange for a transient
    /// gap — off-list browsing keeps working directly either way.
    private var tunnelStatusColor: Color {
        if proxy.tunnelConnected {
            return .green
        }
        if proxy.tunnelStuck || proxy.isFullTunnel {
            return .red
        }
        if proxy.socksPort != nil {
            return .orange
        }
        return .secondary
    }

    /// The tunnel button's spoken state, matching the sheet's title.
    private var tunnelStatusValue: String {
        if proxy.tunnelConnected { return "Connected" }
        if proxy.tunnelStuck { return "Disconnected" }
        if proxy.sessionAlive { return "Reconnecting" }
        return "Stopped"
    }

    /// Builds the share-popout bookmark action. Removal happens immediately;
    /// adding stashes a draft so the editor opens once the popout dismisses.
    private func bookmarkActivity(for url: URL) -> BookmarkActivity {
        let library = model.library
        if library.isBookmarked(url) {
            return BookmarkActivity(mode: .remove) { library.removeBookmark(url: url) }
        }
        let name = model.selectedTab?.displayTitle ?? (url.host() ?? url.absoluteString)
        return BookmarkActivity(mode: .add) { pendingShareDraft = BookmarkDraft(name: name, url: url) }
    }

    private func stopAndDismiss() {
        model.stopAll()
        proxy.stop()
        showingTunnelStatus = false
        showingTabTray = false
        dismiss()
    }

    @ViewBuilder
    private func progressBar(for page: WebPage) -> some View {
        if page.isLoading && page.estimatedProgress < 1 {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
        }
    }

    /// Briefly shows the "Bookmark Saved" toast, then fades it out.
    private func flashBookmarkSaved() {
        withAnimation(.spring(duration: 0.3)) { showBookmarkSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.3)) { showBookmarkSaved = false }
        }
    }

}

/// Wraps the URL being shared so it can drive `.sheet(item:)`.
private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Which Library segment to open, driving `.sheet(item:)`.
private struct LibraryRequest: Identifiable {
    let section: LibraryView.Section
    var id: LibraryView.Section { section }
}

/// What Hide Toolbars leaves at the top: the page's domain and a tunnel-status
/// dot on the bar material, under the status bar. Tapping it brings the
/// toolbars back, as Safari's collapsed bar does.
@MainActor
private struct CollapsedToolbarStrip: View {
    let tab: BrowserTab?
    let tunnelStatusColor: Color
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 6) {
                if tab?.siteSecurity == .secure {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(hostText)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Circle()
                    .fill(tunnelStatusColor)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .accessibilityLabel("Show toolbars")
        .accessibilityValue(hostText)
        .accessibilityIdentifier("browser.showToolbars")
    }

    /// The registrable domain alone (`example.com` for `www.example.com`), the
    /// part that says whose page this is.
    private var hostText: String {
        guard let tab else { return "" }
        if let parts = AddressDisplayParts(tab: tab) { return parts.primaryText }
        return tab.visibleURL?.host() ?? tab.addressText
    }
}

/// Transient confirmation shown after a bookmark is saved.
private struct BookmarkSavedToast: View {
    var body: some View {
        Label("Bookmark Saved", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.green, in: Capsule())
            .shadow(radius: 6, y: 2)
    }
}

/// Transient confirmation shown when a download finishes or fails.
private struct DownloadStatusToast: View {
    let toast: DownloadToast

    var body: some View {
        Label(toast.message, systemImage: toast.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(toast.isFailure ? Color.red : Color.green, in: Capsule())
            .shadow(radius: 6, y: 2)
    }
}

/// Placeholder shown for a fresh tab that hasn't navigated yet — a wordmark and
/// a grid of search engines, mirroring Firefox iOS's default new-tab page so
/// startup isn't a blank web view. Tapping a tile loads it through the tunnel.
private struct BrowserHomeView: View {
    let onOpen: (String) -> Void

    /// Search engines offered as a starting point. Favicons aren't bundled here,
    /// so each tile uses a monogram in the engine's brand color.
    private struct SearchEngine: Identifiable {
        let id = UUID()
        let title: String
        let url: String
        let color: Color
        var monogram: String { String(title.prefix(1)) }
    }

    private let engines = [
        SearchEngine(title: "Google", url: "https://www.google.com/", color: Color(red: 0.26, green: 0.52, blue: 0.96)),
        SearchEngine(title: "DuckDuckGo", url: "https://duckduckgo.com/", color: Color(red: 0.87, green: 0.40, blue: 0.16)),
        SearchEngine(title: "Bing", url: "https://www.bing.com/", color: Color(red: 0.0, green: 0.46, blue: 0.49)),
    ]

    /// Always-on shortcut to the reserved `flextunnel.internal` server status
    /// page, which flextunnel tunnels to the server regardless of the routed set,
    /// so it's one tap away from a fresh tab.
    private let internalShortcutURL = "http://flextunnel.internal"

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 52, weight: .regular))
                        .foregroundStyle(.tint)

                    Text("flextunnel")
                        .font(.largeTitle.weight(.semibold))

                    Text("Search or enter an address to browse through your tunnel.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("SHORTCUTS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: columns, spacing: 20) {
                        Button {
                            onOpen(internalShortcutURL)
                        } label: {
                            internalShortcutTile
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)

                VStack(alignment: .leading, spacing: 12) {
                    Text("SEARCH ENGINES")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(engines) { engine in
                            Button {
                                onOpen(engine.url)
                            } label: {
                                engineTile(engine)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var internalShortcutTile: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.tint)
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(.white)
                }

            Text("Server Status")
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func engineTile(_ engine: SearchEngine) -> some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(engine.color)
                .frame(width: 60, height: 60)
                .overlay {
                    Text(engine.monogram)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }

            Text(engine.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

/// Address-bar autosuggestion list, layered over the page while the address bar
/// is focused — typed matches, or the most recent pages when nothing is typed.
/// Each row is a previously visited page; tapping it navigates there.
private struct AddressSuggestionsView: View {
    let entries: [HistoryEntry]
    let onOpen: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    Button {
                        onOpen(entry.url.absoluteString)
                    } label: {
                        row(for: entry)
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 52)
                }
            }
        }
        .scrollDismissesKeyboard(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
    }

    private func row(for entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(displayURL(entry.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Compact form without the scheme (e.g. `example.com/path`), matching how
    /// mainstream browsers render suggestion subtitles.
    private func displayURL(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}

private struct EmptyBrowserView: View {
    let onNewTab: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text("No Tabs")
                .font(.title3.weight(.semibold))

            Button(action: onNewTab) {
                Label("New Tab", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// Full-screen failure page layered over the document WebKit kept displaying.
/// Besides retrying, it offers the way out mainstream browsers give for free —
/// back to the page you were on — since the overlay otherwise hides it. It also
/// says how the host is routed, the first thing to know when a private host
/// fails: a tunneled host while the tunnel is down, or a host that isn't in the
/// tunnel set at all and so went out directly.
private struct BrowserLoadFailureView: View {
    let failure: BrowserLoadFailure
    let route: PageRoute?
    let tunnelConnected: Bool
    let onRetry: () -> Void
    let onGoBack: () -> Void
    let onShowTunnelStatus: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)

            Text("Problem Loading Page")
                .font(.title3.weight(.semibold))

            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 320)

            if failure.reason != failure.message {
                Text(failure.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 320)
            }

            Text(failure.url.host() ?? failure.url.absoluteString)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let routeHint {
                Label(routeHint.text, systemImage: routeHint.icon)
                    .font(.footnote)
                    .foregroundStyle(routeHint.color)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 320, alignment: .leading)
                    .background(routeHint.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("browser.failureRoute")
            }

            VStack(spacing: 10) {
                Button(action: onRetry) {
                    Label("Try Again", systemImage: "arrow.clockwise").frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)

                if route == .tunnel && !tunnelConnected {
                    Button(action: onShowTunnelStatus) {
                        Label("Tunnel Status", systemImage: "bolt.horizontal.circle").frame(maxWidth: 280)
                    }
                    .buttonStyle(.bordered)
                }

                Button(action: onGoBack) {
                    Text("Go Back").frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var routeHint: (text: String, icon: String, color: Color)? {
        switch route {
        case .tunnel where !tunnelConnected:
            return ("This site is reached through the tunnel, which is reconnecting.",
                    "bolt.slash.circle", .orange)
        case .tunnel:
            return ("Reached through the tunnel — the server couldn't load it.",
                    "bolt.horizontal.circle", .secondary)
        case .direct:
            return ("Connected directly — this host isn't in the tunnel set.",
                    "arrow.up.right.circle", .secondary)
        case nil:
            return nil
        }
    }
}

/// Full-screen interstitial for an untrusted TLS certificate — Chrome-style:
/// states the connection isn't private, shows the specific reason and host, and
/// offers going back or proceeding anyway (which trusts the host for the
/// session). Replaces a modal alert so it reads like the load-failure page.
private struct BrowserCertificateWarningView: View {
    let warning: BrowserCertificateWarning
    let onProceed: () -> Void
    let onGoBack: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.red)

            Text("Your connection is not private")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(warning.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 320)

            Text(warning.displayHost)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            VStack(spacing: 10) {
                Button(action: onGoBack) {
                    Text("Go Back").frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive, action: onProceed) {
                    Text("Continue Anyway").frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// Top chrome: app-specific tunnel status plus Firefox-style location surface.
private struct AddressBarView: View {
    @Bindable var model: BrowserModel
    let proxy: ProxyController
    let tunnelStatusIcon: String
    let tunnelStatusColor: Color
    let tunnelStatusValue: String
    let tunnelReconnecting: Bool
    @Binding var showingTunnelStatus: Bool
    @Binding var addressBarFocused: Bool
    @Binding var editText: String
    @State private var showingSiteSecurity = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                leadingLocationButton(for: tab)

                ZStack(alignment: .leading) {
                    TextField("Search or enter address", text: $editText)
                        .textFieldStyle(.plain)
                        .keyboardType(.webSearch)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .accessibilityIdentifier("browser.addressField")
                        .opacity(addressFocused ? 1 : 0)
                        .allowsHitTesting(addressFocused)
                        .onSubmit {
                            model.navigate(editText)
                            addressFocused = false
                        }

                    if !addressFocused {
                        Button {
                            beginEditing(tab)
                        } label: {
                            AddressDisplayText(tab: tab)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("browser.address")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36)

                trailingLocationButton(for: tab)
            }
            .frame(height: 36)
            .padding(.leading, 2)
            .padding(.trailing, 4)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(.separator).opacity(0.18), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .popover(isPresented: $showingSiteSecurity) {
                if let tab {
                    SiteSecurityPopover(tab: tab, route: proxy.pageRoute(for: tab.visibleURL))
                        .presentationCompactAdaptation(.popover)
                }
            }

            // While editing, offer the standard iOS-browser Cancel to back out —
            // it resigns focus, which restores the address text and drops the
            // suggestions/home overlay so the current page is visible again.
            // Otherwise the tunnel status action takes the slot.
            if addressFocused {
                Button("Cancel") { cancelEditing() }
                    .buttonStyle(.plain)
                    .transition(.opacity)
            } else {
                tunnelStatusButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.easeInOut(duration: 0.18), value: addressFocused)
        .onChange(of: model.selectedID) { syncAddress(model.selectedTab?.addressText) }
        .onChange(of: tab?.addressText) { if !addressFocused { syncAddress(tab?.addressText) } }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                editText = tab?.addressText ?? editText
            } else {
                syncAddress(tab?.addressText)
            }
            if addressBarFocused != focused {
                addressBarFocused = focused
            }
        }
        .onChange(of: addressBarFocused) { _, focused in
            if addressFocused != focused {
                addressFocused = focused
            }
        }
        .onAppear {
            syncAddress(tab?.addressText)
            addressBarFocused = addressFocused
        }
    }

    private var tunnelStatusButton: some View {
        Button {
            showingTunnelStatus = true
        } label: {
            Image(systemName: tunnelStatusIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tunnelStatusColor)
                .symbolEffect(.pulse, isActive: tunnelReconnecting)
                .frame(width: 40, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tunnel status")
        .accessibilityValue(tunnelStatusValue)
        .accessibilityIdentifier("browser.tunnelStatus")
    }

    @ViewBuilder
    private func leadingLocationButton(for tab: BrowserTab?) -> some View {
        if addressFocused || tab?.siteSecurity == nil {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 36)
                .accessibilityHidden(true)
        } else if let tab {
            Button {
                showingSiteSecurity = true
            } label: {
                Image(systemName: siteSecurityIcon(for: tab.siteSecurity))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(siteSecurityColor(for: tab.siteSecurity))
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(siteSecurityAccessibilityLabel(for: tab.siteSecurity))
            .accessibilityIdentifier("browser.siteSecurity")
        }
    }

    @ViewBuilder
    private func trailingLocationButton(for tab: BrowserTab?) -> some View {
        if addressFocused {
            if !editText.isEmpty {
                Button {
                    editText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear address")
            }
        } else if let tab {
            Button {
                if tab.page.isLoading {
                    tab.stop()
                } else {
                    tab.reload()
                }
            } label: {
                Image(systemName: tab.page.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.page.isLoading ? "Stop loading" : "Reload")
        }
    }

    private func beginEditing(_ tab: BrowserTab?) {
        editText = tab?.addressText ?? editText
        addressFocused = true
    }

    /// Backs out of editing without navigating: drops focus and restores the
    /// address text to the current page, so the overlays clear and the page shows.
    private func cancelEditing() {
        addressFocused = false
        syncAddress(model.selectedTab?.addressText)
    }

    private func syncAddress(_ address: String?) {
        editText = address ?? ""
    }

    private func siteSecurityIcon(for security: BrowserSiteSecurity?) -> String {
        switch security {
        case .secure:
            return "lock.fill"
        case .notSecure:
            return "info.circle"
        case .certificateException:
            return "lock.slash.fill"
        case nil:
            return "magnifyingglass"
        }
    }

    private func siteSecurityColor(for security: BrowserSiteSecurity?) -> Color {
        switch security {
        case .secure:
            return .secondary
        case .notSecure:
            return .secondary
        case .certificateException:
            return .orange
        case nil:
            return .secondary
        }
    }

    private func siteSecurityAccessibilityLabel(for security: BrowserSiteSecurity?) -> String {
        switch security {
        case .secure:
            return "Secure connection"
        case .notSecure:
            return "Connection is not secure"
        case .certificateException:
            return "Certificate exception"
        case nil:
            return "Search or enter address"
        }
    }
}

@MainActor
private struct AddressDisplayText: View {
    let tab: BrowserTab?

    var body: some View {
        if let tab,
           let parts = AddressDisplayParts(tab: tab) {
            HStack(spacing: 0) {
                if !parts.subduedPrefix.isEmpty {
                    Text(parts.subduedPrefix)
                        .foregroundStyle(.secondary)
                }
                Text(parts.primaryText)
                    .foregroundStyle(.primary)
            }
            .font(.body)
            .lineLimit(1)
            .truncationMode(.head)
        } else if let address = tab?.addressText, !address.isEmpty {
            Text(address)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
        } else {
            Text("Search or enter address")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

@MainActor
private struct AddressDisplayParts {
    let subduedPrefix: String
    let primaryText: String

    init?(tab: BrowserTab) {
        guard let url = tab.visibleURL,
              let host = url.host(),
              !host.isEmpty else {
            return nil
        }

        let displayHost = Self.displayHost(host)
        let portSuffix = Self.portSuffix(for: url)
        guard Self.canSplit(host: displayHost) else {
            subduedPrefix = ""
            primaryText = displayHost + portSuffix
            return
        }

        let labels = displayHost.split(separator: ".").map(String.init)
        let registrableCount = Self.registrableLabelCount(for: labels)
        guard labels.count > registrableCount else {
            subduedPrefix = ""
            primaryText = displayHost + portSuffix
            return
        }

        subduedPrefix = labels.dropLast(registrableCount).joined(separator: ".") + "."
        primaryText = labels.suffix(registrableCount).joined(separator: ".") + portSuffix
    }

    /// Number of trailing labels making up the registrable domain (the part to
    /// emphasize). This is a pragmatic stand-in for the Public Suffix List,
    /// erring toward not dimming the registrant:
    /// - a known multi-label public suffix (`example.co.uk`) → 3;
    /// - a longer gTLD (`.com`, `.dev`, …) → 2 (the usual eTLD+1);
    /// - an unknown 2-letter ccTLD (`co.ke`, `github.io`, …), where 2-label and
    ///   private suffixes are common and the registrable boundary is unknowable
    ///   without the full PSL → no split, so the whole host stays primary rather
    ///   than risk promoting the suffix over the registrant.
    private static func registrableLabelCount(for labels: [String]) -> Int {
        guard labels.count >= 3 else { return 2 }
        let lastTwo = labels.suffix(2).joined(separator: ".").lowercased()
        if multiLabelPublicSuffixes.contains(lastTwo) { return 3 }
        if labels[labels.count - 1].count <= 2 { return labels.count }
        return 2
    }

    private static let multiLabelPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.jp", "ne.jp", "or.jp", "go.jp", "ac.jp",
        "co.nz", "net.nz", "org.nz", "govt.nz",
        "co.in", "net.in", "org.in", "gov.in", "ac.in",
        "co.kr", "co.za", "com.br", "com.cn", "com.mx", "com.tr",
        "com.sg", "com.hk", "com.tw", "co.il", "com.ar",
    ]

    private static func displayHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private static func portSuffix(for url: URL) -> String {
        guard let port = url.port else { return "" }
        let scheme = url.scheme?.lowercased()
        if scheme == "https", port == 443 { return "" }
        if scheme == "http", port == 80 { return "" }
        return ":\(port)"
    }

    private static func canSplit(host: String) -> Bool {
        if host == "localhost" { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return true
    }
}

@MainActor
private struct SiteSecurityPopover: View {
    let tab: BrowserTab
    let route: PageRoute?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)

            if let url = tab.visibleURL {
                Text(hostText(for: url))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let route {
                Divider()
                Label(route == .tunnel ? "Through the tunnel" : "Direct (not in the tunnel set)",
                      systemImage: route == .tunnel ? "bolt.horizontal.circle.fill" : "arrow.up.right.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(route == .tunnel ? .green : .secondary)
                    .accessibilityIdentifier("browser.siteRoute")
            }
        }
        .padding()
        .frame(width: 300, alignment: .leading)
    }

    private var title: String {
        switch tab.siteSecurity {
        case .secure:
            return "Secure Connection"
        case .notSecure:
            return "Not Secure"
        case .certificateException:
            return "Certificate Exception"
        case nil:
            return "Site Information"
        }
    }

    private var message: String {
        switch tab.siteSecurity {
        case .secure:
            return "The connection uses HTTPS."
        case .notSecure:
            return "The connection does not use HTTPS."
        case .certificateException:
            return "You allowed this certificate for the current browser session."
        case nil:
            return "No site information is available."
        }
    }

    private var icon: String {
        switch tab.siteSecurity {
        case .secure:
            return "lock.fill"
        case .notSecure:
            return "info.circle"
        case .certificateException:
            return "lock.slash.fill"
        case nil:
            return "info.circle"
        }
    }

    private var color: Color {
        switch tab.siteSecurity {
        case .secure:
            return .green
        case .notSecure:
            return .red
        case .certificateException:
            return .orange
        case nil:
            return .secondary
        }
    }

    private func hostText(for url: URL) -> String {
        guard var host = url.host() else { return url.absoluteString }
        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// Bottom toolbar: tab tray, library, back, forward, share, menu.
///
/// Back and forward sit mid-bar rather than in the corner nearest a page's
/// bottom-left controls, and a dead band above the buttons catches a finger
/// that overshoots the page's bottom row — so a stray tap lands on nothing
/// instead of navigating away.
private struct BottomActionBar: View {
    @Bindable var model: BrowserModel
    @Binding var showingTabTray: Bool
    @Binding var showingFind: Bool
    let onShowLibrary: (LibraryView.Section) -> Void
    let onShare: (URL) -> Void
    let onAddBookmark: (BookmarkDraft) -> Void
    let onHideToolbars: () -> Void
    let onDisconnect: () -> Void

    /// Height of the non-interactive band between the page and the buttons.
    private static let deadBand: CGFloat = 10

    var body: some View {
        let tab = model.selectedTab
        let url = tab?.page.url
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                barButton("Show tabs", id: "browser.tabs") {
                    showingTabTray = true
                } label: {
                    tabCountIcon
                }

                barButton("Library", id: "browser.library") {
                    onShowLibrary(.bookmarks)
                } label: {
                    Image(systemName: "book")
                        .overlay(alignment: .topTrailing) {
                            if downloadsActive {
                                Circle()
                                    .fill(.tint)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -2)
                            }
                        }
                }
                .accessibilityValue(downloadsActive ? "Downloading" : "")

                barButton("Back", id: "browser.back") {
                    tab?.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(tab?.canGoBack != true)

                barButton("Forward", id: "browser.forward") {
                    tab?.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(tab?.canGoForward != true)

                barButton("Share", id: "browser.share") {
                    if let url { onShare(url) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(url == nil)

                menu(tab: tab, url: url)
            }
            .imageScale(.large)
            .padding(.horizontal, 8)
            .padding(.top, Self.deadBand)
        }
        .background(.bar)
    }

    /// One evenly spaced bar slot with a 44pt hit frame, starting below the
    /// dead band.
    private func barButton(
        _ title: String,
        id: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private func menu(tab: BrowserTab?, url: URL?) -> some View {
        Menu {
            if let url {
                if model.library.isBookmarked(url) {
                    Button {
                        model.library.removeBookmark(url: url)
                    } label: {
                        Label("Remove Bookmark", systemImage: "bookmark.slash")
                    }
                } else {
                    Button {
                        onAddBookmark(BookmarkDraft(
                            name: tab?.displayTitle ?? (url.host() ?? url.absoluteString),
                            url: url))
                    } label: {
                        Label("Add Bookmark", systemImage: "bookmark")
                    }
                }
                Button {
                    UIPasteboard.general.string = url.absoluteString
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button {
                    showingFind = true
                } label: {
                    Label("Find in Page", systemImage: "magnifyingglass")
                }
                Button(action: onHideToolbars) {
                    Label("Hide Toolbars", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            Button {
                onShowLibrary(.downloads)
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            Divider()
            if let url {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open in Safari (bypasses tunnel)", systemImage: "safari")
                }
            }
            if let tab = tab {
                Button {
                    model.closeTab(tab)
                } label: {
                    Label("Close Tab", systemImage: "xmark.square")
                }
            }
            Divider()
            Button(role: .destructive, action: onDisconnect) {
                Label("Disconnect Tunnel", systemImage: "stop.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("browser.menu")
    }

    private var downloadsActive: Bool {
        model.downloads.items.contains { if case .downloading = $0.state { return true } else { return false } }
    }

    private var tabCountIcon: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(lineWidth: 2)
            .frame(width: 26, height: 26)
            .overlay {
                Text("\(model.tabs.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
    }
}
