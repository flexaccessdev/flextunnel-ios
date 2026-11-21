import Foundation
import Combine
import Network

/// Drives the in-process flextunnel client via the Rust FFI (libflextunnel.a).
/// Browser sessions expose a SOCKS5 port to WKWebView; forwarding-only sessions
/// expose no proxy and use native server-direct forward listeners.
///
/// One session serves every configured destination. Starting it connects
/// nothing: the core connects a destination's server when something is first
/// sent to it, and closes the connection again once it has gone unused. So a
/// session is *running* as soon as its listeners are bound, and the state of
/// each server is its destination's, read from the core on every poll.
@MainActor
final class ProxyController: ObservableObject {
    /// Lifecycle phase. Drives whether the session's screen is presented: it
    /// appears once the session is `.running`, and stays until an explicit
    /// quit.
    enum Phase: Equatable {
        case idle
        /// The native session is being started (no screen presented yet).
        case starting
        /// The session started; its screen is presented. Relaunches of the
        /// native session (`isRelaunching`) and a session that died stay in
        /// this phase.
        case running
        /// The start failed (terminal; shown on the setup screen).
        case failed
    }

    /// A destination's connection state, as the core reports it.
    enum LinkState: String {
        /// Not connected and nothing is asking for it — the resting state.
        case idle
        /// Building its endpoint, connecting or authenticating.
        case connecting
        case connected
        /// The last attempt failed and requests are still waiting on a retry.
        case backoff
        /// The server refused this client (an unauthorized key, say); requests
        /// fail at once until the core's next attempt.
        case failed
    }

    /// One destination's state, safe to show in UI. Only what changes when the
    /// state does: the per-second counters the core also reports (connection
    /// age, open streams) are left out, so the 1 Hz poll republishes nothing
    /// while a destination sits in one state.
    struct DestinationStatus: Identifiable, Equatable {
        var name: String
        var serverNodeID: String
        var state: LinkState
        /// What the last failed attempt said. Kept by the core while the
        /// destination is idle again, and cleared by a successful connection —
        /// so an idle destination carrying one failed the last time it was used.
        var lastError: String?
        var routedDomains: [String]
        var routedCIDRs: [String]

        var id: String { name }

        /// Idle after a failed attempt: it retries on its next use, not before.
        var lastAttemptFailed: Bool { state == .idle && lastError != nil }
    }

    /// The session's overall state, for the surfaces that show one indicator.
    enum Health: Equatable {
        /// The native session ended; nothing is served until it is restarted.
        case stopped
        /// The native session is being replaced.
        case restarting
        /// A destination can't be reached: it is retrying, was refused, or
        /// failed the last time it was used.
        case trouble
        /// A destination is connecting, none is in trouble.
        case connecting
        /// At least one destination is connected, none is in trouble.
        case connected
        /// Running with every destination idle: each connects when used.
        case ready

        var title: String {
            switch self {
            case .stopped: return "Stopped"
            case .restarting: return "Restarting"
            case .trouble: return "Unreachable"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .ready: return "Ready"
            }
        }
    }

    @Published var status: String = "idle"
    @Published var lastError: String?
    /// Current lifecycle phase; drives whether the session's screen is presented.
    @Published private(set) var phase: Phase = .idle
    /// Loopback SOCKS5 port the core actually bound, or nil while stopped. In
    /// browser mode this is an OS-assigned ephemeral port, pinned into the
    /// replayed settings so it survives relaunches; forwarding-only mode
    /// leaves it nil.
    @Published var socksPort: UInt16?
    /// The native session is alive (FFI health == 1). In browser mode it also
    /// owns the SOCKS5 listener; forwarding-only mode has no proxy listener.
    @Published var sessionAlive: Bool = false
    /// Changes for every successfully-created native session. Port forwarding
    /// uses this to apply its desired listener set to a replacement handle.
    @Published private(set) var forwardingSessionID: UUID?
    /// An established session's native handle is being replaced (manual
    /// restart, suspension recovery) and the new one hasn't started yet. The
    /// session's screen stays up throughout.
    @Published private(set) var isRelaunching: Bool = false
    /// Each destination's state, in the order configured. Empty while stopped
    /// and until a new session's first poll.
    @Published private(set) var destinations: [DestinationStatus] = []
    /// The session's routing table — fixed for its lifetime, since routing is
    /// this client's configuration and nothing about it is learned from a
    /// server. Nil while no session is running.
    @Published private(set) var routeTable: RouteTable?
    /// The relay URLs the running session uses; empty means iroh's defaults.
    @Published private(set) var relayURLs: [String] = []

