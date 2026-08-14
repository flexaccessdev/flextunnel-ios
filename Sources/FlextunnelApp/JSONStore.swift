import Foundation

/// The app's small on-disk JSON stores — connection profiles and port-forward
/// definitions. Non-secret data only: secrets live in the Keychain
/// (`SecretStore`), which is the whole reason these files can be plain JSON.
///
/// Writes are atomic, happen off the main thread, carry a file-protection
/// class so nothing is readable before the first unlock, and the directory is
/// kept out of backups (this is device-local setup, not user documents).
enum JSONStore {
    /// Serial, so writes stay ordered: the callers persist on every keystroke
    /// in a settings field and on every forward toggle.
    private static let ioQueue = DispatchQueue(
        label: "dev.flexaccess.flextunnel.json-store-io", qos: .utility)

    /// An Application Support subdirectory. Not created here — `save` creates
    /// it on the way to the first write.
    static func directory(named name: String) -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(name, isDirectory: true)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Encode on the calling (main) actor — a deterministic snapshot of current
    /// state — then hand the bytes to the serial queue to write.
    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        ioQueue.async {
            var directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            try? data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
