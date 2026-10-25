import SwiftUI
import UIKit

/// Firefox-style Library sheet: bookmarks, browsing history and this session's
/// downloads in one place, picked with a segmented control. Every segment is
/// searchable; history is grouped by day; rows offer the usual browser context
/// actions (open in a new tab, copy link, edit, delete) and swipe to delete.
struct LibraryView: View {
    enum Section: Hashable {
        case bookmarks, history, downloads
    }

    @Bindable var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section
    @State private var query = ""
    @State private var editing: Bookmark?
    @State private var confirmingClearHistory = false

    init(model: BrowserModel, section: Section = .bookmarks) {
        self.model = model
        _section = State(initialValue: section)
    }

    private var library: BrowserLibrary { model.library }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    Text("Bookmarks").tag(Section.bookmarks)
                    Text("History").tag(Section.history)
                    Text("Downloads").tag(Section.downloads)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("library.section")

                Group {
                    switch section {
                    case .bookmarks: bookmarksList
                    case .history: historyList
                    case .downloads: DownloadsList(downloads: model.downloads, query: trimmedQuery)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                if section == .history && !library.history.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear History…", role: .destructive) { confirmingClearHistory = true }
                    }
                }
                if section == .downloads && !model.downloads.items.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear All", role: .destructive) { model.downloads.clearAll() }
                    }
                }
            }
            .confirmationDialog("Clear History", isPresented: $confirmingClearHistory, titleVisibility: .visible) {
                Button("Last Hour", role: .destructive) {
                    library.clearHistory(since: Date().addingTimeInterval(-3600))
                }
                Button("Today", role: .destructive) {
                    library.clearHistory(since: Calendar.current.startOfDay(for: Date()))
                }
                Button("All History", role: .destructive) { library.clearHistory() }
            } message: {
                Text("Cookies and site data are kept.")
            }
            .sheet(item: $editing) { bookmark in
                BookmarkEditView(
                    draft: BookmarkDraft(name: bookmark.name, url: bookmark.url),
                    title: "Edit Bookmark",
                    isTaken: { $0 != bookmark.url && library.isBookmarked($0) }
                ) { name, url in
                    library.updateBookmark(bookmark, name: name, url: url)
                }
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var searchPrompt: String {
        switch section {
        case .bookmarks: return "Search Bookmarks"
        case .history: return "Search History"
        case .downloads: return "Search Downloads"
        }
    }

    private func matches(title: String, url: URL) -> Bool {
        let query = trimmedQuery
        guard !query.isEmpty else { return true }
        return title.lowercased().contains(query) || url.absoluteString.lowercased().contains(query)
    }

    // MARK: - Bookmarks

    @ViewBuilder
    private var bookmarksList: some View {
        let bookmarks = library.bookmarks.filter { matches(title: $0.name, url: $0.url) }
        if library.bookmarks.isEmpty {
            ContentUnavailableView(
                "No Bookmarks",
                systemImage: "bookmark",
                description: Text("Choose Add Bookmark from the \u{22EF} menu to save a page."))
        } else if bookmarks.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(bookmarks) { bookmark in
                    Button { open(bookmark.url) } label: {
                        LibraryRow(systemImage: "bookmark", title: bookmark.name, url: bookmark.url, detail: nil)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        openActions(for: bookmark.url)
                        Button {
                            editing = bookmark
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            library.removeBookmark(bookmark)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            library.removeBookmark(bookmark)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editing = bookmark
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historyList: some View {
        let groups = HistoryGroup.grouping(library.history.filter { matches(title: $0.title, url: $0.url) })
        if library.history.isEmpty {
            ContentUnavailableView(
                "No History",
                systemImage: "clock",
                description: Text("Pages you visit will appear here."))
        } else if groups.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(groups) { group in
                    SwiftUI.Section(group.title) {
                        ForEach(group.entries) { entry in
                            Button { open(entry.url) } label: {
                                LibraryRow(
                                    systemImage: "clock",
                                    title: entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title,
                                    url: entry.url,
                                    detail: entry.lastVisited.formatted(date: .omitted, time: .shortened))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                openActions(for: entry.url)
                                Button(role: .destructive) {
                                    library.removeHistory(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    library.removeHistory(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private func openActions(for url: URL) -> some View {
        Button {
            open(url, inNewTab: true)
        } label: {
            Label("Open in New Tab", systemImage: "plus.square.on.square")
        }
        Button {
            UIPasteboard.general.url = url
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }
    }

    /// Dismiss first, then navigate on the next runloop turn. Loading swaps the
    /// tab out of its home state, which re-evaluates the browser body that owns
    /// this sheet's `isPresented` state — doing that in the same transaction as
    /// the dismissal loses it, leaving the library covering the page it opened.
    private func open(_ url: URL, inNewTab: Bool = false) {
        dismiss()
        DispatchQueue.main.async {
            if inNewTab { model.addTab() }
            model.navigate(url.absoluteString)
        }
    }
}

/// History entries bucketed by how long ago they were visited, newest first.
struct HistoryGroup: Identifiable {
    let title: String
    let entries: [HistoryEntry]
    var id: String { title }

    /// Splits newest-first `entries` into Today / Yesterday / Last 7 Days /
    /// Older, dropping empty buckets. Order within a bucket is preserved.
    static func grouping(_ entries: [HistoryEntry], now: Date = Date()) -> [HistoryGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: today) ?? today

        var buckets: [(String, [HistoryEntry])] = [
            ("Today", []), ("Yesterday", []), ("Last 7 Days", []), ("Older", []),
        ]
        for entry in entries {
            let index: Int
            switch entry.lastVisited {
            case today...: index = 0
            case yesterday...: index = 1
            case lastWeek...: index = 2
            default: index = 3
            }
            buckets[index].1.append(entry)
        }
        return buckets.filter { !$0.1.isEmpty }.map { HistoryGroup(title: $0.0, entries: $0.1) }
    }
}

/// One bookmark or history row: an icon, the title, and the compact
/// `host/path` plus an optional detail (the visit time).
private struct LibraryRow: View {
    let systemImage: String
    let title: String
    let url: URL
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.displayURL(url))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail {
                        Text("·")
                        Text(detail)
                            .fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Scheme-less `host/path`, the way browsers label a page in their library.
    private static func displayURL(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path
        return path.isEmpty || path == "/" ? host + port : host + port + path
    }
}
