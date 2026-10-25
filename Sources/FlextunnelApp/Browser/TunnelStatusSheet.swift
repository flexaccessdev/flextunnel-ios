import SwiftUI
import UIKit

/// How the browser reaches a page's host: through the tunnel, or directly.
enum PageRoute {
    case tunnel
    case direct

    /// Whether `url`'s host goes through the tunnel under `routes`, or nil
    /// while no tunnel set is known (no handshake yet) or the URL has no host.
    /// `RouteMatch` follows the core's routed-set rules, but the core still
    /// makes the real call per connection; this only labels it.
    static func resolve(_ url: URL?, routes: ProxyController.ForwardedRoutes?) -> PageRoute? {
        guard let host = url?.host(), let routes, routes.isKnown else { return nil }
        let normalized = BrowserNavigationDecider.normalizedHost(host)
        return RouteMatch.isTunneled(host: normalized, routes: routes) ? .tunnel : .direct
    }
}

extension ProxyController {
    /// How the browser reaches `url` under the current tunnel set.
    func pageRoute(for url: URL?) -> PageRoute? {
        PageRoute.resolve(url, routes: forwardedRoutes)
    }
}

/// The browser's tunnel status: a health header that says what the split means
/// right now, the recovery actions, how the current page is routed, the tunnel
/// set the server pushed, and the session details. A sheet rather than a
/// popover so the routes and details have room; the page underneath is never
/// disturbed.
struct TunnelStatusSheet: View {
    @ObservedObject var proxy: ProxyController
    /// The browser's bound SOCKS port, shown when the controller no longer
    /// publishes one (the listener went away).
    let boundPort: UInt16
    /// The selected tab's page, for the "This page" row.
    let pageURL: URL?
    let onReconnect: () -> Void
    let onDisconnect: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingConnPath = false

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

