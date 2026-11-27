import SwiftUI
import UIKit

struct ContentView: View {
    /// What a successful connect presents: the in-app browser, or the proxy-only
    /// screen (SOCKS + port forwards for other apps, no browser). Raw values are
    /// the AppStorage encoding of the remembered choice.
    private enum SessionMode: String {
        case browser
        case proxyOnly

        var title: String {
            switch self {
            case .browser: return "Browse the web"
            case .proxyOnly: return "Forward ports"
            }
        }

        var description: String {
            switch self {
            case .browser:
                return "Open the built-in browser. Sites on a destination's "
                    + "routes go through its server, where private hostnames resolve."
            case .proxyOnly:
                return "Forward local ports to hosts behind your destinations, "
                    + "with no browser, so other apps on this device "
                    + "(SSH, RDP, databases…) can reach them at localhost."
            }
        }

        var icon: String {
            switch self {
            case .browser: return "safari.fill"
            case .proxyOnly: return "app.connected.to.app.below.fill"
            }
        }

        var cta: String {
            switch self {
            case .browser: return "Start Browsing"
            case .proxyOnly: return "Start Port Forwarding"
            }
        }

        var startingLabel: String {
            switch self {
            case .browser: return "Starting browser session…"
            case .proxyOnly: return "Starting port forwarding…"
            }
        }
    }

    @StateObject private var proxy = ProxyController()
    @StateObject private var portForwards = PortForwardController()
    // Location-based background keep-alive for forwarding-only sessions. Browser
    // sessions follow WebKit/iOS background suspension normally; opting in is
    // offered only when Forward ports is selected (see BackgroundKeepAlive.swift
    // and docs/background-keep-alive.md).
    @StateObject private var keepAlive = BackgroundKeepAlive()

    // The client's saved setup: its destinations (the servers it reaches, each
    // by a name) and the auth key and relays they share. One session
    // serves every destination, connecting each server only when it is used.
    @StateObject private var client = ClientStore()
    // The named client auth keys (Keychain-backed; see AuthKeyStore); the
    // client references one by id. Keys persist the moment they're generated
    // or imported — unlike the relay token there is no "known-good" moment to
    // wait for: the public key must be on a server's authorized-keys file
    // before the first connection to it can succeed.
    @StateObject private var authKeys = AuthKeyStore()
    @State private var relayAuthToken = ""
    @State private var browserModel: BrowserModel?
    @State private var didLoadSecrets = false
    // The relay token the running session was started with, held until a
    // destination connects with it (see the `connectedNames` handler) — not
    // whatever the field holds by then. Nil once saved, and between sessions.
    @State private var unsavedRelayToken: String?
    // The destination being added or edited, in its sheet.
    @State private var destinationDraft: DestinationDraft?
    // Remembered across launches: both modes share the config above, so the
    // choice is sticky and only the single CTA's label follows it.
    @AppStorage("lastSessionMode") private var sessionModeRaw = SessionMode.browser.rawValue
    @State private var proxyOnlyActive = false

    private var sessionMode: SessionMode {
        get { SessionMode(rawValue: sessionModeRaw) ?? .browser }
        nonmutating set { sessionModeRaw = newValue.rawValue }
    }

    // Best-effort background grace: buys ~30s of runtime after backgrounding so
    // the session and its port forwards outlive a brief app switch. This is separate
    // from the forwarding-only location keep-alive.
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    // Set when the background grace expired with nothing holding the process
    // (see the expiration handler): iOS suspended the app and defunct'd the
    // forward listeners, so the next foreground must rebind them.
    @State private var wasSuspended = false

    // Session status Live Activity (lock screen / Dynamic Island) for forwarding
    // sessions only: a backgrounded forwarding session is what earns a glanceable
    // banner, while a browser session is either in front or suspended. UX only —
    // it reflects the last-known state; it neither grants nor needs background time.
    @State private var liveActivity = LiveActivityController()

