import ActivityKit
import Foundation

/// Owns the single tunnel Live Activity: request it once the session connects,
/// push state updates as the link flaps, and end it on an explicit Stop. This is
/// UX only — it neither grants nor relies on background execution (see the
/// keep-alive note in `ContentView.handleScenePhase`). If the user has Live
/// Activities disabled system-wide, every call is a no-op.
@MainActor
final class LiveActivityController {
    private var activity: Activity<TunnelActivityAttributes>?

    /// Start the activity, or update it if one is already running (so callers can
    /// treat this as idempotent "reflect the connected state").
    func start(serverLabel: String, modeTitle: String, state: TunnelActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil {
            update(state)
            return
        }
        let attributes = TunnelActivityAttributes(serverLabel: serverLabel, modeTitle: modeTitle)
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: nil),
            pushType: nil
        )
    }

    func update(_ state: TunnelActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
