import Foundation
import Combine

/// The shared, named client auth keys — the iOS mirror of the desktop app's
/// Keys pane. The whole list persists as one JSON blob in the Keychain entry
/// `SecretStore.authKeyService`: the names ride along with the secrets (they
/// aren't sensitive, but one storage home keeps the list atomic), and the
/// public halves are never stored — each is re-derived from its secret via
/// the FFI on load. Which key the connection uses is a plain reference kept
/// in `@AppStorage` upstream, like every other non-secret setting.
@MainActor
final class AuthKeyStore: ObservableObject {
    /// One named keypair. `publicKey` is derived, not persisted.
    struct Key: Identifiable, Equatable {
        let id: String
        var name: String
        var secret: String
        var publicKey: String
    }

    /// A user-facing validation failure (name rules, invalid or duplicate
    /// secret).
    struct ValidationError: Error {
        let message: String
    }

    /// The persisted shape: everything but the derived public half.
    private struct StoredKey: Codable {
        var id: String
        var name: String
        var secret: String
    }

    @Published private(set) var keys: [Key] = []

    init() {
        guard let json = SecretStore.load(service: SecretStore.authKeyService),
              let data = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode([StoredKey].self, from: data)
        else { return }
        // A record whose secret no longer derives a public key is corrupt —
        // drop it rather than carry an entry that can never connect.
        keys = stored.compactMap { record in
            AuthKey.publicKey(forSecret: record.secret).map {
                Key(id: record.id, name: record.name, secret: record.secret, publicKey: $0)
            }
        }
    }

    func key(id: String) -> Key? {
        keys.first { $0.id == id }
    }

    /// Validate and add a key. Mirrors the desktop rules: the name collapses
    /// to single-spaced words, is required, ≤64 characters, and unique; the
    /// secret must parse; the same keypair twice under two names is an
    /// accidental re-add, not a use case.
    func add(name rawName: String, secret: String) -> Result<Key, ValidationError> {
        let name: String
        switch validated(name: rawName, excluding: nil) {
        case .success(let valid): name = valid
        case .failure(let error): return .failure(error)
        }
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let publicKey = AuthKey.publicKey(forSecret: secret) else {
            return .failure(.init(message: "Not a valid secret key (expected flxtsecretv1:…)."))
        }
        if let other = keys.first(where: { $0.publicKey == publicKey }) {
            return .failure(.init(message: "Key \"\(other.name)\" already holds this secret."))
        }
        let key = Key(id: UUID().uuidString, name: name, secret: secret, publicKey: publicKey)
        keys.append(key)
        persist()
        return .success(key)
    }

    /// Rename `id`; returns a user-facing error when the new name is invalid.
    func rename(id: String, to newName: String) -> ValidationError? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return nil }
        switch validated(name: newName, excluding: id) {
        case .success(let name):
            keys[index].name = name
            persist()
            return nil
        case .failure(let error):
            return error
        }
    }

    func delete(id: String) {
        keys.removeAll { $0.id == id }
        persist()
    }

    /// Normalize (whitespace runs collapse to single spaces, ends trimmed)
    /// and validate a name, rejecting duplicates of any key but `own`.
    private func validated(
        name raw: String, excluding own: String?
    ) -> Result<String, ValidationError> {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if name.isEmpty {
            return .failure(.init(message: "Key name is required."))
        }
        if name.count > 64 {
            return .failure(.init(message: "Key name must be 64 characters or fewer."))
        }
        if keys.contains(where: { $0.name == name && $0.id != own }) {
            return .failure(.init(message: "Another key is already named \"\(name)\"."))
        }
        return .success(name)
    }

    private func persist() {
        let stored = keys.map { StoredKey(id: $0.id, name: $0.name, secret: $0.secret) }
        guard let data = try? JSONEncoder().encode(stored),
              let json = String(data: data, encoding: .utf8)
        else { return }
        SecretStore.save(json, service: SecretStore.authKeyService)
    }
}
