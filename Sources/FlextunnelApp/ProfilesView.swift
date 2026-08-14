import SwiftUI

/// The profile list screen — the iOS mirror of the desktop's profile sidebar,
/// minus the concurrency: pick which saved connection the setup form edits and
/// the CTA connects, and add, rename or delete profiles. The settings
/// themselves are edited on the setup form, so there is no form here.
struct ProfilesView: View {
    @ObservedObject var store: ProfileStore

    @State private var showAddAlert = false
    @State private var renameTarget: ProfileStore.Profile?
    @State private var deleteTarget: ProfileStore.Profile?
    @State private var nameField = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(store.profiles) { profile in
                    row(profile)
                }
            } footer: {
                Text("The checked profile is the one the setup screen edits and "
                    + "the one that connects. Its server, auth key, relays and "
                    + "port forwards are remembered separately from the others'.")
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            Button {
                nameField = ""
                showAddAlert = true
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Add profile")
            }
        }
        .alert("Name the new profile", isPresented: $showAddAlert) {
            TextField("e.g. work", text: $nameField)
            Button("Add") { addProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It starts empty and becomes the selected profile, ready to "
                + "set up on the previous screen.")
        }
        .alert(
            "Rename profile",
            isPresented: presented($renameTarget),
            presenting: renameTarget
        ) { profile in
            TextField("Name", text: $nameField)
            Button("Rename") {
                if let error = store.rename(id: profile.id, to: nameField) {
                    errorMessage = error.message
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("")
        }
        .confirmationDialog(
            "Delete this profile?",
            isPresented: presented($deleteTarget),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { profile in
            Button("Delete \"\(profile.name)\"", role: .destructive) {
                if let error = store.delete(id: profile.id) {
                    errorMessage = error.message
                }
            }
        } message: { _ in
            Text("Its server, relays, port forwards and relay auth token are "
                + "removed from this device. Auth keys are shared between "
                + "profiles and are kept.")
        }
        .alert(
            "Can't do that",
            isPresented: presented($errorMessage),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func row(_ profile: ProfileStore.Profile) -> some View {
        let isSelected = profile.id == store.selectedID
        let subtitle = profile.serverNodeID.isEmpty ? "No server yet" : profile.serverNodeID
        return HStack(spacing: 12) {
            Button {
                store.selectedID = profile.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use profile \(profile.name)")

            Menu {
                Button {
                    nameField = profile.name
                    renameTarget = profile
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteTarget = profile
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("Actions for \(profile.name)")
            }
            .buttonStyle(.borderless)
        }
    }

    private func addProfile() {
        if case .failure(let error) = store.add(name: nameField) {
            errorMessage = error.message
        }
    }

    /// A presence binding for `.alert`/`.confirmationDialog(presenting:)`:
    /// true while the optional holds a value; dismissal clears it.
    private func presented<T>(_ target: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { target.wrappedValue != nil },
            set: { if !$0 { target.wrappedValue = nil } }
        )
    }
}