    /// Called (on the main actor) from the poll loop when the Live-Activity-
    /// relevant state changes while a forwarding session is backgrounded with
    /// keep-alive — the hook `ContentView` uses to refresh the banner without
    /// SwiftUI's `.onChange` (which doesn't fire while backgrounded). Only invoked while
    /// `backgroundLiveActivityRefreshEnabled` is set.
    var onBackgroundLiveActivityRefresh: (() -> Void)?
    /// Called after each native health poll so the port-forward controller can
    /// refresh listener and active-connection status.
    var onForwardStatusRefresh: (() -> Void)?
    /// Set by `ContentView` while a forwarding keep-alive is holding the
    /// backgrounded process; gates `onBackgroundLiveActivityRefresh`.
    /// Clearing it resets the keep-alive refresh clock so the next background
    /// stint re-arms immediately.
    var backgroundLiveActivityRefreshEnabled = false {
        didSet { if !backgroundLiveActivityRefreshEnabled { lastBackgroundRefresh = nil } }
    }
    /// When the background Live Activity was last refreshed, so a periodic
    /// re-arm keeps its `staleDate` in the future while the app stays alive (even
    /// with no state change); nil until the first background refresh.
    private var lastBackgroundRefresh: Date?
    /// Re-arm cadence for the background refresh — shorter than the Live
    /// Activity's stale window (`LiveActivityController.staleAfter`, 90s) so the
    /// banner never falsely reads stale while the app is genuinely running, yet
    /// still goes stale within ~90s if the app actually stops updating. Kept
    /// just under `backgroundPollInterval` so every backgrounded poll re-arms
    /// the banner — at 60 the elapsed check could race the poll cadence and
    /// skip to the next tick, ~120s later, past the stale window.
    private static let backgroundRefreshInterval: TimeInterval = 50

    /// The subset of state the Live Activity reflects; compared across a poll to
    /// detect a meaningful change worth pushing to the banner.
    private struct LiveActivityState: Equatable {
        let phase: Phase
        let health: Health
    }
    private var liveActivityState: LiveActivityState {
        LiveActivityState(phase: phase, health: health)
    }

