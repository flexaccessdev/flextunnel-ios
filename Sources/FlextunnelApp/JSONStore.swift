import Foundation
import os

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

    /// A failed write is silent to the user — the setting is on screen, it just
    /// won't survive the next launch — so the log is the only way to tell that
    /// apart from a bug in the store. File names only: the container path
    /// carries an install-specific UUID and says nothing useful.
    private static let log = Logger(
        subsystem: "dev.flexaccess.flextunnel", category: "storage")

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
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            log.error("Encoding \(name, privacy: .public) failed: \(error, privacy: .public)")
            return
        }
        ioQueue.async {
            var directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            do {
                try data.write(
                    to: url,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                log.error("Writing \(name, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }
}
