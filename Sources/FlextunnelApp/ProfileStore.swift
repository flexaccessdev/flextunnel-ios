import Foundation
import Combine

/// The saved connection profiles — the desktop's profile list, narrowed to
/// what a phone needs. The point is convenience, not concurrency: a profile
/// remembers one server's setup so switching to another server doesn't mean
/// clearing and retyping the form. **One profile is selected at a time and
/// only the selected one connects** — iOS still runs a single session, unlike
/// the desktop where every profile can be up at once.
///
/// What a profile holds is non-secret (a name, a server node id, a reference
/// to a shared auth key, the relay URL list) and persists as one JSON document
/// in Application Support, the way port forwards do. The secrets stay where
/// they were:
///
/// - auth-key secrets in `AuthKeyStore`'s Keychain blob — **one shared list**,
///   as on the desktop, so several profiles can authenticate with the same
///   keypair; a profile only references one by id;
/// - each profile's relay auth token in the Keychain under its own account
///   (`SecretStore.relayTokenService`), written only once it has authenticated.
///
/// Port forwards are per-profile too, but they stay in `PortForwardController`
/// with their runtime state; it keys them by the same profile id.
@MainActor
final class ProfileStore: ObservableObject {
    /// One saved connection. Everything here is safe to write in plaintext.
    struct Profile: Identifiable, Codable, Equatable {
        let id: String
        var name: String
        var serverNodeID: String = ""
        /// Which key from the shared `AuthKeyStore` list authenticates this
        /// profile; empty when none is picked. A plain reference, not a secret.
        var authKeyID: String = ""
        /// The relay URLs as typed — comma-separated, split at connect time.
        var relayURLs: String = ""
    }

    /// A user-facing failure: the name rules, or the last-profile guard.
    struct ValidationError: Error {
        let message: String
    }

    /// The persisted shape: the list and the selection in one document, so a
    /// stored selection can never point at a profile that wasn't written.
    private struct Document: Codable {
        var selectedID: String
        var profiles: [Profile]
    }

    @Published private(set) var profiles: [Profile]

    /// The profile the setup form edits and the CTA connects. Never empty and
    /// always present in `profiles`: the list keeps at least one entry, so the
    /// form always has something to edit.
    ///
    /// Assigning persists — this is what the picker is bound to, and the
    /// mutating methods below rely on it rather than persisting twice.
    @Published var selectedID: String {
        didSet {
            guard selectedID != oldValue else { return }
            persist()
        }
    }

    private let fileURL: URL

    init(directory: URL? = nil) {
        fileURL = (directory ?? JSONStore.directory(named: "Profiles"))
            .appendingPathComponent("profiles.json")
        let document = JSONStore.load(Document.self, from: fileURL)
        var loaded = document?.profiles ?? []
        // First launch, or a file that decoded to nothing usable: seed the one
        // profile the form needs. Nothing is written until something is edited.
        if loaded.isEmpty {
            loaded = [Profile(id: UUID().uuidString, name: "Default")]
        }
        profiles = loaded
        let stored = document?.selectedID ?? ""
        selectedID = loaded.contains { $0.id == stored } ? stored : loaded[0].id
    }

    /// The selected profile. Settable so the setup form's fields can bind
    /// straight through (`$store.selected.serverNodeID`); each write persists.
    /// The name is deliberately not edited that way — `rename` validates it.
    var selected: Profile {
        get { profiles.first { $0.id == selectedID } ?? profiles[0] }
        set {
            guard let index = profiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            guard profiles[index] != newValue else { return }
            profiles[index] = newValue
            persist()
        }
    }

    func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Add a profile and select it — adding one is how you start setting one
    /// up, so there is no case where you'd want to stay on the old one.
    func add(name rawName: String) -> Result<Profile, ValidationError> {
        let name: String
        switch validated(name: rawName, excluding: nil) {
        case .success(let valid): name = valid
        case .failure(let error): return .failure(error)
        }
        let profile = Profile(id: UUID().uuidString, name: name)
        profiles.append(profile)
        // Persists both the append and the selection (see `selectedID`).
        selectedID = profile.id
        return .success(profile)
    }

    /// Rename `id`; returns a user-facing error when the new name is invalid.
    func rename(id: String, to newName: String) -> ValidationError? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        switch validated(name: newName, excluding: id) {
        case .success(let name):
            profiles[index].name = name
            persist()
            return nil
        case .failure(let error):
            return error
        }
    }

    /// Delete `id`, along with the relay token stored under its Keychain
    /// account. Deleting the selected profile moves the selection to a
    /// neighbour; deleting the last one is refused, because every screen here
    /// assumes there is a profile to show.
    func delete(id: String) -> ValidationError? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        guard profiles.count > 1 else {
            return .init(message: "This is the only profile. Rename it, or clear its "
                + "fields, instead of deleting it.")
        }
        profiles.remove(at: index)
        // Nothing else references that account, and the profile it belonged to
        // is gone — leaving it would strand a secret in the Keychain forever.
        SecretStore.clear(service: SecretStore.relayTokenService, account: id)
        if selectedID == id {
            // Persists the removal too (see `selectedID`).
            selectedID = profiles[min(index, profiles.count - 1)].id
        } else {
            persist()
        }
        return nil
    }

    /// Normalize (whitespace runs collapse to single spaces, ends trimmed) and
    /// validate a name, rejecting duplicates of any profile but `own`. Same
    /// rules as the desktop's profile form, and as `AuthKeyStore`'s key names.
    ///
    /// The desktop also refuses two profiles for one server node id. Not here:
    /// the server field is edited in place on the setup form rather than in a
    /// modal, so there is no save step to reject — and a duplicate costs
    /// nothing when only one profile connects at a time.
    private func validated(
        name raw: String, excluding own: String?
    ) -> Result<String, ValidationError> {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if name.isEmpty {
            return .failure(.init(message: "Profile name is required."))
        }
        if name.count > 64 {
            return .failure(.init(message: "Profile name must be 64 characters or fewer."))
        }
        if profiles.contains(where: { $0.name == name && $0.id != own }) {
            return .failure(.init(message: "Another profile is already named \"\(name)\"."))
        }
        return .success(name)
    }

    private func persist() {
        JSONStore.save(Document(selectedID: selectedID, profiles: profiles), to: fileURL)
    }
}