    /// Borrowed from `native` for the status calls; nil whenever a start or stop
    /// that could end it has been issued.
    private var handle: OpaquePointer?
    private let native = NativeSession()
    private var healthTimer: Timer?
    /// Health-poll cadence while the app is frontmost. Low Power Mode halves
    /// the discretionary polling — the poll is pure status/UI work, so slower
    /// updates are exactly the trade Low Power Mode asks for.
    private var foregroundPollInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 2.0 : 1.0
    }
    /// Health-poll cadence while backgrounded (under the location keep-alive —
    /// without it the app is suspended shortly anyway). A 1 Hz poll with the
    /// screen off is the classic energy anti-pattern: backgrounded, the poll
    /// only feeds the Live Activity re-arm and the keep-alive's activity
    /// sampling, both of which run at minute granularity.
    private static let backgroundPollInterval: TimeInterval = 60
    /// Mirrors the scene phase (set by `ContentView`); drives the poll cadence
    /// here and the core's heartbeat cadence over the FFI.
    private var isBackgrounded = false
    /// Last path verdict from `NWPathMonitor`, forwarded to the core so no
    /// destination dials while there is genuinely no network.
    private var pathAvailable = true
    private let pathMonitor = NWPathMonitor()
    private var lowPowerObserver: NSObjectProtocol?
    /// Last settings that drove a launch, replayed by a relaunch.
    private var lastSettings: Settings?
    /// Bumped on every start and teardown so an in-flight async start whose FFI
    /// finishes after a newer start/stop is discarded instead of clobbering state.
    private var startEpoch = 0

    /// What a session is started with.
    struct Settings {
        /// One server this client reaches; see `ClientStore.Destination`.
        struct Destination {
            var name: String
            var serverNodeID: String
            var routedDomains: [String]
            var routedCIDRs: [String]
        }

        var destinations: [Destination]
        /// The client auth secret key ("ed25519-sec:…"); its public half must
        /// be on every server's authorized-keys file.
        var authKey: String
        /// Loopback SOCKS5 port for browser mode. `nil` means a forwarding-only
        /// session with no SOCKS5 listener; `0` requests an OS-assigned
        /// ephemeral port; the bound port is published as `socksPort`. Nonzero
        /// is the session's pinned port, replayed by relaunches, and is
        /// required: a relaunch that can't bind it fails.
        var socksPort: UInt16?
        var relayURLs: [String]
        /// Shared bearer token sent to every custom relay's WebSocket upgrade.
        /// Empty means none; only valid with custom `relayURLs`.
        var relayAuthToken: String

        var routeTable: RouteTable {
            RouteTable(entries: destinations.map {
                RouteTable.Entry(name: $0.name, domains: $0.routedDomains, cidrs: $0.routedCIDRs)
            })
        }
    }

    /// A single connection-path snapshot — one iroh path to a server — for the
    /// on-demand "connection path" readout. Mirrors the desktop's `ConnPath` and
    /// `ezvpn client status`; produced by `queryConnPath(name:)`.
    struct ConnPath: Identifiable {
        /// Stable synthetic identity = the path's index in the snapshot. `display`
        /// can't be the id: it embeds the RTT, so it churns every refresh for the
        /// same path (breaking `ForEach` row identity) and two paths could collide.
        let id: Int
        var kind: Kind
        /// Human line like `Direct 1.2.3.4:52186 (rtt 1ms)` or
        /// `Relay https://… (rtt 42ms)`.
        var display: String
        /// Whether iroh currently routes traffic over this path.
        var selected: Bool

        enum Kind: String {
            case direct, relay, other

            /// Parse the FFI JSON token, defaulting to `.other` for anything
            /// unrecognized (a missing field or a future value).
            init(token: String?) {
                self = token.flatMap(Kind.init(rawValue:)) ?? .other
            }
        }
    }

    /// Health of one configured custom relay, from the on-demand `/healthz`
    /// probe the core runs when a snapshot is requested. `working` is `true` on a
    /// 2xx, `false` when unreachable/timed-out/non-2xx, and `nil` if the check
    /// could not run. `/healthz` is unauthenticated: it confirms the relay is up,
    /// not that a relay auth token is accepted.
    struct CustomRelay: Identifiable {
        let url: String
        var working: Bool?
        var error: String?

        var id: String { url }
    }

    /// One on-demand connection snapshot: a destination's live iroh path(s)
    /// plus custom-relay health. No paths while the destination isn't connected.
    struct ConnectionSnapshot {
        var paths: [ConnPath] = []
        var customRelays: [CustomRelay] = []
        /// UDP datagrams the live connection has sent/received since it was
        /// established (0 while disconnected). On cellular, energy is
        /// per-wakeup rather than per-byte, so the tx count sampled across an
        /// interval — e.g. across a backgrounded stint — is the cheap proxy for
        /// the tunnel's radio cost.
        var udpTxDatagrams: UInt64 = 0
        var udpRxDatagrams: UInt64 = 0
    }

    /// The session's overall state: one indicator over every destination.
    var health: Health {
        if isRelaunching { return .restarting }
        guard sessionAlive else { return .stopped }
        if destinations.contains(where: { $0.state == .backoff || $0.state == .failed || $0.lastAttemptFailed }) {
            return .trouble
        }
        if destinations.contains(where: { $0.state == .connecting }) { return .connecting }
        if destinations.contains(where: { $0.state == .connected }) { return .connected }
        return .ready
    }

    /// The destinations connected right now.
    var connectedNames: Set<String> {
        Set(destinations.lazy.filter { $0.state == .connected }.map(\.name))
    }

    /// The destinations that can't be reached right now (see `Health.trouble`).
    var troubledNames: [String] {
        destinations
            .filter { $0.state == .backoff || $0.state == .failed || $0.lastAttemptFailed }
            .map(\.name)
    }

    func destination(name: String) -> DestinationStatus? {
        destinations.first { $0.name == name }
    }

    init() {
        flextunnel_init_logging()
        // Watch the device's network path for the whole controller lifetime and
        // feed it to whichever session is live: while no path is usable the
        // core dials nothing (no backoff timers into a dead network), and the
        // path's return gives every destination with requests waiting an
        // immediate attempt.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.notePathChanged(available) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "flextunnel.path-monitor"))
        // Low Power Mode only changes the discretionary poll cadence; it can
        // flip while a session runs, so re-arm the timer when it does.
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reschedulePolling() }
        }
    }

    /// Scene-phase mirror from `ContentView`. Backgrounded, the health poll
    /// drops to minute cadence and the core slows each connected destination's
    /// heartbeat — that connection's only periodic traffic — from every 10s to
    /// every 60s (each destination beats on its own clock, so several
    /// connected ones don't line up); foregrounded, both snap back, the core
    /// ends any retry backoff in progress, and an immediate poll refreshes the
    /// UI.
    func setBackgrounded(_ backgrounded: Bool) {
        guard backgrounded != isBackgrounded else { return }
        isBackgrounded = backgrounded
        if let handle { _ = flextunnel_set_background(handle, backgrounded ? 1 : 0) }
        reschedulePolling()
    }

    private func notePathChanged(_ available: Bool) {
        guard available != pathAvailable else { return }
        pathAvailable = available
        if let handle { _ = flextunnel_set_network_available(handle, available ? 1 : 0) }
    }

    /// Re-arm the poll timer at the cadence for the current scene phase and
    /// power state — only if polling is running at all (a dead session's
    /// stopped poll stays stopped).
    private func reschedulePolling() {
        guard healthTimer != nil else { return }
        startHealthPolling()
    }

    /// Raw result of the blocking start FFI, handed back to the main actor.
    /// `@unchecked Sendable`: the `OpaquePointer` is produced on the lifecycle
    /// queue and only ever read on the main actor after the hop, never shared.
    fileprivate struct StartResult: @unchecked Sendable {
        let handle: OpaquePointer?
        let message: String
    }

    /// User-initiated start from the setup screen: always a fresh session,
    /// whatever state a previous one was left in.
    func start(_ s: Settings) {
        launch(s, relaunch: false)
    }

    /// Builds the FFI config, starts the client, and publishes the bound port.
    ///
    /// The starting state is published immediately, then the blocking
    /// `flextunnel_start` (and any previous handle's teardown) runs on the
    /// lifecycle queue so the UI shows the spinner instead of freezing on the tap.
    ///
    /// A relaunch replaces an established session's handle in place and the
    /// phase stays `.running`, so the session's screen stays up.
    private func launch(_ s: Settings, relaunch: Bool) {
        lastSettings = s
        lastError = nil

        // Drop the previous session's published state now, synchronously, so the
        // UI updates before the blocking FFI. The lifecycle queue stops the
        // previous handle before starting the new one; a bumped epoch discards
        // any in-flight start we're superseding.
        startEpoch &+= 1
        let epoch = startEpoch
        handle = nil
        stopPolling()
        forwardingSessionID = nil
        socksPort = nil
        sessionAlive = false
        destinations = []
        if relaunch {
            isRelaunching = true
            status = "restarting session…"
        } else {
            isRelaunching = false
            routeTable = nil
            relayURLs = []
            phase = .starting
            status = "starting…"
        }

        let relayAuthToken = s.relayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let configDict: [String: Any] = [
            "auth_key": s.authKey,
            "socks_port": s.socksPort.map { Int($0) } ?? NSNull(),
            "relay_urls": s.relayURLs,
            "relay_auth_token": relayAuthToken.isEmpty ? NSNull() : relayAuthToken,
            "destinations": s.destinations.map { destination in
                [
                    "name": destination.name,
                    "server_node_id": destination.serverNodeID,
                    "routed_domains": destination.routedDomains,
                    "routed_cidrs": destination.routedCIDRs,
                ] as [String: Any]
            },
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: configDict),
            let configStr = String(data: data, encoding: .utf8)
        else {
            launchFailed("failed to encode config JSON")
            return
        }

        native.launch(config: configStr) { result in
            Task { @MainActor in self.finishStart(result, settings: s, epoch: epoch) }
        }
    }

    /// Publishes the outcome of a launch back on the main actor.
    private func finishStart(_ result: StartResult, settings s: Settings, epoch: Int) {
        // A newer start()/teardown superseded this launch. Nothing to stop here:
        // whatever superseded it was queued behind this launch on the lifecycle
        // queue and ends the handle it produced.
        guard epoch == startEpoch else { return }

        guard let handle = result.handle else {
            launchFailed(result.message)
            return
        }

        guard
            let resultData = result.message.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            launchFailed("bad result JSON: \(result.message)")
            return
        }
        let port: UInt16?
        if let value = obj["socks_port"] as? Int, (1...65535).contains(value) {
            port = UInt16(value)
        } else if obj["socks_port"] is NSNull {
            port = nil
        } else {
            launchFailed("bad result JSON: \(result.message)")
            return
        }

        self.handle = handle
        // A fresh handle starts foregrounded-and-online in the core; replay the
        // actual scene/path state so a session launched while backgrounded (the
        // keep-alive's suspension recovery) or offline paces itself correctly.
        _ = flextunnel_set_background(handle, isBackgrounded ? 1 : 0)
        _ = flextunnel_set_network_available(handle, pathAvailable ? 1 : 0)
        routeTable = s.routeTable
        relayURLs = s.relayURLs
        socksPort = port
        // Pin the OS-assigned SOCKS port so relaunches of this session (manual
        // restart, suspend recovery) bind the same port and the browser's
        // proxy config stays valid; one that can't get it back fails the start.
        lastSettings?.socksPort = port
        forwardingSessionID = UUID()
        isRelaunching = false
        // The listeners are bound and the client is serving. No server has been
        // contacted, and none needs to be: each connects on first use.
        phase = .running
        startHealthPolling()
    }

    /// Explicit user quit: fully tear down.
    func stop() {
        teardownHandle()
        routeTable = nil
        relayURLs = []
        phase = .idle
        status = "idle"
    }

    /// Whether Restart does anything right now: only for an established
    /// session, and not while a relaunch is already in flight.
    var canRestart: Bool {
        phase == .running && lastSettings != nil && !isRelaunching
    }

    /// Manual restart — the way out of a session that died, or of a destination
    /// that stays unreachable: a fresh session drops every connection and
    /// builds each destination's endpoint anew on its next use. Ignored while
    /// `canRestart` is false: a second tap during a relaunch would only restart
    /// it from scratch.
    func restartNow() {
        guard canRestart else { return }
        relaunch()
    }

    /// Replace the established session's native handle with a fresh one from
    /// the last settings. Unlike `restartNow` it doesn't defer to a relaunch in
    /// progress: the suspension recovery needs a handle whose sockets were never
    /// frozen, and the lifecycle queue makes back-to-back launches safe.
    func relaunch() {
        guard phase == .running, let lastSettings else { return }
        launch(lastSettings, relaunch: true)
    }

    /// Suspension is imminent: close the core's local listeners (the SOCKS5
    /// front-end and every forward listener) so local clients get an immediate
    /// connection-refused instead of hanging in a frozen process's accept
    /// backlog. One-way for this handle — the on-foreground recovery
    /// (`ContentView.recoverFromSuspension`) relaunches the session, which
    /// rebinds everything. Guarded to `.running` because that recovery only
    /// relaunches running sessions; pausing any other phase would orphan a
    /// handle that never gets its listeners back.
    func closeListenersForSuspension() {
        guard phase == .running, let handle else { return }
        _ = flextunnel_close_listeners(handle)
    }

    private func stopPolling() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Stop the FFI handle and polling and clear per-session state. The
    /// session's configuration (its routing table and relays) is left to the
    /// caller: a session that ended behind its own screen still shows it.
    private func teardownHandle() {
        // Supersede any in-flight async start so its result is discarded; the
        // shutdown queued behind it stops whatever handle it produces.
        startEpoch &+= 1
        stopPolling()
        handle = nil
        native.shutdown()
        forwardingSessionID = nil
        socksPort = nil
        sessionAlive = false
        isRelaunching = false
        destinations = []
    }

    /// A launch couldn't produce a usable session. Before the session's screen
    /// is up that's the setup screen's failure; for an established session the
    /// screen stays up, offering Restart.
    private func launchFailed(_ reason: String) {
        teardownHandle()
        if phase == .running {
            // The routing table stays: the session's screen still labels pages
            // and forwards with it while the user decides to restart or quit.
            status = "session stopped — tap Restart"
            lastError = reason
        } else {
            phase = .failed
            status = "couldn't start: \(reason)"
            lastError = status
        }
    }

    // MARK: - Healthcheck

    private func startHealthPolling() {
        healthTimer?.invalidate()
        let interval = isBackgrounded ? Self.backgroundPollInterval : foregroundPollInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Let the system coalesce the fire with other wakeups; the poll reads
        // state that is not deadline-sensitive at a 10% slip.
        timer.tolerance = interval * 0.1
        healthTimer = timer
        poll() // first read without waiting a full interval
    }

    private func poll() {
        guard let handle else { return }

        // While the location keep-alive holds the app in the background, SwiftUI
        // stops firing the `.onChange` handlers that refresh the Live Activity —
        // so drive it from this poll (which keeps running under keep-alive)
        // instead: snapshot the banner-relevant state and, if it changed this
        // tick, ask `ContentView` to re-sync. Gated to the background+keep-alive
        // case so it never fights the foreground `.onChange` path.
        let liveStateBefore = liveActivityState
        defer {
            if backgroundLiveActivityRefreshEnabled {
                let changed = liveActivityState != liveStateBefore
                let elapsed = lastBackgroundRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
                // Refresh on a real change, or periodically to re-arm the stale
                // window so the banner stays fresh while the app is alive.
                if changed || elapsed >= Self.backgroundRefreshInterval {
                    lastBackgroundRefresh = Date()
                    onBackgroundLiveActivityRefresh?()
                }
            }
        }

        // health == 0 means the client ended, which only happens when a local
        // listener is lost for good — no destination's trouble ends it. Keep
        // the session's screen mounted but mark it unusable, offering Restart.
        if flextunnel_health(handle) == 0 {
            sessionAlive = false
            destinations = []
            status = "session stopped — tap Restart"
            stopPolling()
            return
        }

        publish(\.sessionAlive, true)
        refreshDestinations()
        onForwardStatusRefresh?()
        publish(\.status, runningStatus)
    }

    /// Writes a published property only when the value changes. Every write
    /// fires `objectWillChange`, so the 1 Hz poll republishing the same state
    /// re-rendered the browser each tick, rebuilding an open ⋯ menu under the
    /// user's finger and dropping the tap.
    private func publish<Value: Equatable>(_ property: ReferenceWritableKeyPath<ProxyController, Value>, _ value: Value) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }

    private var runningStatus: String {
        let listening = socksPort.map { "listening on 127.0.0.1:\($0)" } ?? "running"
        let connected = connectedNames.count
        return connected == 0 ? listening : "\(listening) · \(connected) connected"
    }

    struct NativeForwardStatus {
        var state: PortForwardState
        var active: Int
        var lastConnectionError: String?
    }

    /// Reconcile the complete desired native forward set. Returns an error
    /// message when the session is unavailable or the FFI rejects the config.
    func setPortForwards(_ forwards: [PortForward]) -> String? {
        guard let handle else { return "the session is not running" }
        let values: [[String: Any]] = forwards.map { forward in
            [
                "id": forward.id.uuidString,
                "local_port": Int(forward.localPort),
                "remote_host": forward.remoteHost,
                "remote_port": Int(forward.remotePort),
                "enabled": forward.enabled,
            ]
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: values),
            let json = String(data: data, encoding: .utf8)
        else { return "failed to encode forwards" }
        var buf = [CChar](repeating: 0, count: 4096)
        let result = json.withCString { cstr in
            flextunnel_set_forwards(handle, cstr, &buf, buf.count)
        }
        return result == 1 ? nil : String(cString: buf)
    }

    /// Read the core-owned direct-forward listener states. The FFI returns the
    /// byte count the JSON needs (incl. NUL); a first buffer that turns out too
    /// small is regrown to exactly that and the call repeated, so an oversized
    /// snapshot delays a status refresh by one call instead of silently keeping
    /// stale state forever.
    func portForwardStatuses() -> [UUID: NativeForwardStatus]? {
        guard let handle else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        var required = flextunnel_forward_statuses(handle, &buf, buf.count)
        if required > buf.count {
            buf = [CChar](repeating: 0, count: required)
            required = flextunnel_forward_statuses(handle, &buf, buf.count)
        }
        guard required >= 0, required <= buf.count,
              let data = String(cString: buf).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["forwards"] as? [[String: Any]] else { return nil }
        var statuses: [UUID: NativeForwardStatus] = [:]
        for entry in entries {
            guard let idText = entry["id"] as? String, let id = UUID(uuidString: idText) else {
                continue
            }
            let state: PortForwardState
            switch entry["state"] as? String {
            case "starting": state = .starting
            case "listening": state = .listening
            case "failed": state = .failed(entry["error"] as? String ?? "listener failed")
            default: state = .stopped
            }
            statuses[id] = NativeForwardStatus(
                state: state,
                active: entry["active"] as? Int ?? 0,
                lastConnectionError: entry["last_conn_error"] as? String)
        }
        return statuses
    }

    /// Poll the core for each destination's state. Reading it never causes a
    /// connection. The snapshot grows with the destination list, so a buffer
    /// that turns out too small is doubled and the call repeated.
    private func refreshDestinations() {
        guard let handle else { return }
        var buf = [CChar](repeating: 0, count: 64 * 1024)
        var written = flextunnel_status(handle, &buf, buf.count)
        while written == 0, buf.count < 4 * 1024 * 1024 {
            buf = [CChar](repeating: 0, count: buf.count * 2)
            written = flextunnel_status(handle, &buf, buf.count)
        }
        guard written == 1,
              let data = String(cString: buf).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["destinations"] as? [[String: Any]] else { return }

        publish(\.destinations, entries.compactMap { entry -> DestinationStatus? in
            guard let name = entry["name"] as? String,
                  let state = (entry["state"] as? String).flatMap(LinkState.init(rawValue:)) else {
                return nil
            }
            return DestinationStatus(
                name: name,
                serverNodeID: entry["server_node_id"] as? String ?? "",
                state: state,
                lastError: entry["last_error"] as? String,
                routedDomains: entry["routed_domains"] as? [String] ?? [],
                routedCIDRs: entry["routed_cidrs"] as? [String] ?? [])
        })
    }

    /// One-shot snapshot of the iroh path(s) to the destination `name` — a
    /// point-in-time readout (relay/direct) for the "connection path" sheet,
    /// mirroring the desktop CTA. No paths unless that destination is
    /// connected, so callers only offer it for one that is; asking never
    /// connects it.
    func queryConnPath(name: String) -> ConnectionSnapshot {
        guard let handle else { return ConnectionSnapshot() }
        var buf = [CChar](repeating: 0, count: 8 * 1024)
        let written = name.withCString { cstr in
            flextunnel_conn_path(handle, cstr, &buf, buf.count)
        }
        guard written == 1,
              let data = String(cString: buf).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ConnectionSnapshot() }

        let paths = (obj["paths"] as? [[String: Any]] ?? []).enumerated().compactMap {
            index, entry -> ConnPath? in
            guard let display = entry["display"] as? String else { return nil }
            return ConnPath(
                id: index,
                kind: .init(token: entry["kind"] as? String),
                display: display,
                selected: entry["selected"] as? Bool ?? false)
        }
        let customRelays = (obj["custom_relays"] as? [[String: Any]] ?? []).compactMap {
            entry -> CustomRelay? in
            guard let url = entry["url"] as? String else { return nil }
            // `working` is a JSON bool or null; `NSNull`/absent both map to nil.
            return CustomRelay(
                url: url,
                working: entry["working"] as? Bool,
                error: entry["error"] as? String)
        }
        return ConnectionSnapshot(
            paths: paths,
            customRelays: customRelays,
            udpTxDatagrams: (obj["udp_tx_datagrams"] as? NSNumber)?.uint64Value ?? 0,
            udpRxDatagrams: (obj["udp_rx_datagrams"] as? NSNumber)?.uint64Value ?? 0)
    }

    deinit {
        healthTimer?.invalidate()
        pathMonitor.cancel()
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
        }
        native.shutdown()
    }
}