                tunnelSetSections
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
            .sheet(isPresented: $showingConnPath) {
                ConnPathSheet(query: { proxy.queryConnPath() })
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
                .foregroundStyle(healthColor)
                .symbolEffect(.pulse, isActive: proxy.isReconnecting && !proxy.tunnelStuck)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(healthTitle)
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
        // While the link is down the core reconnects on its own, but Retry is
        // offered in case that reconnect is stuck — it relaunches the session.
        // Held off while a relaunch is still establishing, where a tap would
        // only restart it.
        if !proxy.tunnelConnected {
            Button(action: onReconnect) {
                Label(
                    proxy.isReconnecting ? "Retry Connection" : "Reconnect",
                    systemImage: "arrow.clockwise")
            }
            .disabled(!proxy.canRetry)
            .accessibilityIdentifier("tunnelStatus.retry")
        }
        // A one-shot readout of the live iroh path. Only offered while the link
        // is up (the snapshot is empty otherwise), mirroring the desktop CTA.
        if proxy.tunnelConnected {
            Button {
                showingConnPath = true
            } label: {
                Label("Connection Path", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .accessibilityIdentifier("tunnelStatus.connectionPath")
        }
        // Up here with the other actions, so it's reachable at the medium
        // detent rather than below the routes and details.
        Button(role: .destructive, action: onDisconnect) {
            Label("Disconnect", systemImage: "stop.circle")
                .foregroundStyle(.red)
        }
        .accessibilityIdentifier("tunnelStatus.disconnect")
    }

    private var healthTitle: String {
        if proxy.tunnelConnected { return "Connected" }
        if proxy.tunnelStuck { return "Disconnected" }
        if proxy.isReconnecting { return "Reconnecting…" }
        return "Stopped"
    }

    private var healthExplanation: String {
        let offList = proxy.isFullTunnel
            ? "Nothing loads until it's back, since all traffic goes through the tunnel."
            : "Sites outside the tunnel set keep loading directly; tunneled sites wait for it."
        if proxy.tunnelConnected {
            return proxy.isFullTunnel
                ? "All traffic goes through the server."
                : "Sites in the tunnel set go through the server; everything else connects directly."
        }
        if proxy.tunnelStuck {
            return "The tunnel hasn't reconnected on its own. Retry relaunches the session. " + offList
        }
        if proxy.isRelaunching {
            return "Restarting the tunnel session. " + offList
        }
        if proxy.sessionAlive {
            return "The link dropped and is reconnecting on its own. " + offList
        }
        return "The proxy isn't running, so tunneled sites can't load."
    }

    private var healthIcon: String {
        if proxy.tunnelConnected { return "bolt.horizontal.circle.fill" }
        return proxy.tunnelStuck ? "bolt.slash.circle" : "bolt.horizontal.circle"
    }

    private var healthColor: Color {
        if proxy.tunnelConnected { return .green }
        if proxy.tunnelStuck { return .red }
        if proxy.isReconnecting { return .orange }
        return .red
    }

    // MARK: - Tunnel set

    /// The tunnel set the server pushed: the domains/CIDRs routed through the
    /// tunnel (everything else browses directly), plus the server-side aliases,
    /// DNS forwards and bridges. Shown even while the link is down so the user
    /// can see which routes are temporarily unavailable.
    @ViewBuilder
    private var tunnelSetSections: some View {
        if let routes = proxy.forwardedRoutes, routes.isKnown {
            Section {
                if routes.isFullTunnel {
                    Text("All traffic (full tunnel)")
                } else if routes.isEmpty {
                    Text("Nothing but flextunnel.internal")
                        .accessibilityIdentifier("tunnelStatus.emptyTunnelSet")
                } else {
                    ForEach(routes.domains, id: \.self) { domain in
                        RouteRow(systemImage: "globe", text: domain)
                    }
                    ForEach(routes.cidrs, id: \.self) { cidr in
                        RouteRow(systemImage: "network", text: cidr)
                    }
                }
            } header: {
                Text("Tunnel set")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set by the server. Hosts not listed here connect directly.")
                    // A CIDR turns off WebKit's hostname scoping
                    // (`ForwardedRoutes.proxyMatchDomains`), so say what that
                    // costs: off-list sites then depend on the in-app listener.
                    // The system never proxies loopback or the device's own
                    // addresses, so those stay direct whatever the set says.
                    if !routes.isFullTunnel && !routes.cidrs.isEmpty {
                        Text("IP ranges cover IP-address URLs (like http://10.0.0.5) and port forwards, never hostnames. While the set has any, every page except loopback and this device's own addresses goes through the in-app proxy, which still sends hosts outside the set out directly.")
                            .accessibilityIdentifier("tunnelStatus.cidrNote")
                    }
                }
            }

            if !routes.hostAliases.isEmpty {
                Section("Host aliases") {
                    ForEach(routes.hostAliases, id: \.alias) { alias in
                        RouteRow(systemImage: "arrow.turn.down.right", text: "\(alias.alias) → \(alias.target)")
                    }
                }
            }

            if !routes.dnsForwards.isEmpty {
                Section {
                    ForEach(routes.dnsForwards, id: \.suffix) { forward in
                        RouteRow(
                            systemImage: "server.rack",
                            text: "\(forward.suffix) → \(forward.servers.joined(separator: ", "))")
                    }
                } header: {
                    Text("DNS forwards")
                } footer: {
                    Text("Each suffix covers its subdomains too, resolved on the server.")
                }
            }

            if !routes.bridges.isEmpty {
                Section("Bridge routes") {
                    ForEach(routes.bridges) { bridge in
                        Text(bridge.summary)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        } else {
            Section("Tunnel set") {
                Text("Not known yet — the server sends it when the tunnel connects.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section("Details") {
            if let summary = proxy.connectionSummary {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Server node id")
                    Text(summary.serverNodeID)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = summary.serverNodeID
                    } label: {
                        Label("Copy Node ID", systemImage: "doc.on.doc")
                    }
                }
                LabeledContent("Relays") {
                    Text(summary.relayURLs.isEmpty ? "iroh defaults" : summary.relayURLs.joined(separator: "\n"))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Peer discovery", value: "n0 discovery")
            }
            // Where the browser sends tunnel-set hosts. Off-list hosts never
            // touch it (WebKit's matchDomains split happens before any
            // connection), so while nothing is listening only tunnel-set hosts
            // fail.
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

/// "This page" row: the host and whether it goes through the tunnel.
struct PageRouteRow: View {
    let host: String
    let route: PageRoute

    var body: some View {
        LabeledContent {
            Label(route == .tunnel ? "Through the tunnel" : "Direct",
                  systemImage: route == .tunnel ? "bolt.horizontal.circle.fill" : "arrow.up.right.circle")
                .foregroundStyle(route == .tunnel ? .green : .secondary)
        } label: {
            Text(host)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityIdentifier("tunnelStatus.pageRoute")
    }
}

/// One tunnel-set entry: an icon and the monospaced pattern.
private struct RouteRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("tunnelStatus.route")
    }
}
