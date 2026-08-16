import CoreLocation
import Foundation
import SwiftUI
import UIKit

/// Location-based background keep-alive, common to both session modes — the
/// same technique Termius and Blink use: while a continuous Core Location
/// session is running, iOS does not suspend the app, so the tunnel (and any
/// server-direct port forwards other apps reach at localhost) stays up
/// indefinitely instead of dying ~30s after backgrounding.
///
/// Runs while a session is up (`setSessionActive`) and the persisted `enabled`
/// preference is on (off by default, like Termius's opt-in setting). The
/// preference is a top-level decision made on the home screen before starting,
/// not a per-mode one — see docs/background-keep-alive.md.
///
/// The accuracy is deliberately coarse (100 km, like Blink's `geo track`) so
/// fixes come from cell towers rather than the GPS radio, and no fix is ever
/// stored or sent — a fix is only compared against the last one to tell whether
/// the device moved. The session stops with the session it holds up, so the
/// location indicator never outlives it.
///
/// `timeoutMinutes` caps how long an *inactive* session is held: with nothing
/// moving, nothing connected through a forward and the app not in front, the
/// location session gives up rather than holding the process (and the battery)
/// forever. Expiry stops the location session and lets iOS suspend the app the
/// same way it does with the keep-alive off — `ContentView` then relaunches the
/// session on return.
@MainActor
final class BackgroundKeepAlive: NSObject, ObservableObject {
    /// The persisted "Keep alive in background" preference; off by default, so
    /// no location prompt until the user opts in.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            // Resolve permission at the decision point (the home screen, before
            // any session): the prompt never lands mid-connect, and `denied` is
            // visible in time to matter. No location session starts here —
            // `reconcile` still requires an active session for that.
            if enabled, authorization == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            resetIdleWindow()
            reconcile()
        }
    }

    /// Minutes of inactivity after which the keep-alive gives up. Persisted
    /// alongside `enabled` and settable on the home screen only.
    @Published var timeoutMinutes: Int {
        didSet {
            UserDefaults.standard.set(timeoutMinutes, forKey: Self.timeoutKey)
            // A new limit starts a fresh window, and un-expires a keep-alive
            // that had already given up under the old one.
            resetIdleWindow()
            reconcile()
        }
    }

    @Published private(set) var authorization: CLAuthorizationStatus
    /// Whether the location session is currently running.
    @Published private(set) var isRunning = false
    /// The inactivity limit was reached: the location session was stopped and
    /// iOS is free to suspend the app. Cleared by `noteActivity`.
    @Published private(set) var timedOut = false

    /// Called when the limit is reached, while the app is still alive (the
    /// location session is stopped immediately after). A callback rather than a
    /// `@Published` read, because SwiftUI's `.onChange` handlers are paused
    /// while backgrounded — which is the only time this fires.
    var onTimeout: (() -> Void)?

    /// The offered limits, in the picker's order. There is deliberately no
    /// unbounded option: using the app and carrying traffic through a forward
    /// both postpone the limit indefinitely, so a session in use never needs one.
    static let timeoutChoices = [5, 15, 30, 60]
    private static let defaultTimeoutMinutes = 5
    private static let defaultsKey = "keepAliveInBackground"
    private static let timeoutKey = "keepAliveTimeoutMinutes"
    /// How far a fix must be from the last one to count as movement. Fixes at
    /// 100 km desired accuracy are tower-grade, so anything smaller is jitter;
    /// this is roughly Core Location's own significant-change distance.
    private static let movementThreshold: CLLocationDistance = 500
    /// The window is checked periodically against a wall clock rather than
    /// armed as a one-shot at the deadline, so a coalesced fire can't silently
    /// extend it and a changed limit applies on the next tick.
    private static let idleCheckInterval: TimeInterval = 60

    private let manager: CLLocationManager
    private var sessionActive = false
    private var lastActivity = Date()
    /// The last fix movement was measured from; moved only when the device
    /// actually moved, so slow drift accumulates instead of resetting per fix.
    private var movementAnchor: CLLocation?
    private var idleTimer: Timer?
    /// Retries a start that was skipped because the app was backgrounded (see
    /// `startUpdates`) once the app is in front again.
    private var foregroundObserver: NSObjectProtocol?

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        // Anything not on offer any more (a limit dropped from `timeoutChoices`)
        // falls back to the default, so the picker always has a matching row.
        timeoutMinutes = Self.sanitized(
            UserDefaults.standard.object(forKey: Self.timeoutKey) as? Int)
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // A start can only take effect in the foreground (see `startUpdates`);
        // one that was skipped while backgrounded is retried here.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// Location permission is missing, so the session dies shortly after
    /// backgrounding — surfaced in the UI with a path to Settings.
    var denied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// What the in-session screens read: the decision lives on the home screen,
    /// so both the browser and the forwarding screen show this read-only.
    enum Status {
        /// Opted out; iOS suspends the app shortly after backgrounding.
        case off
        /// Opted in, but location permission is missing — same outcome as `off`.
        case denied
        /// Opted in and permitted; the location session starts with the tunnel.
        case pending
        /// The location session is running: the app survives backgrounding.
        case active
        /// The inactivity limit was reached, so the keep-alive let go.
        case timedOut
    }

    var status: Status {
        guard enabled else { return .off }
        if denied { return .denied }
        if timedOut { return .timedOut }
        return isRunning ? .active : .pending
    }

    var statusLabel: String {
        switch status {
        case .off: return "off"
        case .denied: return "needs location access"
        case .pending: return "starts with the session"
        case .active: return "active"
        case .timedOut: return "timed out"
        }
    }

    /// Paired with `statusLabel` so the forwarding screen and the browser's
    /// tunnel popover read the same, without each re-deriving the mapping.
    var statusColor: Color? {
        switch status {
        case .active: return .green
        case .denied: return .red
        case .timedOut: return .orange
        case .off, .pending: return nil
        }
    }

    /// The current limit, for the picker and the screens that name it.
    var timeoutLabel: String { Self.timeoutLabel(timeoutMinutes) }

    /// When the inactivity limit will be reached if nothing resets the window
    /// first — nil unless the location session is actually holding the app, so
    /// callers can treat it as "how much longer this session is held". Estimated:
    /// expiry is noticed on a periodic check, so the stop lands at or shortly
    /// after this. Fed to the Live Activity, which counts it down itself.
    var deadline: Date? {
        guard isRunning else { return nil }
        return lastActivity.addingTimeInterval(Double(timeoutMinutes) * 60)
    }

    static func timeoutLabel(_ minutes: Int) -> String {
        switch minutes {
        case 1: return "1 minute"
        case ..<60: return "\(minutes) minutes"
        case 60: return "1 hour"
        default: return "\(minutes / 60) hours"
        }
    }

    private static func sanitized(_ minutes: Int?) -> Int {
        guard let minutes, timeoutChoices.contains(minutes) else {
            return defaultTimeoutMinutes
        }
        return minutes
    }

    /// Follows the session (either mode): the keep-alive runs only while one is up.
    func setSessionActive(_ active: Bool) {
        if active != sessionActive {
            sessionActive = active
            // Every session — and every gap between them — starts with a full
            // window. Only on a real transition: this is called repeatedly with
            // the same value, and re-stamping each time would defeat the limit.
            resetIdleWindow()
        }
        reconcile()
    }

    /// Something happened that means the session isn't idle: the device moved, a
    /// forward is carrying a connection, or the app came to the front. Restarts
    /// the location session if the limit had already been reached.
    func noteActivity() {
        lastActivity = Date()
        guard timedOut else { return }
        timedOut = false
        reconcile()
    }

    private func resetIdleWindow() {
        lastActivity = Date()
        timedOut = false
    }

    private func reconcile() {
        guard enabled && sessionActive && !timedOut else {
            stopUpdates()
            return
        }
        switch authorization {
        case .notDetermined:
            // Updates start from the grant's authorization callback.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdates()
        default:
            stopUpdates() // denied/restricted; see `denied`
        }
    }

    private func startUpdates() {
        guard !isRunning else { return }
        // With When In Use authorization, a location session only holds the
        // process if it was started in the foreground — one started while the
        // app is already backgrounded delivers nothing, yet `isRunning` would
        // read true and `ContentView` would skip arming the on-return recovery
        // (`wasSuspended`) on the strength of it. Skip instead, truthfully not
        // running; the `didBecomeActive` observer retries once in front.
        guard UIApplication.shared.applicationState != .background else { return }
        manager.desiredAccuracy = 100_000 // coarse on purpose: no GPS, minimal battery
        manager.pausesLocationUpdatesAutomatically = false
        // Requires the `location` UIBackgroundModes entry in Info.plist.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRunning = true
        lastActivity = Date()
        startIdleTimer()
    }

    private func stopUpdates() {
        stopIdleTimer()
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        isRunning = false
        // The next run measures movement from where it resumes, not from a fix
        // that may be hours old.
        movementAnchor = nil
    }

    // MARK: - Inactivity limit

    private func startIdleTimer() {
        stopIdleTimer()
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleCheckInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func checkIdle() {
        guard isRunning else { return }
        // The app being in front is activity in itself — browsing produces no
        // other signal (no forward connections, movement only past 500 m) — so
        // refill the window on every check rather than expiring a session the
        // user is looking at. The scene-phase refills in `ContentView` cover
        // the transitions; this covers a foreground stint longer than the limit.
        if UIApplication.shared.applicationState == .active {
            lastActivity = Date()
            return
        }
        guard Date().timeIntervalSince(lastActivity) >= Double(timeoutMinutes) * 60 else { return }
        timedOut = true
        // Before letting go: the app is still definitely alive here, which the
        // Live Activity dismissal (and arming the on-return recovery) needs.
        onTimeout?()
        stopUpdates()
    }

    /// Movement resets the inactivity window. Deliberately measured from the
    /// fixes the keep-alive already receives — no accuracy or filter change, so
    /// no extra battery cost for the timeout.
    private func noteFix(_ fix: CLLocation) {
        // A fix delivered after the session stopped says nothing about now.
        guard isRunning else { return }
        guard let anchor = movementAnchor else {
            movementAnchor = fix // seed: the first fix isn't movement
            return
        }
        guard fix.distance(from: anchor) >= Self.movementThreshold else { return }
        movementAnchor = fix
        noteActivity()
    }
}

extension BackgroundKeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.reconcile()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        // Fixes are never stored or sent: the updates exist to keep the app
        // alive, and the coordinate is only compared against the last one to
        // tell whether the device moved (see `noteFix`).
        guard let fix = locations.last else { return }
        Task { @MainActor in self.noteFix(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient fix failures (indoors, airplane mode) don't stop the
        // session; the running session is what keeps the app alive.
    }
}