/// Owns the native handle's lifetime on one serial queue. The core runs at most
/// one instance and refuses a second `flextunnel_start` while one is live, so
/// every start and stop runs here in the order it was issued: a launch stops
/// its predecessor before starting, and a stop issued while a launch is still
/// running waits for it and then stops what it produced. The main actor only
/// borrows the current pointer for status calls, and drops it before issuing
/// anything that ends it.
private final class NativeSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "flextunnel.session-lifecycle", qos: .userInitiated)
    /// Only touched on `queue`.
    private var current: OpaquePointer?

    /// Stop the current handle, if any, then validate the config and bind the
    /// local listeners — off the UI thread, since stopping the predecessor
    /// closes its endpoints first. Queued before returning, so it is ordered
    /// against a `shutdown` the caller issues right after; `completion` runs on
    /// the queue.
    func launch(config: String, completion: @escaping @Sendable (ProxyController.StartResult) -> Void) {
        queue.async {
            self.stopCurrent()
            var buf = [CChar](repeating: 0, count: 2048)
            let handle = config.withCString { cstr in
                flextunnel_start(cstr, &buf, buf.count)
            }
            self.current = handle
            completion(ProxyController.StartResult(handle: handle, message: String(cString: buf)))
        }
    }

    func shutdown() {
        queue.async { self.stopCurrent() }
    }

    private func stopCurrent() {
        guard let current else { return }
        flextunnel_stop(current)
        self.current = nil
    }
}
