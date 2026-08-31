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
                return "Open the built-in browser through the tunnel. "
                    + "Private hostnames resolve on the server."
            case .proxyOnly:
                return "Run the proxy without the browser and forward local ports "
                    + "to private hosts, so other apps on this device "
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

        var connectingLabel: String {
            switch self {
            case .browser: return "Starting browser session…"
            case .proxyOnly: return "Starting port forwarding…"
            }
        }

        /// The line under the "Flextunnel" title in the Live Activity: what this
        /// session is doing with the tunnel.
        var liveActivitySubtitle: String {
            switch self {
            case .browser: return "Browsing through the tunnel"
            case .proxyOnly: return "Server-direct port forwarding"
            }
        }
    }

    @StateObject private var proxy = ProxyController()
    @StateObject private var portForwards = PortForwardController()
    // Location-based background keep-alive, active while a session of either mode
    // runs. Opting in is a top-level decision made below, before starting (see
    // BackgroundKeepAlive.swift and docs/background-keep-alive.md).
    @StateObject private var keepAlive = BackgroundKeepAlive()

    // The saved connection profiles. Every field in Setup below edits the
    // selected one, so pointing the app at another server is a pick rather
    // than a retype. Only the selected profile connects — one session at a
    // time, unlike the desktop.
    @StateObject private var profiles = ProfileStore()
    // The named client auth keys (Keychain-backed; see AuthKeyStore), one
    // shared list across profiles; each profile references a key by id. Keys
    // persist the moment they're generated or imported — unlike the relay
    // token there is no "known-good" moment to wait for: the public key must
    // be on the server's authorized-keys file before the first connect can
    // succeed.
    @StateObject private var authKeys = AuthKeyStore()
    @State private var relayAuthToken = ""
    @State private var browserModel: BrowserModel?
    @State private var didLoadSecrets = false
    // The immutable settings snapshot handed to `proxy.start`, so the Keychain
    // save on `.connected` persists the exact relay token that authenticated —
    // not whatever the (still-editable) field holds by the time the handshake
    // lands. (The auth key is saved at generation/import instead.)
    @State private var connectingSettings: ProxyController.Settings?
    // Which profile that snapshot belongs to, so the token lands in the
    // Keychain account of the profile that authenticated with it even if the
    // selection moved on meanwhile.
    @State private var connectingProfileID = ""
    // Remembered across launches: both modes share the config above, so the
    // choice is sticky and only the single CTA's label follows it.
    @AppStorage("lastSessionMode") private var sessionModeRaw = SessionMode.browser.rawValue
    @State private var proxyOnlyActive = false

    private var sessionMode: SessionMode {
        get { SessionMode(rawValue: sessionModeRaw) ?? .browser }
        nonmutating set { sessionModeRaw = newValue.rawValue }
    }

    // Best-effort background keep-alive: buys ~30s of runtime after backgrounding
    // so the tunnel and port forwards outlive a brief app switch.
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    // Set when the background grace expired with nothing holding the process
    // (see the expiration handler): iOS suspended the app and defunct'd the
    // forward listeners, so the next foreground must rebind them.
    @State private var wasSuspended = false

    // Tunnel status Live Activity (lock screen / Dynamic Island). UX only — it
    // reflects the last-known state; it neither grants nor needs background time.
    @State private var liveActivity = LiveActivityController()

    // Owned here so bookmarks/history survive BrowserModel being recreated when
    // the proxy port changes.
    @State private var library = BrowserLibrary()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    profileRow
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Each profile remembers its own server, auth key, relays and "
                        + "port forwards. Switching profiles here is only about not "
                        + "retyping them — one profile connects at a time.")
                }

                Section("Setup") {
                    LabeledField("Server node id") {
                        TextField("", text: $profiles.selected.serverNodeID)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    authKeyRow
                    LabeledField("Relay URLs", hint: "comma-separated, optional") {
                        TextField("", text: $profiles.selected.relayURLs)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("Relay auth token", hint: "optional, custom relays only") {
                        SecureField("", text: $relayAuthToken)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }

                // Both modes share the config above; pick one, and the single
                // CTA below takes its label from the choice.
                Section("Use the tunnel to") {
                    ForEach([SessionMode.browser, .proxyOnly], id: \.rawValue) { mode in
                        ModeChoiceRow(
                            icon: mode.icon,
                            title: mode.title,
                            description: mode.description,
                            isSelected: sessionMode == mode,
                            disabled: proxy.phase == .connecting) {
                            sessionMode = mode
                        }
                    }
                }

                backgroundSection

                Section {
                    if proxy.phase == .connecting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(sessionMode.connectingLabel)
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
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    if proxy.phase == .failed {
                        Text(proxy.lastError ?? proxy.status)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                AppVersionFooter()
            }
            .navigationTitle("flextunnel")
            .scrollDismissesKeyboard(.interactively)
            .fullScreenCover(isPresented: browserIsPresented) {
                if let browserModel {
                    BrowserView(model: browserModel, proxy: proxy, keepAlive: keepAlive)
                        .interactiveDismissDisabled(proxy.socksPort != nil)
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
                    .interactiveDismissDisabled(proxy.sessionAlive)
            }
            .onChange(of: proxy.phase) { _, newPhase in
                // Persist the relay token only once it has actually authenticated,
                // so a typo'd credential (which starts fine but fails the handshake)
                // never overwrites a good one. Save it from the snapshot the
                // connection used, not the live (still-editable) field. Empty
                // clears it (save treats "" as a clear). The auth key was already
                // saved at generation/import.
                if newPhase == .connected, let settings = connectingSettings {
                    SecretStore.save(
                        settings.relayAuthToken,
                        service: SecretStore.relayTokenService,
                        account: connectingProfileID)
                }
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
            .onChange(of: sessionScreenActive) {
                syncKeepAlive()
            }
            .onChange(of: proxy.sessionAlive) {
                syncForwards()
                syncKeepAlive()
                syncLiveActivity()
            }
            .onChange(of: proxy.tunnelConnected) { syncLiveActivity() }
            // A reconnect can land a changed tunnel set; keep the browser's
            // WebKit-level split-tunneling (matchDomains) in step with it.
            // Double optional on purpose: the outer nil (routes cleared while a
            // relaunch re-handshakes) keeps the last known scoping — browsing
            // stays independent of the proxy through the gap — while an inner
            // nil (full-tunnel set) must be applied.
            .onChange(of: proxy.forwardedRoutes.map(\.proxyMatchDomains)) { _, known in
                if let matchDomains = known {
                    browserModel?.updateProxyMatchDomains(matchDomains)
                }
            }
            // `tunnelStuck` flips without `tunnelConnected`/`sessionAlive` changing,
            // so it needs its own trigger to refresh the banner (→ "Disconnected").
            .onChange(of: proxy.tunnelStuck) { syncLiveActivity() }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
            // Switching profiles swaps everything the setup screen shows: the
            // fields follow `selected` on their own, these don't.
            .onChange(of: profiles.selectedID) { _, id in
                // Anything typed into the token field and not yet connected
                // with is dropped here on purpose — it is only persisted once
                // it has authenticated, so it would be lost at relaunch too.
                relayAuthToken = storedRelayToken(for: id)
                clearDanglingAuthKey()
                portForwards.setProfile(id)
            }
            // A profile deleted on the manage screen leaves its forwards behind.
            .onChange(of: profiles.profiles.map(\.id)) { _, ids in
                portForwards.pruneProfiles(keeping: Set(ids))
            }
            .onAppear {
                loadStoredSecrets()
                clearDanglingAuthKey()
                portForwards.setProfile(profiles.selectedID)
                portForwards.pruneProfiles(keeping: Set(profiles.profiles.map(\.id)))
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
                    if portForwards.hasOpenConnections { keepAlive.noteActivity() }
                }
                keepAlive.onTimeout = { handleKeepAliveTimeout() }
                // Reconcile any Live Activity the controller reattached to on
                // launch with the real state (ends a leftover banner while idle).
                syncLiveActivity()
            }
        }
    }

    /// The key the selected profile authenticates with; nil until one is picked
    /// (or after the picked key was deleted).
    private var selectedKey: AuthKeyStore.Key? {
        authKeys.key(id: profiles.selected.authKeyID)
    }

    /// Drop a reference to a key that is gone — deleted on the Keys screen, or
    /// dropped as corrupt on load — so the Picker has a tag it can match ("")
    /// and shows "Pick a key…" rather than a blank selection. Only the selected
    /// profile is swept, and that is enough: nothing reads another profile's
    /// reference until it is selected, which runs this again.
    private func clearDanglingAuthKey() {
        if !profiles.selected.authKeyID.isEmpty, selectedKey == nil {
            profiles.selected.authKeyID = ""
        }
    }

    /// The profile's own relay token, from its own Keychain account.
    private func storedRelayToken(for profileID: String) -> String {
        SecretStore.load(
            service: SecretStore.relayTokenService, account: profileID) ?? ""
    }

    /// The profile picker and the way to the manage screen. Everything else
    /// about a profile is edited in Setup below, for the picked one.
    private var profileRow: some View {
        HStack(spacing: 8) {
            Picker("Profile", selection: $profiles.selectedID) {
                ForEach(profiles.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(proxy.phase == .connecting)
            Spacer(minLength: 4)
            NavigationLink {
                ProfilesView(store: profiles)
            } label: {
                Text("Manage…")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)
            // Two rows on this screen show "Manage…"; spell out which is which
            // for VoiceOver, where the surrounding label isn't read with it.
            .accessibilityLabel("Manage profiles")
        }
    }

    /// The auth-key setup row: a picker over the named key list plus the
    /// picked key's public half — shown unmasked on purpose, it's what goes
    /// on the server's authorized-keys file. Everything else (generate,
    /// import, export, rename, delete) lives on the Keys screen.
    private var authKeyRow: some View {
        LabeledField(
            "Auth key",
            hint: selectedKey != nil ? "public key — give it to the server operator" : nil
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if authKeys.keys.isEmpty {
                        Text("No keys yet")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Auth key", selection: $profiles.selected.authKeyID) {
                            if selectedKey == nil {
                                Text("Pick a key…").tag("")
                            }
                            ForEach(authKeys.keys) { key in
                                Text(key.name).tag(key.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(proxy.phase == .connecting)
                    }
                    Spacer(minLength: 4)
                    NavigationLink {
                        KeysView(store: authKeys, selectedKeyID: $profiles.selected.authKeyID)
                    } label: {
                        Text("Manage…")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Manage auth keys")
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
                    Text("Add one under Manage, then put its public key on the "
                        + "server's authorized-keys file.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The keep-alive opt-in: a top-level decision for whichever mode is
    /// started, made here rather than mid-session so the location prompt is
    /// resolved (and a denial visible) before the tunnel comes up. The in-session
    /// screens show it read-only.
    private var backgroundSection: some View {
        Section {
            Toggle("Keep alive in background", isOn: $keepAlive.enabled)
                .disabled(proxy.phase == .connecting)
            if keepAlive.enabled {
                Picker("Time limit", selection: $keepAlive.timeoutMinutes) {
                    ForEach(BackgroundKeepAlive.timeoutChoices, id: \.self) { minutes in
                        Text(BackgroundKeepAlive.timeoutLabel(minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .disabled(proxy.phase == .connecting)
            }
            if keepAlive.enabled, keepAlive.denied {
                Text("Location access is denied, so iOS suspends the app about 30 seconds after backgrounding and the session stops until you return.")
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
        "iOS suspends the app about 30 seconds after backgrounding; the session stops until you return."
    }

    private var enabledBackgroundFooter: String {
        "A coarse location session (nothing is stored or sent) keeps iOS from suspending the app, so the tunnel — and any port forwards — keep running while you use other apps. It starts with the session and stops when you stop it. Expect the location indicator and some extra battery use."
            + " After \(keepAlive.timeoutLabel.lowercased()) with no movement, no open forward connection and the app not in front, it lets go: iOS then suspends the app, and the session comes back automatically when you return."
    }

    private var browserIsPresented: Binding<Bool> {
        Binding {
            browserModel != nil
        } set: { isPresented in
            if !isPresented, !proxy.sessionAlive {
                browserModel = nil
            }
        }
    }

    /// Mirror of `browserIsPresented`: a tunnel drop never dismisses the screen;
    /// only an explicit Stop lets the cover go.
    private var proxyOnlyIsPresented: Binding<Bool> {
        Binding {
            proxyOnlyActive
        } set: { isPresented in
            if !isPresented, !proxy.sessionAlive {
                proxyOnlyActive = false
            }
        }
    }

    private func startProxy(mode: SessionMode) {
        sessionMode = mode
        // A fresh session starts with every forward off: the CTA never
        // auto-starts tunnels, the user enables what this session needs.
        // (Mid-session reconnects don't come through here, so they keep the
        // toggles as set.)
        portForwards.disableAll()
        let settings = currentSettings()
        connectingSettings = settings
        connectingProfileID = profiles.selectedID
        proxy.start(settings)
    }

    private var trimmedServerNodeID: String {
        profiles.selected.serverNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStartProxy: Bool {
        // A listed key always has a parsing secret (the store drops corrupt
        // records on load), so picked means usable.
        !trimmedServerNodeID.isEmpty && selectedKey != nil
    }

    private func currentSettings() -> ProxyController.Settings {
        ProxyController.Settings(
            serverNodeID: trimmedServerNodeID,
            authKey: selectedKey?.secret ?? "",
            // Forwarding-only sessions have no SOCKS listener. Browser mode
            // asks for an OS-assigned port; ProxyController pins the assigned
            // port into its replayed settings so reconnects keep it.
            socksPort: sessionMode == .browser ? 0 : nil,
            relayURLs: splitCSV(profiles.selected.relayURLs),
            relayAuthToken: relayAuthToken
        )
    }

    private func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Prefill the selected profile's Keychain-backed relay token on first
    /// appearance (the auth keys load themselves in `AuthKeyStore.init`).
    /// Everything else the profile holds is non-secret and loads with it.
    /// Guarded, so coming back from a pushed screen can't clobber a token that
    /// has been typed but not connected with yet.
    private func loadStoredSecrets() {
        guard !didLoadSecrets else { return }
        didLoadSecrets = true
        relayAuthToken = storedRelayToken(for: profiles.selectedID)
    }

    /// Present-only: reveal the mode's screen once the handshake lands and never
    /// tear it down here. A drop after connecting keeps it up (the tunnel
    /// auto-reconnects); teardown happens solely through the explicit-quit path —
    /// Stop → `proxy.stop()` → the presentation binding clears the state.
    private func syncSessionPresentation() {
        guard proxy.phase == .connected else { return }

        switch sessionMode {
        case .browser:
            guard let socksPort = proxy.socksPort else { return }
            // Routes are known here: the poll learns them before flipping the
            // phase to connected. Nil (defensively) proxies every host.
            let matchDomains = proxy.forwardedRoutes?.proxyMatchDomains
            if browserModel == nil {
                browserModel = BrowserModel(
                    socksPort: socksPort, proxyMatchDomains: matchDomains, library: library)
            } else if browserModel?.socksPort != socksPort {
                browserModel?.stopAll()
                browserModel = BrowserModel(
                    socksPort: socksPort, proxyMatchDomains: matchDomains, library: library)
            }
        case .proxyOnly:
            proxyOnlyActive = true
        }
    }

    /// Keep native server-direct forwards tied to the current FFI session.
    private func syncForwards() {
        portForwards.syncProxy(proxy)
    }

    // MARK: - Background keep-alive

    /// A session screen is up, in either mode — what the keep-alive and the Live
    /// Activity both follow.
    private var sessionScreenActive: Bool {
        proxyOnlyActive || browserModel != nil
    }

    /// The location keep-alive follows the session, whichever mode it is: it runs
    /// whenever a session screen is up with a live native session, and stops with
    /// it (so the location indicator never outlives the tunnel).
    private func syncKeepAlive() {
        keepAlive.setSessionActive(sessionScreenActive && proxy.sessionAlive)
    }

    /// Best-effort fallback for when the keep-alive is off (or location was
    /// denied): extended execution buys ~30s after backgrounding, then iOS
    /// suspends the process and defuncts its sockets; the next foreground
    /// relaunches the session (see `recoverFromSuspension`). With the keep-alive
    /// on, the location session (`BackgroundKeepAlive`) holds the process instead
    /// and neither mode is suspended.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Pace for the background: the health poll drops to minute cadence
            // and the core's heartbeat slows to 60s, so a held-alive idle
            // session wakes the cellular radio once a minute instead of
            // continuously.
            proxy.setBackgrounded(true)
            // Time spent in the app doesn't eat the keep-alive's inactivity
            // window: start it when the app actually goes away, so what the Live
            // Activity counts down from here is the full limit.
            keepAlive.noteActivity()
            // While the location keep-alive holds the process, the poll loop keeps
            // running: let it refresh the Live Activity in the background (SwiftUI's
            // .onChange handlers are paused now). Otherwise the banner is left live
            // and only dismissed at actual suspension (the expiration handler
            // below), so it lingers the full grace and a return to the foreground
            // within it keeps it live — no premature .end()/revive flicker.
            proxy.backgroundLiveActivityRefreshEnabled = keepAlive.isRunning
            guard proxy.sessionAlive, backgroundTask == .invalid else { break }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "flextunnel-proxy") {
                // Grace expired → iOS suspends us now (unless keep-alive holds the
                // process) and defuncts the forward listeners — remember that so the
                // next foreground rebinds them.
                wasSuspended = !keepAlive.isRunning
                if wasSuspended {
                    // A suspended process's listeners keep accepting into the
                    // kernel backlog and serve nothing; close them while we can
                    // still run so local clients get refused instead of hanging.
                    // The relaunch on return rebinds them.
                    proxy.closeListenersForSuspension()
                    // Suspended: the banner can no longer be kept fresh, so dismiss
                    // it now (≈ the grace after backgrounding). Hold the task
                    // assertion until the async dismissal actually registers, then
                    // end it — otherwise the app can suspend first and leave the
                    // banner behind. A foreground before this handler fires cancels
                    // the task, so the banner stays live.
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
            proxy.noteForegrounded()
            // Using the app is activity: refill the keep-alive's inactivity
            // window (and revive it if the limit was reached while away), so the
            // limit caps one stretch of backgrounded time.
            keepAlive.noteActivity()
            // Revive an expired banner (via start()) so a still-connected session
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
    /// still read "connected".
    private func handleKeepAliveTimeout() {
        // The limit can only be reached while away (the keep-alive's idle check
        // refills the window whenever the app is in front); if we are in front
        // anyway, nothing is about to be suspended.
        guard scenePhase != .active else { return }
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
    /// endpoint can wedge. Relaunch the session and reapply native forwards.
    private func recoverFromSuspension() {
        guard proxy.phase == .connected else { return }
        proxy.retryNow()
        portForwards.rebindAfterSuspension()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Live Activity

    /// Mirror the session into the Live Activity: start/refresh it while connected,
    /// reflect a reconnect while connecting, and end it once the session is gone.
    /// Both modes get one — either can be held alive in the background now, and a
    /// backgrounded session is exactly when a glanceable banner earns its place.
    /// `allowCreate` is false for background refreshes, which must never call
    /// `Activity.request` (foreground-only) — they only update/end an existing one.
    private func syncLiveActivity(allowCreate: Bool = true) {
        guard sessionScreenActive else {
            liveActivity.end()
            return
        }
        switch proxy.phase {
        case .connected:
            let state = TunnelActivityAttributes.ContentState(
                tunnelConnected: proxy.tunnelConnected,
                socksAlive: proxy.sessionAlive,
                statusText: liveActivityStatusText,
                // Counted down by the widget itself, so it stays right between
                // refreshes (about once a minute while backgrounded).
                keepAliveDeadline: keepAlive.deadline
            )
            if allowCreate {
                liveActivity.start(subtitle: sessionMode.liveActivitySubtitle, state: state)
            } else {
                liveActivity.update(state)
            }
        case .connecting:
            // A reconnect (retryNow) passes through .connecting with a live banner —
            // reflect it as reconnecting rather than leaving the stale "Connected".
            // update() is a no-op when there's no banner (initial connect), so it
            // never creates one here.
            liveActivity.update(TunnelActivityAttributes.ContentState(
                tunnelConnected: false,
                socksAlive: proxy.sessionAlive,
                statusText: "Reconnecting…",
                keepAliveDeadline: keepAlive.deadline
            ))
        case .idle, .failed:
            liveActivity.end()
        }
    }

    private var liveActivityStatusText: String {
        if proxy.tunnelConnected { return "Connected" }
        // Stuck: the core's own reconnect is presumed wedged (manual retry needed),
        // so it reads disconnected rather than optimistically "Reconnecting…".
        if proxy.tunnelStuck { return "Disconnected" }
        if proxy.sessionAlive { return "Reconnecting…" }
        return "Disconnected"
    }
}

/// A radio-style choice row for one tunnel mode: icon, title, short
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
