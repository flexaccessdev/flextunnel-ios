import ActivityKit
import Foundation
import os

/// Owns the single tunnel Live Activity: request it once the session connects,
/// push state updates as the link flaps, and end it on an explicit Stop. This is
/// UX only — it neither grants nor relies on background execution (see the
/// keep-alive note in `ContentView.handleScenePhase`). If the user has Live
/// Activities disabled system-wide, every call is a no-op.
@MainActor
final class LiveActivityController {
    private var activity: Activity<TunnelActivityAttributes>?
    private let log = Logger(subsystem: "com.andrewtheguy.flextunnel", category: "LiveActivity")

    /// Reattach to a Live Activity that outlived a previous run (Live Activities
    /// survive force-quit/relaunch). Without this the fresh `nil` reference would
    /// orphan that banner — `end()` couldn't reach it and `start()` would spawn a
    /// duplicate. Only one is ever expected; end any extras defensively. Callers
    /// then `syncLiveActivity()` (from `onAppear`) to reconcile it with real state.
    init() {
        let survivors = Activity<TunnelActivityAttributes>.activities
        activity = survivors.first
        for extra in survivors.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// How long a pushed state stays trustworthy. Past this the widget flips to a
    /// "status unknown — open app" look (via `context.isStale`) instead of showing
    /// a confidently-stale value. This matters while the app keeps running but
    /// stops updating (e.g. a location-keep-alive session in the background);
    /// once the app is suspended the banner is instead scheduled to be dismissed
    /// (see `expire(after:)`).
    private static let staleAfter: TimeInterval = 90

    /// Start the activity, or update it if one is already live (so callers can
    /// treat this as idempotent "reflect the connected state"). If the previous
    /// activity was scheduled to expire on backgrounding (now `.ended`) or was
    /// dismissed, drop it and request a fresh one — this revives the banner when
    /// the user foregrounds a still-connected session.
    func start(serverLabel: String, modeTitle: String, state: TunnelActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let current = activity {
            switch current.activityState {
            case .active, .stale:
                update(state)
                return
            case .ended, .dismissed:
                // Scheduled to expire, or already gone. Pull it now so it can't
                // linger alongside the fresh one, then fall through to request.
                Task { await current.end(nil, dismissalPolicy: .immediate) }
                activity = nil
            @unknown default:
                break
            }
        }
        let attributes = TunnelActivityAttributes(serverLabel: serverLabel, modeTitle: modeTitle)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content(state),
                pushType: nil
            )
        } catch {
            log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ state: TunnelActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(content(state)) }
    }

    /// Schedule the banner to disappear about `interval` from now, matching when
    /// iOS suspends the backgrounded app (its sockets defunct, so the last state
    /// stops being meaningful). A scheduled `.after` dismissal is honored by the
    /// system even while the process is suspended, so no post-suspension code is
    /// needed. The `activity` reference is kept so `start()` can revive it if the
    /// app returns to the foreground before the dismissal lands.
    func expire(after interval: TimeInterval) {
        guard let activity,
              activity.activityState == .active || activity.activityState == .stale
        else { return }
        Task { await activity.end(nil, dismissalPolicy: .after(Date().addingTimeInterval(interval))) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func content(
        _ state: TunnelActivityAttributes.ContentState
    ) -> ActivityContent<TunnelActivityAttributes.ContentState> {
        .init(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }
}
