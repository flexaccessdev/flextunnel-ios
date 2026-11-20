import SwiftUI
import UIKit

extension ProxyController {
    /// How the browser reaches `url` under the session's routing table, or nil
    /// while no session is running or the URL has no host. `RouteTable` follows
    /// the core's rules, but the core still makes the real call per connection;
    /// this only labels it.
    func pageRoute(for url: URL?) -> Route? {
        guard let host = url?.host(), let routeTable else { return nil }
        return routeTable.route(host: BrowserNavigationDecider.normalizedHost(host))
    }
}

extension Route {
    /// How a page on this route is described: where its requests go.
    var label: String {
        switch self {
        case .destination(let host): return "Through \(host)"
        case .direct: return "Direct (no destination routes it)"
        case .status, .reserved: return "Answered by flextunnel in this app"
        }
    }

    var systemImage: String {
        switch self {
        case .destination: return "bolt.horizontal.circle.fill"
        case .direct: return "arrow.up.right.circle"
        case .status, .reserved: return "iphone"
        }
    }

    var isTunneled: Bool {
        if case .destination = self { return true }
        return false
    }
}

extension ProxyController.DestinationStatus {
    /// The state in a word or two, for a status row.
    var stateText: String {
        switch state {
        case .idle: return lastAttemptFailed ? "Last attempt failed" : "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .backoff: return "Retrying…"
        case .failed: return "Refused"
        }
    }

    var stateColor: Color {
        switch state {
        case .idle: return lastAttemptFailed ? .orange : .secondary
        case .connecting, .backoff: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }
}

extension ProxyController.Health {
    var color: Color {
        switch self {
        case .connected: return .green
        case .ready: return .accentColor
        case .connecting, .restarting, .trouble: return .orange
        case .stopped: return .red
        }
    }

    /// Something is in progress that will settle on its own.
    var isTransient: Bool {
        self == .connecting || self == .restarting
    }
}

/// The browser's session status: a health header that says what the split
/// means right now, the recovery actions, how the current page is routed, each
/// destination with its state and routes, and the session details. A sheet
/// rather than a popover so the destinations and details have room; the page
/// underneath is never disturbed.
struct TunnelStatusSheet: View {
    @ObservedObject var proxy: ProxyController
    /// The browser's bound SOCKS port, shown when the controller no longer
    /// publishes one (the listener went away).
    let boundPort: UInt16
    /// The selected tab's page, for the "This page" row.
    let pageURL: URL?
    let onRestart: () -> Void
    let onDisconnect: () -> Void
    /// Open a status page (the client's own, or a destination server's) in a
    /// new tab.
    let onOpenStatusPage: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The destination whose connection path is being shown.
    @State private var connPathHost: ConnPathTarget?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                    actions
                }

                if let host = pageURL?.host(), let route = proxy.pageRoute(for: pageURL) {
                    Section("This page") {
                        PageRouteRow(host: host, route: route)
                    }
                }

                destinationSections
                detailsSection

