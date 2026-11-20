import Foundation
import Combine

/// Owns persisted forward definitions and reconciles them with the Rust core's
/// server-direct listener manager. Forward definitions persist; enablement is
/// per-session and is never encoded by `PortForward`.
///
/// There is one list for the client. A forward names a host, and the session's
/// routing table picks the destination that reaches it — so a forward to a
/// host no destination routes can't be switched on.
@MainActor
final class PortForwardController: ObservableObject {
    struct RuntimeStatus: Equatable {
        var state: PortForwardState = .stopped
        var connectionCount: Int = 0
        var lastConnectionError: String?
    }

    @Published private(set) var forwards: [PortForward]
    @Published private(set) var runtime: [UUID: RuntimeStatus] = [:]

    /// Any forward is carrying traffic right now. The keep-alive treats that as
    /// activity, so a session in active use is never dropped by its inactivity
    /// limit just because the device is sitting still.
    var hasOpenConnections: Bool {
        runtime.values.contains { $0.connectionCount > 0 }
    }

    private weak var proxy: ProxyController?
    private var sessionID: UUID?
    /// A setup failure auto-disables only if the native listener never reached
    /// `.listening` during this start attempt.
    private var everListened: Set<UUID> = []
    /// Initial bind failures remain visible after the toggle is auto-disabled.
    private var retainedSetupErrors: [UUID: String] = [:]
    private let fileURL: URL

    init(directory: URL? = nil) {
        fileURL = (directory ?? JSONStore.directory(named: "PortForwards"))
            .appendingPathComponent("forwards.json")
        forwards = JSONStore.load([PortForward].self, from: fileURL) ?? []
        runtime = forwards.reduce(into: [:]) { $0[$1.id] = RuntimeStatus() }
    }

    // MARK: - Tunnel lifecycle

    /// Attach to the current native session. A replacement session gets the
    /// complete desired set immediately; a stopped session clears runtime state.
    func syncProxy(_ proxy: ProxyController) {
        let newID = proxy.forwardingSessionID
        if newID == sessionID {
            refreshRuntime()
            return
        }
        sessionID = newID
        self.proxy = newID == nil ? nil : proxy
        everListened.removeAll()
        retainedSetupErrors.removeAll()
        runtime = forwards.reduce(into: [:]) { $0[$1.id] = RuntimeStatus() }
        if newID != nil {
            applyDesired()
            refreshRuntime()
        }
    }

    /// A relaunched native session owns fresh sockets. Reapply the complete set;
    /// this is also harmless if the session replacement notification already did.
    func rebindAfterSuspension() {
        guard sessionID != nil else { return }
        applyDesired()
        refreshRuntime()
    }

    // MARK: - CRUD

    func add(_ forward: PortForward) {
        forwards.append(forward)
        persist()
        everListened.remove(forward.id)
        retainedSetupErrors[forward.id] = nil
        applyDesired()
    }

    func update(_ forward: PortForward) {
        guard let index = forwards.firstIndex(where: { $0.id == forward.id }) else { return }
        forwards[index] = forward
        persist()
        everListened.remove(forward.id)
        retainedSetupErrors[forward.id] = nil
        runtime[forward.id] = RuntimeStatus()
        applyDesired()
    }

    func remove(atOffsets offsets: IndexSet) {
        let ids = offsets.map { forwards[$0].id }
        forwards.remove(atOffsets: offsets)
        for id in ids {
            everListened.remove(id)
            retainedSetupErrors[id] = nil
            runtime[id] = nil
        }
        persist()
        applyDesired()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        forwards[index].enabled = enabled
        everListened.remove(id)
        retainedSetupErrors[id] = nil
        runtime[id] = RuntimeStatus()
        persist()
        applyDesired()
    }

    func isLocalPortTaken(_ port: UInt16, excluding id: UUID?) -> Bool {
        forwards.contains { $0.localPort == port && $0.id != id }
    }

    func disableAll() {
        var changed = false
        for index in forwards.indices where forwards[index].enabled {
            forwards[index].enabled = false
            changed = true
        }
        guard changed else { return }
        everListened.removeAll()
        retainedSetupErrors.removeAll()
        runtime = forwards.reduce(into: [:]) { $0[$1.id] = RuntimeStatus() }
        persist()
        applyDesired()
    }

    // MARK: - Native manager

    private func applyDesired() {
        guard let proxy, proxy.sessionAlive, sessionID != nil else { return }
        // The core takes the set as a whole and refuses all of it if one
        // enabled forward names a host no destination routes. Switch those off
        // here, each with its own reason, so the rest still apply.
        if let table = proxy.routeTable {
            for index in forwards.indices where forwards[index].enabled {
                let forward = forwards[index]
                guard table.destination(for: forward.remoteHost) == nil else { continue }
                forwards[index].enabled = false
                retainedSetupErrors[forward.id] = "no destination routes \(forward.remoteHost)"
            }
        }
        if proxy.setPortForwards(forwards) != nil {
            // The core takes the set whole, and a set it refuses changes
            // nothing there: every listener it had stays up, including one
            // that was just switched off here. So find what it objects to —
            // start from nothing listening, offer the enabled forwards one
            // more at a time, and switch off each it refuses with its reason —
            // which leaves the core listening on exactly what reads as on.
            var offered = forwards
            for index in offered.indices { offered[index].enabled = false }
            if let error = proxy.setPortForwards(offered) {
                // Not about any one forward: the session isn't taking sets.
                for forward in forwards where forward.enabled {
                    runtime[forward.id] = RuntimeStatus(state: .failed(error))
                }
                return
            }
            for index in forwards.indices where forwards[index].enabled {
                offered[index].enabled = true
                if let reason = proxy.setPortForwards(offered) {
                    offered[index].enabled = false
                    forwards[index].enabled = false
                    retainedSetupErrors[forwards[index].id] = reason
                }
            }
        }
        refreshRuntime()
    }

    func refreshRuntime() {
        guard let proxy, proxy.sessionAlive, sessionID != nil,
              let statuses = proxy.portForwardStatuses() else { return }

        var next = forwards.reduce(into: [UUID: RuntimeStatus]()) { result, forward in
            if let error = retainedSetupErrors[forward.id] {
                result[forward.id] = RuntimeStatus(state: .failed(error))
            } else {
                result[forward.id] = RuntimeStatus()
            }
        }
        var autoDisabled = false
        for forward in forwards where forward.enabled {
            guard let status = statuses[forward.id] else {
                next[forward.id] = RuntimeStatus(state: .starting)
                continue
            }
            if case .listening = status.state {
                everListened.insert(forward.id)
            }
            if case .failed = status.state, !everListened.contains(forward.id) {
                if let index = forwards.firstIndex(where: { $0.id == forward.id }) {
                    forwards[index].enabled = false
                    autoDisabled = true
                }
                if case .failed(let error) = status.state {
                    retainedSetupErrors[forward.id] = error
                }
            }
            next[forward.id] = RuntimeStatus(
                state: status.state,
                connectionCount: status.active,
                lastConnectionError: status.lastConnectionError)
        }
        // Polled every second: an unchanged write would still re-render every
        // view observing this controller.
        if runtime != next { runtime = next }
        if autoDisabled {
            persist()
            applyDesired()
        }
    }

    // MARK: - Persistence

    private func persist() {
        JSONStore.save(forwards, to: fileURL)
    }
}