    // Owned here so bookmarks/history survive BrowserModel being recreated when
    // the proxy port changes.
    @State private var library = BrowserLibrary()

    var body: some View {
        NavigationStack {
            Form {
                destinationsSection

                Section {
                    authKeyRow
                    LabeledField("Relay URLs", hint: "comma-separated, optional") {
                        TextField("", text: $client.relayURLs)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("Relay auth token", hint: "optional, custom relays only") {
                        SecureField("", text: $relayAuthToken)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    // Only custom relays can lack it; the default ones serve it.
                    if !relayURLList.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Relays serve QUIC address discovery",
                                   isOn: $client.relayQuicAddrDiscovery)
                                .accessibilityIdentifier("setup.relayQuicAddrDiscovery")
                            Text("Turn off for relays behind a Cloudflare Tunnel or another "
                                + "HTTP-only front, where it delays each start by up to 3 s.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("This device")
                } footer: {
                    Text("One key and one relay list for every destination. Put the "
                        + "public key on each server's authorized-keys file.")
                }

                // Both modes share the config above; pick one, and the single
                // CTA below takes its label from the choice.
                Section("Use it to") {
                    ForEach([SessionMode.browser, .proxyOnly], id: \.rawValue) { mode in
                        ModeChoiceRow(
                            icon: mode.icon,
                            title: mode.title,
                            description: mode.description,
                            isSelected: sessionMode == mode,
                            disabled: proxy.phase == .starting) {
                            sessionMode = mode
                        }
                        .accessibilityIdentifier("setup.mode.\(mode.rawValue)")
                    }
                }

                if sessionMode == .proxyOnly {
                    backgroundSection
                }

                Section {
                    if proxy.phase == .starting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(sessionMode.startingLabel)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { proxy.stop() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else {
                        Button(sessionMode.cta) {
                            startProxy(mode: sessionMode)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(!canStartProxy)
                        .accessibilityIdentifier("setup.start")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    if proxy.phase == .failed {
                        Text(proxy.lastError ?? proxy.status)
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .accessibilityIdentifier("setup.error")
                    }
                }

                AppVersionFooter()
            }
            .navigationTitle("flextunnel")
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $destinationDraft) { draft in
                DestinationEditSheet(
                    draft: draft,
                    routesAccess: routesAccess,
                    validate: { client.validated($0) },
                    onSave: { _ = client.save($0) },
                    onDelete: { client.delete(id: draft.id) })
            }
            .fullScreenCover(isPresented: browserIsPresented) {
                if let browserModel {
                    BrowserView(model: browserModel, proxy: proxy)
                        .interactiveDismissDisabled(proxy.socksPort != nil || proxy.isRelaunching)
                }
            }
            .fullScreenCover(isPresented: proxyOnlyIsPresented) {
                ProxyOnlyView(
                    proxy: proxy,
                    store: portForwards,
                    keepAlive: keepAlive,
                    onStop: {
                        proxy.stop()
                        // Explicitly drop the cover: the binding's setter only
                        // runs on a dismissal attempt, so stopping alone would
                        // leave the screen up showing a dead proxy.
                        proxyOnlyActive = false
                    })
                    .interactiveDismissDisabled(proxy.sessionAlive || proxy.isRelaunching)
            }
            .onChange(of: proxy.phase) {
                syncSessionPresentation()
                syncLiveActivity()
            }
            .onChange(of: proxy.socksPort) {
                syncSessionPresentation()
                syncKeepAlive()
            }
            .onChange(of: proxy.forwardingSessionID) {
                syncForwards()
            }
            .onChange(of: proxyOnlyActive) {
                syncKeepAlive()
                syncLiveActivity()
            }
            .onChange(of: proxy.sessionAlive) {
                syncForwards()
                syncKeepAlive()
                syncLiveActivity()
            }
            .onChange(of: proxy.connectedNames) { before, connected in
                // Persist the relay token only once a connection has been made
                // with it, so a typo'd credential (which starts fine but never
                // connects) doesn't overwrite a good one. Saved from what the
                // session was started with, not the live (still-editable)
                // field. Empty clears it (save treats "" as a clear). The auth
                // key was already saved at generation/import.
                if !connected.isEmpty, let token = unsavedRelayToken {
                    SecretStore.save(token, service: SecretStore.relayTokenService)
                    unsavedRelayToken = nil
                }
                // Pages that failed on a destination that wasn't reachable
                // reload once it connects — brought up by another tab, or a
                // forward — instead of leaving the error up.
                let reconnected = connected.subtracting(before)
                if !reconnected.isEmpty {
                    browserModel?.retryFailedLoads { url in
                        guard case .destination(let name) = proxy.pageRoute(for: url) else { return false }
                        return reconnected.contains(name)
                    }
                }
            }
            // `health` covers what the banner shows: a destination connecting,
            // connected or unreachable, and a relaunch in flight.
            .onChange(of: proxy.health) { syncLiveActivity() }
            .onChange(of: proxy.isRelaunching) { syncKeepAlive() }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
            // A key deleted on the Keys screen leaves the client's reference
            // to it dangling.
            .onChange(of: authKeys.keys.map(\.id)) { clearDanglingAuthKey() }
            .onAppear {
                #if DEBUG
                if let e2e = E2ELaunchConfig.current {
                    E2ELaunchConfig.apply(e2e, client: client, authKeys: authKeys, library: library)
                    sessionMode = .browser
                }
                #endif
                loadStoredSecrets()
                clearDanglingAuthKey()
                syncSessionPresentation()
                syncForwards()
                syncKeepAlive()
                // Let the poll loop refresh the Live Activity while backgrounded
                // under keep-alive (SwiftUI's .onChange above is paused then).
                // Background refreshes must not create an activity — Activity.request
                // is foreground-only — so they only update/end an existing one.
                proxy.onBackgroundLiveActivityRefresh = { syncLiveActivity(allowCreate: false) }
                proxy.onForwardStatusRefresh = {
                    portForwards.refreshRuntime()
                    // A forward carrying traffic is activity: it postpones the
                    // keep-alive's inactivity limit (and revives it if reached),
                    // so a stationary session in active use isn't dropped.
                    if proxyOnlyActive, portForwards.hasOpenConnections {
                        keepAlive.noteActivity()
                    }
                }
                keepAlive.onTimeout = { handleKeepAliveTimeout() }
                // Reconcile any Live Activity the controller reattached to on
                // launch with the real state (ends a leftover banner while idle).
                syncLiveActivity()
            }
        }
    }

    /// The key the client authenticates with; nil until one is picked (or
    /// after the picked key was deleted).
    private var selectedKey: AuthKeyStore.Key? {
        authKeys.key(id: client.authKeyID)
    }

    /// Drop a reference to a key that is gone — deleted on the Keys screen, or
    /// dropped as corrupt on load — so the Picker has a tag it can match ("")
    /// and shows "Pick a key…" rather than a blank selection.
    private func clearDanglingAuthKey() {
        if !client.authKeyID.isEmpty, selectedKey == nil {
            client.authKeyID = ""
        }
    }

    /// The servers this client reaches. A row opens its editor; the last row
    /// adds one.
    private var destinationsSection: some View {
        Section {
            ForEach(client.destinations) { destination in
                Button {
                    destinationDraft = DestinationDraft(destination: destination)
                } label: {
                    DestinationRow(destination: destination)
                }
                .buttonStyle(.plain)
                .disabled(proxy.phase == .starting)
                .accessibilityIdentifier("setup.destination.\(destination.name)")
            }
            .onDelete { offsets in
                offsets.map { client.destinations[$0].id }.forEach(client.delete)
            }
            Button {
                destinationDraft = DestinationDraft()
            } label: {
                Label("Add Destination", systemImage: "plus")
            }
            .disabled(proxy.phase == .starting)
            .accessibilityIdentifier("setup.addDestination")
        } header: {
            Text("Destinations")
        } footer: {
            Text("Each destination is a server, under the name you give it: "
                + "<name>.localhost.flextunnel.internal with a port is the port on the server "
                + "itself, and its routes are the other hosts sent through it. A server is only connected when "
                + "something is first sent to it.")
        }
    }

    /// The auth-key setup row: a picker over the named key list plus the
    /// picked key's public half — shown unmasked on purpose, it's what goes
    /// on the server's authorized-keys file. Everything else (generate,
    /// import, export, rename, delete) lives on the Keys screen.
    private var authKeyRow: some View {
        LabeledField(
            "Auth key",
            hint: selectedKey != nil ? "public key — give it to each server's operator" : nil
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if authKeys.keys.isEmpty {
                        Text("No keys yet")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Auth key", selection: $client.authKeyID) {
                            if selectedKey == nil {
                                Text("Pick a key…").tag("")
                            }
                            ForEach(authKeys.keys) { key in
                                Text(key.name).tag(key.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(proxy.phase == .starting)
                    }
                    Spacer(minLength: 4)
                    NavigationLink {
                        KeysView(store: authKeys, selectedKeyID: $client.authKeyID)
                    } label: {
                        Text("Manage…")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                }
                if let key = selectedKey {
                    HStack(spacing: 8) {
                        Text(key.publicKey)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button {
                            UIPasteboard.general.string = key.publicKey
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy public key")
                    }
                } else if authKeys.keys.isEmpty {
                    Text("Add one under Manage, then put its public key on each "
                        + "server's authorized-keys file.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The forwarding keep-alive opt-in, shown only while Forward ports is
    /// selected. It is decided here rather than mid-session so the location
    /// prompt is resolved (and a denial visible) before the session comes up.
    private var backgroundSection: some View {
        Section {
            Toggle("Keep alive in background", isOn: $keepAlive.enabled)
                .disabled(proxy.phase == .starting)
            if keepAlive.enabled {
                Picker("Time limit", selection: $keepAlive.timeoutMinutes) {
                    ForEach(BackgroundKeepAlive.timeoutChoices, id: \.self) { minutes in
                        Text(BackgroundKeepAlive.timeoutLabel(minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .disabled(proxy.phase == .starting)
            }
            if keepAlive.enabled, keepAlive.denied {
                Text("Location access is denied, so iOS suspends the app about 30 seconds after backgrounding and the port forwards stop until you return.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Allow location in Settings", systemImage: "location.slash")
                }
            }
        } header: {
            Text("Background")
        } footer: {
            Text(keepAlive.enabled ? enabledBackgroundFooter : disabledBackgroundFooter)
        }
    }

    private var disabledBackgroundFooter: String {
        "iOS suspends the app about 30 seconds after backgrounding; port forwards stop until you return."
    }

    private var enabledBackgroundFooter: String {
        "A coarse location session (nothing is stored or sent) keeps iOS from suspending the app, so port forwards stay reachable while you use other apps. It starts and stops with port forwarding. Expect the location indicator and some extra battery use."
            + " After \(keepAlive.timeoutLabel.lowercased()) with no movement, no open forward connection and the app not in front, it lets go: iOS then suspends the app, and port forwarding comes back automatically when you return."
    }

    private var browserIsPresented: Binding<Bool> {
        Binding {
            browserModel != nil
        } set: { isPresented in
            if !isPresented, !proxy.sessionAlive, !proxy.isRelaunching {
                // End the dead session with its screen, so it isn't left
                // `.running` behind the setup screen.
                proxy.stop()
                browserModel = nil
            }
        }
    }

    /// Mirror of `browserIsPresented`: no destination's trouble dismisses the
    /// screen; only an explicit Stop lets the cover go.
    private var proxyOnlyIsPresented: Binding<Bool> {
        Binding {
            proxyOnlyActive
        } set: { isPresented in
            if !isPresented, !proxy.sessionAlive, !proxy.isRelaunching {
                proxy.stop()
                proxyOnlyActive = false
            }
        }
    }

    private func startProxy(mode: SessionMode) {
        sessionMode = mode
        // A fresh session starts with every forward off: the CTA never
        // auto-starts forwards, the user enables what this session needs.
        // (Mid-session relaunches don't come through here, so they keep the
        // toggles as set.)
        portForwards.disableAll()
        let settings = currentSettings()
        unsavedRelayToken = settings.relayAuthToken
        proxy.start(settings)
    }

    private var canStartProxy: Bool {
        // A listed key always has a parsing secret (the store drops corrupt
        // records on load), so picked means usable.
        !client.destinations.isEmpty && selectedKey != nil
    }

    private func currentSettings() -> ProxyController.Settings {
        ProxyController.Settings(
            destinations: client.destinations.map { destination in
                .init(
                    name: destination.name,
                    serverNodeID: destination.serverNodeID,
                    routedDomains: destination.routedDomains,
                    routedCIDRs: destination.routedCIDRs)
            },
            authKey: selectedKey?.secret ?? "",
            // Forwarding-only sessions have no SOCKS listener. Browser mode
            // asks for an OS-assigned port; ProxyController pins the assigned
            // port into its replayed settings so relaunches keep it.
            socksPort: sessionMode == .browser ? 0 : nil,
            relayURLs: relayURLList,
            relayAuthToken: relayAuthToken,
            relayQuicAddrDiscovery: client.relayQuicAddrDiscovery
        )
    }

    /// The relay URLs field, split into its entries.
    private var relayURLList: [String] {
        client.relayURLs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What a destination's editor asks its server with (see `ServerRoutes`):
    /// the picked key and the relays as the fields hold them now, exactly what
    /// a session started this moment would use. Nil until a key is picked.
    private var routesAccess: ServerRoutes.Access? {
        guard let key = selectedKey else { return nil }
        return ServerRoutes.Access(
            authKey: key.secret, relayURLs: relayURLList, relayAuthToken: relayAuthToken,
            relayQuicAddrDiscovery: client.relayQuicAddrDiscovery)
    }

    /// Prefill the Keychain-backed relay token on first appearance (the auth
    /// keys load themselves in `AuthKeyStore.init`). Everything else the client
    /// holds is non-secret and loads with it. Guarded, so coming back from a
    /// pushed screen can't clobber a token that has been typed but not
    /// connected with yet.
    private func loadStoredSecrets() {
        guard !didLoadSecrets else { return }
        didLoadSecrets = true
        relayAuthToken = SecretStore.load(service: SecretStore.relayTokenService) ?? ""
    }

    /// Present-only: reveal the mode's screen once the session is running and
    /// never tear it down here. Nothing a destination does takes it down;
    /// teardown happens solely through the explicit-quit path —
    /// Stop → `proxy.stop()` → the presentation binding clears the state.
    private func syncSessionPresentation() {
        guard proxy.phase == .running else { return }

        switch sessionMode {
        case .browser:
            guard let socksPort = proxy.socksPort else { return }
            // The routing table is the session's own configuration, so the
            // browser's scoping is known before any server is contacted and
            // never changes; nil (no table, defensively) proxies every host.
            // The port is pinned for the session too (a relaunch that can't
            // bind it fails), so the browser is built once and never repointed.
            guard browserModel == nil else { return }
            browserModel = BrowserModel(
                socksPort: socksPort,
                proxyMatchDomains: proxy.routeTable?.proxyMatchDomains,
                routes: proxy.routeTable ?? RouteTable(entries: []),
                library: library)
        case .proxyOnly:
            proxyOnlyActive = true
        }
    }

    /// Keep native server-direct forwards tied to the current FFI session.
    private func syncForwards() {
        portForwards.syncProxy(proxy)
    }

    // MARK: - Background keep-alive

    /// The location keep-alive follows forwarding-only sessions. Browser sessions
    /// explicitly deactivate it even if the persisted forwarding preference is on.
    /// A relaunch keeps it: stopped mid-relaunch it couldn't restart if the app
    /// were backgrounded meanwhile.
    private func syncKeepAlive() {
        keepAlive.setSessionActive(proxyOnlyActive && (proxy.sessionAlive || proxy.isRelaunching))
    }

    /// Best-effort fallback for when the keep-alive is off (or location was
    /// denied): extended execution buys ~30s after backgrounding, then iOS
    /// suspends the process and defuncts its sockets; the next foreground
    /// relaunches the session (see `recoverFromSuspension`). Only forwarding mode
    /// can replace that fallback with the location session (`BackgroundKeepAlive`);
    /// browser mode always follows normal iOS/WebKit background suspension.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Pace for the background: the health poll drops to minute cadence
            // and each connected destination's heartbeat slows from every 10s
            // to every 60s.
            proxy.setBackgrounded(true)
            // Time spent in the app doesn't eat the keep-alive's inactivity
            // window: start it when the app actually goes away, so what the Live
            // Activity counts down from here is the full limit.
            if proxyOnlyActive { keepAlive.noteActivity() }
            // While the location keep-alive holds the process, the poll loop keeps
            // running: let it refresh the Live Activity in the background (SwiftUI's
            // .onChange handlers are paused now). Otherwise the banner is left live
            // and only dismissed at actual suspension (the expiration handler
            // below), so it lingers the full grace and a return to the foreground
            // within it keeps it live — no premature .end()/revive flicker.
            proxy.backgroundLiveActivityRefreshEnabled = proxyOnlyActive && keepAlive.isRunning
            // A relaunch still in flight counts: its new handle is suspended
            // like any other and needs the on-return recovery just the same.
            guard proxy.sessionAlive || proxy.isRelaunching, backgroundTask == .invalid else { break }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "flextunnel-proxy") {
                // Grace expired → iOS suspends us now (unless keep-alive holds the
                // process) and defuncts the forward listeners — remember that so the
                // next foreground rebinds them.
                wasSuspended = !(proxyOnlyActive && keepAlive.isRunning)
                if wasSuspended {
                    // A suspended process's listeners keep accepting into the
                    // kernel backlog and serve nothing; close them while we can
                    // still run so local clients get refused instead of hanging.
                    // The relaunch on return rebinds them.
                    proxy.closeListenersForSuspension()
                    // Suspended: a forwarding session's banner can no longer be
                    // kept fresh, so dismiss it now (≈ the grace after
                    // backgrounding); a no-op in browser mode, which has none.
                    // Hold the task assertion until the async dismissal actually
                    // registers, then end it — otherwise the app can suspend first
                    // and leave the banner behind. A foreground before this
                    // handler fires cancels the task, so the banner stays live.
                    Task {
                        await liveActivity.endNow()
                        endBackgroundTask()
                    }
                } else {
                    endBackgroundTask()
                }
            }
        case .active:
            endBackgroundTask()
            // Snap the poll and the core's heartbeat back to foreground cadence
            // (an overdue beat goes out immediately, and the poll refreshes now).
            proxy.setBackgrounded(false)
            proxy.backgroundLiveActivityRefreshEnabled = false
            // SwiftUI's .onChange handlers were paused while away, and a change
            // that netted out (a relaunched forwarding session) may never fire
            // them on return — reconcile everything they drive explicitly.
            syncSessionPresentation()
            syncForwards()
            syncKeepAlive()
            // Using the app is activity: refill the keep-alive's inactivity
            // window (and revive it if the limit was reached while away), so the
            // limit caps one stretch of backgrounded time.
            if proxyOnlyActive { keepAlive.noteActivity() }
            // Revive an expired banner (via start()) so a still-running session
            // is glanceable again on return.
            syncLiveActivity()
            if wasSuspended {
                wasSuspended = false
                recoverFromSuspension()
            }
        default:
            break
        }
    }

    /// The keep-alive reached its inactivity limit and is about to drop the
    /// location session, so iOS will suspend us exactly as it does with the
    /// keep-alive off — while we're still alive here, arm the same on-return
    /// recovery and dismiss the banner we can no longer keep fresh. Without the
    /// `wasSuspended` flag the app would come back with defunct sockets that
    /// still read as running.
    private func handleKeepAliveTimeout() {
        // The limit can only be reached while away (the keep-alive's idle check
        // refills the window whenever the app is in front); if we are in front
        // anyway, nothing is about to be suspended.
        guard proxyOnlyActive, scenePhase != .active else { return }
        wasSuspended = true
        // Same as the background-grace expiration handler: don't leave
        // black-hole listeners behind while suspended.
        proxy.closeListenersForSuspension()
        proxy.backgroundLiveActivityRefreshEnabled = false
        // Its own assertion: the backgrounding grace expired long ago, so
        // `backgroundTask` is spent. Held until the async dismissal registers,
        // otherwise the app can suspend first and leave the banner behind.
        let task = UIApplication.shared.beginBackgroundTask(withName: "flextunnel-keepalive-timeout")
        Task {
            await liveActivity.endNow()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    /// iOS marks the process's sockets defunct while it is suspended, and the
    /// core can't recover from that on its own: its local listeners and QUIC
    /// endpoints can wedge. Relaunch the session and reapply native forwards.
    private func recoverFromSuspension() {
        guard proxy.phase == .running else { return }
        proxy.relaunch()
        portForwards.rebindAfterSuspension()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Live Activity

    /// Mirror a forwarding session into the Live Activity: start/refresh it while
    /// the session runs and end it once it is gone. Browser sessions never get
    /// one: the banner exists for a session running behind other apps, which
    /// only forwarding does (a browser session is either on screen or suspended
    /// within the grace).
    /// `allowCreate` is false for background refreshes, which must never call
    /// `Activity.request` (foreground-only) — they only update/end an existing one.
    private func syncLiveActivity(allowCreate: Bool = true) {
        guard proxyOnlyActive, proxy.phase == .running else {
            liveActivity.end()
            return
        }
        let state = TunnelActivityAttributes.ContentState(
            level: liveActivityLevel,
            statusText: proxy.health.title,
            // Counted down by the widget itself, so it stays right between
            // refreshes (about once a minute while backgrounded).
            keepAliveDeadline: keepAlive.deadline
        )
        if allowCreate {
            liveActivity.start(state: state)
        } else {
            liveActivity.update(state)
        }
    }

    private var liveActivityLevel: TunnelActivityAttributes.ContentState.Level {
        switch proxy.health {
        case .connected, .ready: return .ok
        case .connecting, .restarting, .trouble: return .attention
        case .stopped: return .down
        }
    }
}

/// One destination on the setup screen: its name, and its server and
/// routes in brief.
private struct DestinationRow: View {
    let destination: ClientStore.Destination

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name)
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(destination.serverNodeID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(routesSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var routesSummary: String {
        let count = destination.routedDomains.count + destination.routedCIDRs.count
        switch count {
        case 0: return "The server itself only"
        case 1: return "The server itself and 1 route"
        default: return "The server itself and \(count) routes"
        }
    }
}

/// A radio-style choice row for one session mode: icon, title, short
/// description, and a trailing selection mark. The CTA lives below the list
/// and takes its label from the selected mode.
private struct ModeChoiceRow: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let disabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                    .padding(.top, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.vertical, 4)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A form row whose label stays visible above the field even after the field
/// has content — unlike a placeholder, which disappears once the user types.
private struct LabeledField<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
