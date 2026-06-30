import SwiftUI

/// Flextunnel is a VPN-like access browser: it reaches resources on a private
/// network through the flextunnel SOCKS5 tunnel, with the option to route all
/// traffic through it. It behaves like a mainstream browser plus private-resource
/// access — not a privacy/anonymity browser. Traffic to non-whitelisted resources
/// bypasses the proxy (split tunnel); only whitelisted private resources are
/// tunneled, which is where its access protection applies.
@main
struct FlextunnelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
