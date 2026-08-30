import Foundation
import SwiftUI

/// What this build is, read from the bundle Info.plist: the app's own version
/// (MARKETING_VERSION / CURRENT_PROJECT_VERSION) and the flextunnel core it
/// links (FLEXTUNNEL_CORE_VERSION — the release pinned in
/// Packages/Flextunnel/Package.swift, kept in step by scripts/bump-xcframework.sh).
/// Shown at the bottom of every non-browser screen so a tester can tell which
/// build is on the phone, and which core it is talking to the server with,
/// without going through Settings.
enum AppVersion {
    /// "0.0.4 (4)" — marketing version with the build number, the format Apple
    /// uses in Settings. "unknown" only if the plist keys are missing, which
    /// would mean a broken bundle.
    static let app: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return short
        }
        return "\(short) (\(build))"
    }()

    /// The pinned libflextunnel release, e.g. "0.0.66". A local FFI build
    /// (FLEXTUNNEL_LOCAL_XCFRAMEWORK) still reports the pinned number — the
    /// locally built artifact carries no version of its own.
    static let core: String = {
        let value = Bundle.main.infoDictionary?["FlextunnelCoreVersion"] as? String
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }()

    /// The single line both numbers share.
    static var summary: String { "Version \(app) · core \(core)" }
}

/// Centered, quiet version line meant as the last row of a `Form`/`List`.
struct AppVersionFooter: View {
    var body: some View {
        Text(AppVersion.summary)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityLabel("App version \(AppVersion.app), flextunnel core \(AppVersion.core)")
    }
}
