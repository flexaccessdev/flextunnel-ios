import SwiftUI

/// A pending bookmark whose name/URL the user can edit before saving. Drives
/// `.sheet(item:)` presentation of `BookmarkEditView`.
struct BookmarkDraft: Identifiable {
    let id = UUID()
    var name: String
    var url: URL
}

/// Editable form shown before a bookmark is saved, prefilled with the page
/// title and URL. Save is disabled until both fields resolve to a usable value.
struct BookmarkEditView: View {
    let onSave: (_ name: String, _ url: URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlString: String

    init(draft: BookmarkDraft, onSave: @escaping (_ name: String, _ url: URL) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _urlString = State(initialValue: draft.url.absoluteString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section("URL") {
                    TextField("URL", text: $urlString)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Add Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guard let url = normalizedURL else { return }
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), url)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    /// Resolves the edited text to a navigable web URL, prepending `https://`
    /// when no scheme is present. Only http/https URLs with a non-empty host are
    /// accepted, so hostless input like `https://` is rejected.
    private var normalizedURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: URL?
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else { return nil }
            candidate = url
        } else {
            candidate = URL(string: "https://\(trimmed)")
        }

        guard let candidate, let host = candidate.host(), !host.isEmpty else { return nil }
        return candidate
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalizedURL != nil
    }
}