                if let error = proxy.lastError {
                    Section("Last error") {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .accessibilityIdentifier("tunnelStatus.sheet")
            .navigationTitle("Tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $connPathHost) { target in
                ConnPathSheet(host: target.host, query: { proxy.queryConnPath(host: target.host) })
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Health

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: healthIcon)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(proxy.health.color)
                .symbolEffect(.pulse, isActive: proxy.health.isTransient)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(proxy.health.title)
                    .font(.headline)
                    .accessibilityIdentifier("tunnelStatus.title")
                Text(healthExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actions: some View {
        // A destination that can't be reached retries on its own whenever it
        // is used; Restart is the way out when that isn't enough, or when the
        // session itself ended. Held off while a relaunch is in flight, where
        // a tap would only restart it.
        if proxy.health == .stopped || proxy.health == .trouble || proxy.health == .restarting {
            Button(action: onRestart) {
                Label("Restart Session", systemImage: "arrow.clockwise")
            }
            .disabled(!proxy.canRestart)
            .accessibilityIdentifier("tunnelStatus.restart")
        }
        if proxy.sessionAlive {
            Button {
                onOpenStatusPage(URL(string: "http://flextunnel.internal/")!)
            } label: {
                Label("Client Status Page", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("tunnelStatus.clientStatusPage")
        }
        // Up here with the other actions, so it's reachable at the medium
        // detent rather than below the destinations and details.
        Button(role: .destructive, action: onDisconnect) {
            Label("Disconnect", systemImage: "stop.circle")
                .foregroundStyle(.red)
        }
        .accessibilityIdentifier("tunnelStatus.disconnect")
    }

    private var healthExplanation: String {
        let split = proxy.routeTable?.catchAllDestination.map {
            "Every site goes through a destination — \($0) takes the ones no other claims."
        } ?? "Sites on a destination's routes go through its server; everything else connects directly."
        switch proxy.health {
        case .connected:
            return split
        case .ready:
            return "No server is connected yet — each connects when something is first sent to it. " + split
        case .connecting:
            return "Connecting to a server for the first request to it. " + split
        case .trouble:
            let hosts = proxy.troubledHosts.joined(separator: ", ")
            return "Can't reach \(hosts). Sites through it wait for a retry, then fail; "
                + "it is tried again whenever it is used."
        case .restarting:
            return "Restarting the session. Sites through a destination wait for it."
        case .stopped:
            return "The proxy isn't running, so sites through a destination can't load."
        }
    }

    private var healthIcon: String {
        switch proxy.health {
        case .connected: return "bolt.horizontal.circle.fill"
        case .ready, .connecting, .restarting: return "bolt.horizontal.circle"
        case .trouble, .stopped: return "bolt.slash.circle"
        }
    }

    // MARK: - Destinations

    /// Each destination: its state, what is routed through it, and the readouts
    /// that go with it. Routing is this client's configuration, so the routes
    /// are known whether or not the server has ever been connected.
    @ViewBuilder
    private var destinationSections: some View {
        ForEach(proxy.destinations) { destination in
            Section {
                DestinationStateRow(destination: destination)
                RouteRow(systemImage: "server.rack", text: destination.host, note: "with a port: the server itself")
                ForEach(destination.routedDomains, id: \.self) { domain in
                    RouteRow(systemImage: "globe", text: domain)
                }
                ForEach(destination.routedCIDRs, id: \.self) { cidr in
                    RouteRow(systemImage: "network", text: cidr)
                }
                // A one-shot readout of the live iroh path. Only offered while
                // this destination is connected (the snapshot is empty
                // otherwise), mirroring the desktop CTA.
                if destination.state == .connected {
                    Button {
                        connPathHost = ConnPathTarget(host: destination.host)
                    } label: {
                        Label("Connection Path", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .accessibilityIdentifier("tunnelStatus.connectionPath.\(destination.host)")
                }
                // The server's own view — its routed set, host aliases, DNS
                // forwards and bridges. Fetching it connects the destination.
                Button {
                    onOpenStatusPage(URL(string: "http://flextunnel.internal/servers/\(destination.host)/")!)
                } label: {
                    Label("Server Status Page", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("tunnelStatus.serverStatusPage.\(destination.host)")
            } header: {
                Text(destination.host)
                    .textCase(nil)
                    .font(.footnote.monospaced())
            } footer: {
                if destination.id == proxy.destinations.last?.id {
                    destinationsFooter
                }
            }
        }
    }

    /// Under the last destination: how destinations connect, and what the
    /// routes cost the browser's scoping.
    private var destinationsFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A destination connects when something is first sent to it, and disconnects after 5 minutes unused. Its server must route a host too — the server's own list is what it allows.")
            // A `*` rule or a network turns off WebKit's hostname scoping
            // (`RouteTable.proxyMatchDomains`), so say what that costs: sites
            // on no route then depend on the in-app proxy. The system never
            // proxies loopback or the device's own addresses, so those stay
            // direct whatever the routes say.
            if let table = proxy.routeTable, table.proxyMatchDomains == nil {
                // Verbatim: as a localized key, the address would render as a link.
                Text(verbatim: "IP ranges cover IP-address URLs (like http://10.0.0.5) and port forwards, never hostnames. With an IP range or * among the routes, every page except loopback and this device's own addresses goes through the in-app proxy, which still sends hosts on no route out directly.")
                    .accessibilityIdentifier("tunnelStatus.unscopedNote")
            }
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section("Details") {
            if proxy.routeTable != nil {
                LabeledContent("Relays") {
                    Text(proxy.relayURLs.isEmpty ? "iroh defaults" : proxy.relayURLs.joined(separator: "\n"))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Peer discovery", value: "n0 discovery")
            }
            // Where the browser sends routed hosts. Hosts on no route never
            // touch it while the routes are names only (WebKit's matchDomains
            // split happens before any connection), so while nothing is
            // listening only routed hosts fail.
            LabeledContent("SOCKS listener") {
                if proxy.sessionAlive {
                    Text(verbatim: "127.0.0.1:\(proxy.socksPort ?? boundPort)")
                        .monospacedDigit()
                } else {
                    Text("Not listening")
                        .foregroundStyle(.red)
                }
            }
            LabeledContent("Core status", value: proxy.status)
        }
    }
}

/// The destination a connection-path sheet is about.
struct ConnPathTarget: Identifiable {
    let host: String
    var id: String { host }
}

/// A destination's state: a colored word, and under it what the last failed
/// attempt said.
struct DestinationStateRow: View {
    let destination: ProxyController.DestinationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(destination.stateColor)
                    .frame(width: 8, height: 8)
                Text(destination.stateText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(destination.stateColor)
                    .accessibilityIdentifier("tunnelStatus.state.\(destination.host)")
            }
            if let error = destination.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "This page" row: the host and where its requests go.
struct PageRouteRow: View {
    let host: String
    let route: Route

    var body: some View {
        LabeledContent {
            Label(route.label, systemImage: route.systemImage)
                .foregroundStyle(route.isTunneled ? .green : .secondary)
        } label: {
            Text(host)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityIdentifier("tunnelStatus.pageRoute")
    }
}

/// One route of a destination: an icon, the monospaced pattern, and an
/// optional note on what it means.
private struct RouteRow: View {
    let systemImage: String
    let text: String
    var note: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("tunnelStatus.route")
    }
}
