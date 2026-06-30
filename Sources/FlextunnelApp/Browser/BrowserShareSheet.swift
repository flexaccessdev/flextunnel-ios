import SwiftUI
import UIKit

/// Wraps `UIActivityViewController` so the native share popout can carry custom
/// actions (like "Add Bookmark") alongside the system share targets — the same
/// pattern Safari uses for its bookmark action.
struct BrowserShareSheet: UIViewControllerRepresentable {
    let url: URL
    let activities: [UIActivity]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: activities)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A custom share-sheet action that bookmarks (or un-bookmarks) the shared page.
final class BookmarkActivity: UIActivity {
    enum Mode { case add, remove }

    private let mode: Mode
    private let action: () -> Void

    init(mode: Mode, action: @escaping () -> Void) {
        self.mode = mode
        self.action = action
    }

    override var activityTitle: String? {
        mode == .add ? "Add Bookmark" : "Remove Bookmark"
    }

    override var activityImage: UIImage? {
        UIImage(systemName: mode == .add ? "bookmark" : "bookmark.slash")
    }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.example.flextunnel.bookmark")
    }

    override class var activityCategory: UIActivity.Category { .action }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        action()
        activityDidFinish(true)
    }
}
