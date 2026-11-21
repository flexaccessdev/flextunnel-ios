import SwiftUI
import UIKit

/// Full-screen forwarding-only session: each destination's state and the
/// server-direct local forwards, with no browser and no SOCKS5 listener. Other apps on the device
/// reach the configured forwards at localhost while this app is alive; when the
/// keep-alive was opted into on the start screen, the location session (see
/// `BackgroundKeepAlive`) holds this one in the background, otherwise it is
/// best-effort (~30s before suspension).
struct ProxyOnlyView: View {
    @ObservedObject var proxy: ProxyController
    @ObservedObject var store: PortForwardController
    @ObservedObject var keepAlive: BackgroundKeepAlive
    let onStop: () -> Void

    @State private var editingDraft: ForwardDraft?
    /// The destination whose on-demand connection-path snapshot is shown.
    @State private var connPathTarget: ConnPathTarget?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                destinationsSection
                forwardsSection
                backgroundSection

                Section {
                    // A destination that can't be reached retries on its own
                    // whenever a forward uses it; Restart is the way out when
                    // that isn't enough, or when the session itself ended. Held
                    // off while a relaunch is in flight.
                    if proxy.health == .stopped || proxy.health == .trouble || proxy.health == .restarting {
                        Button {
                            proxy.restartNow()
                        } label: {
                            Label("Restart Session", systemImage: "arrow.clockwise")
                        }
                        .disabled(!proxy.canRestart)
                    }
                    Button(role: .destructive, action: onStop) {
                        Label("Stop Forwarding", systemImage: "stop.circle")
                    }
                }

