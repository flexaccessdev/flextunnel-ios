import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen banner + Dynamic Island rendering for the tunnel session. Colors
/// follow tunnel-link state: green when connected, orange while reconnecting.
struct TunnelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TunnelActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.serverLabel, systemImage: "lock.shield.fill")
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusPill(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.modeTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(context.state.statusColor)
            } compactTrailing: {
                Circle()
                    .fill(context.state.statusColor)
                    .frame(width: 8, height: 8)
            } minimal: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(context.state.statusColor)
            }
        }
    }
}

private struct LockScreenView: View {
    let attributes: TunnelActivityAttributes
    let state: TunnelActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(state.statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.serverLabel)
                    .font(.headline)
                    .lineLimit(1)
                Text(attributes.modeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(state: state)
        }
    }
}

private struct StatusPill: View {
    let state: TunnelActivityAttributes.ContentState

    var body: some View {
        Text(state.statusText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.statusColor)
            .lineLimit(1)
    }
}

extension TunnelActivityAttributes.ContentState {
    var statusColor: Color {
        if tunnelConnected { return .green }
        if socksAlive { return .orange }
        return .secondary
    }
}
