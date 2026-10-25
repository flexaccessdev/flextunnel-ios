import SwiftUI

/// The Library's Downloads segment: this session's downloads with live
/// progress, completion state, and tap-to-open via QuickLook. Rows swipe to
/// delete (cancelling one still in flight) and finished files share.
struct DownloadsList: View {
    let downloads: BrowserDownloadManager
    /// Lowercased search text from the Library; empty shows everything.
    let query: String
    @State private var preview: PreviewItem?

    var body: some View {
        let items = downloads.items.filter { query.isEmpty || $0.filename.lowercased().contains(query) }
        Group {
            if downloads.items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Files you download appear here for this session."))
            } else if items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(items) { item in
                        row(item)
                            .swipeActions {
                                if case .downloading = item.state {
                                    Button(role: .destructive) {
                                        downloads.remove(item)
                                    } label: {
                                        Label("Cancel", systemImage: "xmark")
                                    }
                                } else {
                                    Button(role: .destructive) {
                                        downloads.remove(item)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .contextMenu {
                                if case .finished(let url) = item.state {
                                    ShareLink(item: url) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                }
                                Button(role: .destructive) {
                                    downloads.remove(item)
                                } label: {
                                    if case .downloading = item.state {
                                        Label("Cancel Download", systemImage: "xmark")
                                    } else {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $preview) { item in
            FilePreviewView(url: item.url, onDone: { preview = nil })
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func row(_ item: DownloadItem) -> some View {
        let content = HStack(spacing: 12) {
            Image(systemName: downloadFileIcon(item.filename))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.body)
                    .lineLimit(1)
                subtitle(item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .finished = item.state {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())

        if case .finished(let url) = item.state {
            Button { preview = PreviewItem(url: url) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder
    private func subtitle(_ item: DownloadItem) -> some View {
        switch item.state {
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = item.fractionComplete {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text(Self.progressText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished(let url):
            HStack(spacing: 6) {
                Text(Self.fileSize(at: url))
                if let host = item.sourceURL.host() {
                    Text("·")
                    Text(host).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    // MARK: - Formatting

    private static func progressText(_ item: DownloadItem) -> String {
        let written = ByteCountFormatter.string(fromByteCount: item.bytesWritten, countStyle: .file)
        if item.totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
            return "\(written) of \(total)"
        }
        return written
    }

    private static func fileSize(at url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        return ByteCountFormatter.string(fromByteCount: size ?? 0, countStyle: .file)
    }

}

/// Firefox-style download confirmation card: the file (icon, name, size · host)
/// with Cancel / Download actions, shown as a compact bottom sheet.
struct DownloadPromptView: View {
    let prompt: DownloadPrompt
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: downloadFileIcon(prompt.filename))
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.filename)
                        .font(.headline)
                        .lineLimit(2)
                    Text(prompt.detailText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Button(role: .cancel, action: onCancel) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// SF Symbol for a downloaded file, chosen by extension.
func downloadFileIcon(_ filename: String) -> String {
    switch (filename as NSString).pathExtension.lowercased() {
    case "pdf": return "doc.richtext"
    case "zip", "gz", "tar", "7z", "rar": return "doc.zipper"
    case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff": return "photo"
    case "mp4", "mov", "m4v", "avi", "mkv", "webm": return "film"
    case "mp3", "wav", "aac", "m4a", "flac", "ogg": return "music.note"
    case "txt", "md", "rtf", "csv", "json", "xml", "log": return "doc.text"
    case "dmg", "pkg", "app": return "shippingbox"
    default: return "doc"
    }
}
