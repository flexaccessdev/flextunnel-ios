import Foundation

/// A local TCP port forward: connections accepted on loopback are relayed to
/// `remoteHost:remotePort` over a QUIC stream to the destination that routes
/// `remoteHost`. A forward never connects directly.
///
/// A destination's own host name is that server's loopback: the server dials
/// its own localhost, whatever it routes, so such a target need not be in the
/// server's routed set. Any other target is an ordinary routed one, which the
/// server dials only if its own routed set allows it, and rejects otherwise.
struct PortForward: Identifiable, Codable, Equatable {
    let id: UUID
    /// Optional display name; empty shows the target instead.
    var label: String
    var localPort: UInt16
    /// Hostname or IP literal. Kept a string end-to-end: it picks the
    /// destination, and an ordinary routed hostname resolves on that server
    /// (a destination's own host name is not resolved at all — it means the
    /// server's loopback).
    var remoteHost: String
    var remotePort: UInt16
    /// Runtime-only by design: the start/stop toggle is per-session, so it is
    /// excluded from persistence (see `CodingKeys`) and every launch loads the
    /// forward switched off.
    var enabled: Bool = false

    /// Everything but `enabled` — what a forward *is* persists; whether it is
    /// running does not.
    private enum CodingKeys: String, CodingKey {
        case id, label, localPort, remoteHost, remotePort
    }

    init(
        id: UUID = UUID(),
        label: String = "",
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16,
        enabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.enabled = enabled
    }

    var displayName: String {
        label.isEmpty ? "\(remoteHost):\(remotePort)" : label
    }

    var routeDescription: String {
        "localhost:\(localPort) → \(remoteHost):\(remotePort)"
    }
}