                AppVersionFooter()
            }
            .navigationTitle("Port Forwarding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingDraft = ForwardDraft()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add port forward")
                }
            }
            .sheet(item: $editingDraft) { draft in
                ForwardEditSheet(
                    draft: draft,
                    isLocalPortTaken: { store.isLocalPortTaken($0, excluding: draft.existingID) },
                    destination: { proxy.routeTable?.destination(for: $0) },
                    onSave: { forward in
                        if draft.existingID != nil {
                            store.update(forward)
                        } else {
                            store.add(forward)
                        }
                    })
            }
            .sheet(item: $connPathTarget) { target in
                ConnPathSheet(name: target.name, query: { proxy.queryConnPath(name: target.name) })
            }
        }
    }

    // MARK: - Status

    /// The session as a whole. Each server's own state is its destination's,
    /// in the section below.
    private var statusSection: some View {
        Section("Session") {
            HStack {
                Label(proxy.health.title, systemImage: healthIcon)
                    .font(.headline)
                    .foregroundStyle(proxy.health.color)
                Spacer()
                if proxy.health.isTransient {
                    ProgressView()
                }
            }

            InfoRow("State", proxy.status)
            InfoRow("Forward engine", proxy.sessionAlive ? "running" : "stopped",
                    valueColor: proxy.sessionAlive ? .green : .red)
            if proxy.routeTable != nil {
                InfoRow("Relay URLs", proxy.relayURLs.isEmpty
                    ? "iroh defaults"
                    : proxy.relayURLs.joined(separator: "\n"))
                InfoRow("iroh peer discovery", "enabled (n0 discovery)")
            }

            if let error = proxy.lastError {
                InfoRow("Last error", error, valueColor: .red)
            }
        }
    }

    /// Each destination: its state, what is routed through it — which is what
    /// a forward can target — and, while it is connected, the one-shot snapshot
    /// of its live iroh path.
    private var destinationsSection: some View {
        Section {
            ForEach(proxy.destinations) { destination in
                VStack(alignment: .leading, spacing: 6) {
                    Text(destination.name)
                        .font(.subheadline.monospaced().weight(.medium))
                        .textSelection(.enabled)
                    DestinationStateRow(destination: destination)
                    InfoRow("Server node id", destination.serverNodeID, monospace: true)
                    InfoRow(
                        "Reaches",
                        (["\(RouteTable.loopbackHost(destination.name)) (with a port: the server itself)"]
                            + destination.routedDomains + destination.routedCIDRs)
                            .joined(separator: "\n"),
                        monospace: true)
                    if destination.state == .connected {
                        Button {
                            connPathTarget = ConnPathTarget(name: destination.name)
                        } label: {
                            Label("Connection path", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Destinations")
        } footer: {
            Text("A destination connects when a forward first uses it, and disconnects after 5 minutes unused. A forward waits for it to connect, and fails if it can't be reached.")
        }
    }

    private var healthIcon: String {
        switch proxy.health {
        case .connected: return "bolt.horizontal.circle.fill"
        case .ready, .connecting, .restarting: return "bolt.horizontal.circle"
        case .trouble, .stopped: return "bolt.slash.circle"
        }
    }

    // MARK: - Forwards

    private var forwardsSection: some View {
        Section {
            if store.forwards.isEmpty {
                Text("No port forwards. Tap + to forward a local port to a host behind one of the destinations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.forwards) { forward in
                ForwardRow(
                    forward: forward,
                    status: store.runtime[forward.id] ?? .init(),
                    routeTable: proxy.routeTable,
                    onToggle: { store.setEnabled($0, id: forward.id) })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingDraft = ForwardDraft(forward: forward)
                    }
            }
            .onDelete { store.remove(atOffsets: $0) }
        } header: {
            Text("Port forwards")
        } footer: {
            Text("Forwards listen on localhost (127.0.0.1 and ::1) and are reachable from other apps on this device while flextunnel is running.")
        }
    }

    // MARK: - Background keep-alive

    /// Read-only: the keep-alive is a top-level decision taken on the start screen
    /// before connecting, so this reports its live status and — when location
    /// permission is missing — the path to fix it.
    private var backgroundSection: some View {
        Section {
            InfoRow(
                "Background keep-alive", keepAlive.statusLabel,
                valueColor: keepAlive.statusColor)
            if keepAlive.enabled, keepAlive.denied {
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
            Text(backgroundFooter)
        }
    }

    private var backgroundFooter: String {
        switch keepAlive.status {
        case .off:
            return "iOS suspends the app about 30 seconds after backgrounding and forwards stop until you return. Turn on \"Keep alive in background\" on the start screen before connecting."
        case .denied:
            return "Location access is denied, so the keep-alive can't run: iOS suspends the app about 30 seconds after backgrounding and forwards stop until you return."
        case .timedOut:
            return "The keep-alive hit its \(keepAlive.timeoutLabel.lowercased()) inactivity limit and let go, so iOS suspended the app and forwards stopped. They rebind automatically now that you're back."
        case .pending, .active:
            return "A coarse location session (nothing is stored or sent) keeps iOS from suspending the app, so forwards stay reachable while you use other apps. It stops when you stop forwarding."
                + " It also lets go after \(keepAlive.timeoutLabel.lowercased()) with no movement, no open forward connection and the app not in front — set the limit on the start screen."
        }
    }
}

// MARK: - Forward row

private struct ForwardRow: View {
    let forward: PortForward
    let status: PortForwardController.RuntimeStatus
    let routeTable: RouteTable?
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(forward.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(forward.routeDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // On its own line: it names a destination, which may be too
                // long to share one with the forward's name.
                routeBadge
                statusLine
            }
            Spacer()
            Toggle("", isOn: Binding(get: { forward.enabled }, set: onToggle))
                .labelsHidden()
                .accessibilityIdentifier("forward.enabled")
        }
        .padding(.vertical, 2)
    }

    /// Which destination the forward goes through, or that none routes its
    /// host — in which case it can't be switched on. The table is the session's
    /// own, so this is known whether or not any server is connected.
    @ViewBuilder
    private var routeBadge: some View {
        if let routeTable {
            let destination = routeTable.destination(for: forward.remoteHost)
            Text(destination.map { "via \($0)" } ?? "no route")
                .accessibilityIdentifier("forward.route")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    (destination == nil ? Color.orange : Color.green).opacity(0.15), in: Capsule())
                .foregroundStyle(destination == nil ? .orange : .green)
        }
    }

    private var statusLine: some View {
        statusText.accessibilityIdentifier("forward.status")
    }

    @ViewBuilder
    private var statusText: some View {
        switch status.state {
        case .starting:
            Text("starting…")
                .font(.caption)
                .foregroundStyle(.orange)
        case .listening:
            VStack(alignment: .leading, spacing: 2) {
                Text(status.connectionCount > 0
                     ? "listening · \(status.connectionCount) active"
                     : "listening")
                    .foregroundStyle(.green)
                if let error = status.lastConnectionError {
                    Text(error).foregroundStyle(.orange)
                }
            }
            .font(.caption)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
        case .stopped:
            Text(forward.enabled ? "stopped" : "off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add/Edit sheet

/// Editable copy of a forward driving the sheet; `existingID` is nil for Add.
private struct ForwardDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var label = ""
    var localPortText = ""
    var remoteHost = ""
    var remotePortText = ""
    var enabled = true

    init() {}

    init(forward: PortForward) {
        existingID = forward.id
        label = forward.label
        localPortText = String(forward.localPort)
        remoteHost = forward.remoteHost
        remotePortText = String(forward.remotePort)
        enabled = forward.enabled
    }
}

private struct ForwardEditSheet: View {
    @State var draft: ForwardDraft
    let isLocalPortTaken: (UInt16) -> Bool
    /// The destination that routes a host, or nil when none does.
    let destination: (String) -> String?
    let onSave: (PortForward) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Local") {
                    TextField("Local port (e.g. 8080)", text: $draft.localPortText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("forward.localPort")
                        .onChange(of: draft.localPortText) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            if filtered != newValue { draft.localPortText = filtered }
                        }
                    if let localPort = parsedLocalPort, localPort < 1024 {
                        Text("Ports below 1024 usually can't be bound by apps.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    TextField("Host or IP (resolved by server)", text: $draft.remoteHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("forward.remoteHost")
                    TextField("Port (e.g. 22)", text: $draft.remotePortText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("forward.remotePort")
                        .onChange(of: draft.remotePortText) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            if filtered != newValue { draft.remotePortText = filtered }
                        }
                } header: {
                    Text("Remote target")
                } footer: {
                    Text(routeNote)
                }
                Section("Options") {
                    TextField("Label (optional)", text: $draft.label)
                    Toggle("Enabled", isOn: $draft.enabled)
                }
                if let message = validationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(draft.existingID == nil ? "Add Forward" : "Edit Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let forward = builtForward {
                            onSave(forward)
                            dismiss()
                        }
                    }
                    .disabled(builtForward == nil)
                    .accessibilityIdentifier("forward.save")
                }
            }
        }
    }

    private var parsedLocalPort: UInt16? { parsePort(draft.localPortText) }
    private var parsedRemotePort: UInt16? { parsePort(draft.remotePortText) }
    private var trimmedHost: String {
        draft.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parsePort(_ text: String) -> UInt16? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(value) else { return nil }
        return UInt16(value)
    }

    /// Where the typed host would go: a forward only works through a
    /// destination, so one that none routes is said up front.
    private var routeNote: String {
        guard !trimmedHost.isEmpty else {
            return "<name>.localhost.flextunnel.internal is that destination's server itself; "
                + "any other host must be on a destination's routes."
        }
        if let name = destination(trimmedHost) {
            let loopback = RouteTable.loopbackName(RouteTable.routingKey(trimmedHost.lowercased())) != nil
            return loopback
                ? "This reaches the port on \(name)'s server itself."
                : "Goes through \(name)."
        }
        return "No destination routes \(trimmedHost), so this forward can't be switched on "
            + "until one does."
    }

    /// Non-nil once every field validates; drives Save.
    private var builtForward: PortForward? {
        guard let localPort = parsedLocalPort,
              let remotePort = parsedRemotePort,
              !trimmedHost.isEmpty,
              !isLocalPortTaken(localPort) else { return nil }
        return PortForward(
            id: draft.existingID ?? UUID(),
            label: draft.label.trimmingCharacters(in: .whitespacesAndNewlines),
            localPort: localPort,
            remoteHost: trimmedHost,
            remotePort: remotePort,
            enabled: draft.enabled)
    }

    private var validationMessage: String? {
        if draft.localPortText.isEmpty && trimmedHost.isEmpty && draft.remotePortText.isEmpty {
            return nil // pristine form; no nagging
        }
        if !draft.localPortText.isEmpty && parsedLocalPort == nil {
            return "Local port must be 1–65535."
        }
        if let localPort = parsedLocalPort {
            if isLocalPortTaken(localPort) {
                return "Another forward already uses local port \(localPort)."
            }
        }
        if !draft.remotePortText.isEmpty && parsedRemotePort == nil {
            return "Remote port must be 1–65535."
        }
        return nil
    }
}

/// A caption-over-value status row — a trivial two-Text row, kept private here.
private struct InfoRow: View {
    let title: String
    let value: String
    let valueColor: Color?
    let monospace: Bool

    init(_ title: String, _ value: String, valueColor: Color? = nil, monospace: Bool = false) {
        self.title = title
        self.value = value
        self.valueColor = valueColor
        self.monospace = monospace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospace ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(valueColor ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
