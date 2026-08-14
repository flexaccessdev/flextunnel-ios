import Foundation
import Combine

/// Owns persisted forward definitions and reconciles them with the Rust core's
/// server-direct listener manager. Forward definitions persist; enablement is
/// per-session and is never encoded by `PortForward`.
///
/// Definitions are kept **per connection profile** (see `ProfileStore`): a
/// forward names a host behind one particular server, so it would mean nothing
/// under another profile. `forwards` is the selected profile's set; the rest
/// sit in the same file, keyed by profile id, waiting for that profile to be
/// picked again.
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
    /// Every profile's definitions, keyed by profile id. `forwards` is the
    /// live copy of `byProfile[profileID]`; `persist()` folds it back in.
    private var byProfile: [String: [PortForward]]
    private var profileID = ""
    /// A setup failure auto-disables only if the native listener never reached
    /// `.listening` during this start attempt.
    private var everListened: Set<UUID> = []
    /// Initial bind failures remain visible after the toggle is auto-disabled.
    private var retainedSetupErrors: [UUID: String] = [:]
    private let fileURL: URL

    init(directory: URL? = nil) {
        fileURL = (directory ?? JSONStore.directory(named: "PortForwards"))
            .appendingPathComponent("forwards.json")
        byProfile = JSONStore.load([String: [PortForward]].self, from: fileURL) ?? [:]
        // Empty until a profile is selected — `setProfile` fills it.
        forwards = []
    }

    // MARK: - Profiles

    /// Show `id`'s forwards. Profiles are only switched from the setup screen,
    /// with no session up, so there is normally nothing to reconcile — the
    /// per-session bookkeeping is reset and the set reapplied anyway, so that a
    /// session that somehow is alive gets this profile's forwards rather than
    /// keeping the previous profile's listeners.
    func setProfile(_ id: String) {
        guard id != profileID else { return }
        profileID = id
        forwards = byProfile[id] ?? []
        everListened.removeAll()
        retainedSetupErrors.removeAll()
        runtime = forwards.reduce(into: [:]) { $0[$1.id] = RuntimeStatus() }
        applyDesired()
    }

    /// Drop the forwards of profiles that no longer exist, so a deleted
    /// profile doesn't leave its definitions behind in the file forever.
    func pruneProfiles(keeping ids: Set<String>) {
        let stale = byProfile.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale {
            byProfile[id] = nil
        }
        persist()
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
        if let error = proxy.setPortForwards(forwards) {
            for forward in forwards where forward.enabled {
                runtime[forward.id] = RuntimeStatus(state: .failed(error))
            }
            return
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
        runtime = next
        if autoDisabled {
            persist()
            applyDesired()
        }
    }

    // MARK: - Persistence

    /// Fold the live set back into the per-profile map and write the lot. The
    /// selected profile is the only one that can have changed — except in
    /// `pruneProfiles`, which can run before a profile is selected and must
    /// not invent a bucket for the empty id.
    private func persist() {
        if !profileID.isEmpty {
            byProfile[profileID] = forwards
        }
        JSONStore.save(byProfile, to: fileURL)
    }
}
