import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The key management screen — the iOS mirror of the desktop Keys pane: a
/// named list to pick the connection's identity from, with generate, import,
/// export, rename, and delete. Public halves show unmasked (they go on
/// servers' authorized-keys files); secrets never display — export copies
/// straight to the pasteboard, behind a confirmation.
struct KeysView: View {
    @ObservedObject var store: AuthKeyStore
    /// The picked key's id (`@AppStorage`-backed upstream); empty = none.
    @Binding var selectedKeyID: String

    @State private var showGenerateAlert = false
    @State private var showImportAlert = false
    @State private var renameTarget: AuthKeyStore.Key?
    @State private var exportTarget: AuthKeyStore.Key?
    @State private var deleteTarget: AuthKeyStore.Key?
    @State private var nameField = ""
    @State private var secretField = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            if store.keys.isEmpty {
                Text("No keys yet. Generate one (or paste an existing secret key), "
                    + "then put its public key on the server's authorized-keys file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(store.keys) { key in
                        row(key)
                    }
                } footer: {
                    Text("The checked key authenticates the connection. "
                        + "Its public key goes on the server's authorized-keys file.")
                }
            }
        }
        .navigationTitle("Auth Keys")
        .toolbar {
            Menu {
                Button {
                    nameField = ""
                    showGenerateAlert = true
                } label: {
                    Label("Generate New Key…", systemImage: "key")
                }
                Button {
                    nameField = ""
                    secretField = ""
                    showImportAlert = true
                } label: {
                    Label("Enter Existing Key…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Add key")
            }
        }
        .alert("Name the new key", isPresented: $showGenerateAlert) {
            TextField("e.g. this phone", text: $nameField)
            Button("Generate") { generateKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Names only exist in this app's key list.")
        }
        .alert("Enter existing key", isPresented: $showImportAlert) {
            TextField("Name (e.g. work laptop)", text: $nameField)
            SecureField("ed25519-sec:…", text: $secretField)
            Button("Add Key") { importKey() }
            Button("Cancel", role: .cancel) { secretField = "" }
        } message: {
            Text("Paste a secret key generated elsewhere — exported from the "
                + "desktop app, or by \"flexaccess-keys generate-auth-key\" — "
                + "to reuse its identity.")
        }
        .alert(
            "Rename key",
            isPresented: presented($renameTarget),
            presenting: renameTarget
        ) { key in
            TextField("Name", text: $nameField)
            Button("Rename") {
                if let error = store.rename(id: key.id, to: nameField) {
                    errorMessage = error.message
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("")
        }
        .confirmationDialog(
            "Copy the secret key?",
            isPresented: presented($exportTarget),
            titleVisibility: .visible,
            presenting: exportTarget
        ) { key in
            Button("Copy Secret Key") { copySecret(key.secret) }
        } message: { key in
            Text("Anyone holding the secret key can connect as \"\(key.name)\". "
                + "Paste it into another device's key import.")
        }
        .confirmationDialog(
            "Delete this key?",
            isPresented: presented($deleteTarget),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { key in
            Button("Delete \"\(key.name)\"", role: .destructive) {
                if let error = store.delete(id: key.id) {
                    errorMessage = error.message
                } else if selectedKeyID == key.id {
                    selectedKeyID = ""
                }
            }
        } message: { _ in
            Text("The secret key is removed from this device. The server keeps "
                + "trusting its public key until that's taken off the "
                + "authorized-keys file.")
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

    private func row(_ key: AuthKeyStore.Key) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedKeyID = key.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: key.id == selectedKeyID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(key.id == selectedKeyID ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name)
                            .foregroundStyle(.primary)
                        Text(key.publicKey)
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
            .accessibilityLabel("Use key \(key.name)")

            Menu {
                Button {
                    UIPasteboard.general.string = key.publicKey
                } label: {
                    Label("Copy Public Key", systemImage: "doc.on.doc")
                }
                Button {
                    exportTarget = key
                } label: {
                    Label("Export Secret Key…", systemImage: "square.and.arrow.up")
                }
                Button {
                    nameField = key.name
                    renameTarget = key
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteTarget = key
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("Actions for \(key.name)")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Copy a secret key with an expiry, so the most sensitive thing this app
    /// holds doesn't sit on the pasteboard (readable by every app that comes to
    /// the foreground) until something else replaces it. Left syncable on
    /// purpose: pasting into another device's key import is what export is for.
    private func copySecret(_ secret: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: [.expirationDate: Date().addingTimeInterval(secretPasteboardLifetime)])
    }

    /// Long enough to reach for the other device and paste, short enough that a
    /// forgotten copy doesn't linger.
    private var secretPasteboardLifetime: TimeInterval { 5 * 60 }

    private func generateKey() {
        guard let pair = AuthKey.generate() else {
            errorMessage = "Key generation failed."
            return
        }
        finishAdd(store.add(name: nameField, secret: pair.secretKey))
    }

    private func importKey() {
        let secret = secretField
        secretField = ""
        finishAdd(store.add(name: nameField, secret: secret))
    }

    private func finishAdd(_ result: Result<AuthKeyStore.Key, AuthKeyStore.ValidationError>) {
        switch result {
        case .success(let key):
            // Adopt the new key only when nothing was picked yet — adding a
            // key for another device must not silently switch this one's
            // identity.
            if selectedKeyID.isEmpty {
                selectedKeyID = key.id
            }
        case .failure(let error):
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
