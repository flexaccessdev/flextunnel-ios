import SwiftUI

/// Flextunnel is a private-network access browser: it reaches private resources
/// through flextunnel servers — its destinations — split-tunnel by default
/// (traffic no destination routes bypasses the proxy) with the option to route
/// every site through one. It behaves like a mainstream browser plus
/// private-resource access — not a privacy/anonymity browser. Only what a
/// destination routes is tunneled, which is where its access protection applies.
@main
struct FlextunnelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
