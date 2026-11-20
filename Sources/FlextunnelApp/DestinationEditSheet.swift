import SwiftUI

/// Editable copy of a destination driving its sheet. The rule lists are edited
/// as text — one rule per line, or separated by commas or spaces.
struct DestinationDraft: Identifiable {
    /// The destination's id: the existing one's, or a fresh one for Add.
    let id: String
    let isNew: Bool
    var host = ""
    var serverNodeID = ""
    var routedDomains = ""
    var routedCIDRs = ""

    init() {
        id = UUID().uuidString
        isNew = true
    }

    init(destination: ClientStore.Destination) {
        id = destination.id
        isNew = false
        host = destination.host
        serverNodeID = destination.serverNodeID
        routedDomains = destination.routedDomains.joined(separator: "\n")
        routedCIDRs = destination.routedCIDRs.joined(separator: "\n")
    }

    /// The destination as typed; `ClientStore.validated` normalizes it.
    var destination: ClientStore.Destination {
        ClientStore.Destination(
            id: id,
            host: host,
            serverNodeID: serverNodeID,
            routedDomains: ClientStore.splitRules(routedDomains),
            routedCIDRs: ClientStore.splitRules(routedCIDRs))
    }

    /// Nothing typed yet, so there is nothing to complain about.
    var isPristine: Bool {
        host.isEmpty && serverNodeID.isEmpty && routedDomains.isEmpty && routedCIDRs.isEmpty
    }
}

/// Add or edit one destination: the host name a server goes by on this client,
/// the server's node id, and the further hosts routed through it.
struct DestinationEditSheet: View {
    @State var draft: DestinationDraft
    /// The store's check of the draft against its rules and the other
    /// destinations.
    let validate: (ClientStore.Destination) -> Result<ClientStore.Destination, ClientStore.ValidationError>
    let onSave: (ClientStore.Destination) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host name (e.g. office.internal)", text: $draft.host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("destination.host")
                    // One line: wrapped, the id would be hyphenated at the break.
                    TextField("Server node id", text: $draft.serverNodeID)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("destination.serverNodeID")
                } header: {
                    Text("Server")
                } footer: {
                    Text("The host name is yours to pick: with a port, it is that port "
                        + "on the server itself — the server's own localhost. It can't be "
                        + "an IP address or localhost.")
                }

                Section {
                    TextField("Domains (e.g. *.corp.example)", text: $draft.routedDomains, axis: .vertical)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...6)
                        .accessibilityIdentifier("destination.routedDomains")
                    TextField("IP ranges (e.g. 10.0.0.0/8)", text: $draft.routedCIDRs, axis: .vertical)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...6)
                        .accessibilityIdentifier("destination.routedCIDRs")
                } header: {
                    Text("Also send through it")
                } footer: {
                    Text("Optional. One rule per line. A domain is an exact name, "
                        + "*.suffix for its subdomains, or * for every name; an IP range "
                        + "covers IP-address targets only, never names. The server must "
                        + "route them too — its own list is what it allows. Anything on "
                        + "no destination's list connects directly from this device.")
                }

                if !draft.isNew {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete Destination", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(draft.isNew ? "Add Destination" : "Edit Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if case .success(let destination) = checked {
                            onSave(destination)
                            dismiss()
                        }
                    }
                    .disabled(problem != nil)
                    .accessibilityIdentifier("destination.save")
                }
            }
            // Pinned above the keyboard: in the form it would sit below the
            // fields, out of sight while one of them is being typed in.
            .safeAreaInset(edge: .bottom) {
                if let message = validationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.bar)
                        .accessibilityIdentifier("destination.error")
                }
            }
            .confirmationDialog(
                "Delete this destination?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete \(draft.host)", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            } message: {
                Text("Port forwards to hosts only it routes stop working until "
                    + "another destination routes them.")
            }
        }
    }

    private var checked: Result<ClientStore.Destination, ClientStore.ValidationError> {
        validate(draft.destination)
    }

    /// Why the draft can't be saved as it stands, or nil when it can.
    private var problem: String? {
        if case .failure(let error) = checked { return error.message }
        return nil
    }

    private var validationMessage: String? {
        draft.isPristine ? nil : problem
    }
}
