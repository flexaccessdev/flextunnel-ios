import SwiftUI
import UIKit
import QuickLook

/// A local file to preview, wrapped so it can drive `.sheet(item:)`.
struct PreviewItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// In-app QuickLook preview for a downloaded file, embedded in a navigation bar
/// so QuickLook shows its **Share** button (Save to Files / AirDrop) and we add
/// a **Done** button to dismiss. Presented bare, `QLPreviewController` has no
/// chrome — hence the wrapping nav controller.
struct FilePreviewView: UIViewControllerRepresentable {
    let url: URL
    var onDone: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onDone: onDone) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.done))
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let url: URL
        private let onDone: () -> Void

        init(url: URL, onDone: @escaping () -> Void) {
            self.url = url
            self.onDone = onDone
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        @objc func done() { onDone() }
    }
}
