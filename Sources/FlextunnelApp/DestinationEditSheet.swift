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

/// Where the editor's "Fetch from Server" stands.
enum RoutesFetch: Equatable {
    case idle
    /// The server was asked; the id tells this request's answer from one to an
    /// earlier request, or for a server the draft has since been pointed away
    /// from.
    case fetching(UUID)
    /// The rule fields were filled from the server's answer; what to say.
    case filled(String)
    case failed(String)
}

/// Add or edit one destination: the host name a server goes by on this client,
/// the server's node id, and the further hosts routed through it.
struct DestinationEditSheet: View {
    @State var draft: DestinationDraft
    /// The client's key and relays, with which the draft's server can be asked
    /// what it routes; nil while no auth key is picked.
    let routesAccess: ServerRoutes.Access?
    /// The store's check of the draft against its rules and the other
    /// destinations.
    let validate: (ClientStore.Destination) -> Result<ClientStore.Destination, ClientStore.ValidationError>
    let onSave: (ClientStore.Destination) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var routesFetch = RoutesFetch.idle

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
                    Button {
                        fetchRoutes()
                    } label: {
                        HStack {
                            Label("Fetch from Server", systemImage: "arrow.down.circle")
                            Spacer()
                            if isFetchingRoutes { ProgressView() }
                        }
                    }
                    .disabled(routesBlocker != nil || isFetchingRoutes)
                    .accessibilityIdentifier("destination.fetchRoutes")
                    if let note = routesNote {
                        Text(note.text)
                            .font(.footnote)
                            .foregroundStyle(note.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .accessibilityIdentifier("destination.fetchRoutesNote")
                    }
                } header: {
                    Text("Also send through it")
                } footer: {
                    Text("Optional. One rule per line. A domain is an exact name, "
                        + "*.suffix for its subdomains, or * for every name; an IP range "
                        + "covers IP-address targets only, never names. The server must "
                        + "route them too — its own list is what it allows, and Fetch "
                        + "from Server replaces both fields with it. Anything on "
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
            // An answer on its way is for the server the id named.
            .onChange(of: draft.serverNodeID) { routesFetch = .idle }
            // And it would replace both rule fields — what is typed into one
            // while it is on its way included — so an edit calls it off. (The
            // fill itself lands after the fetch is over, and changes nothing
            // here.)
            .onChange(of: draft.routedDomains) { dropPendingRoutes() }
            .onChange(of: draft.routedCIDRs) { dropPendingRoutes() }
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

    // MARK: - Fetch from Server

    private var isFetchingRoutes: Bool {
        if case .fetching = routesFetch { return true }
        return false
    }

    /// What is still missing before the server can be asked, or nil.
    private var routesBlocker: String? {
        if ClientStore.nodeKey(draft.serverNodeID) == nil {
            return "Enter the server node id to fetch the server's own list."
        }
        if routesAccess == nil {
            return "Pick an auth key on the setup screen to fetch the server's own list."
        }
        return nil
    }

    /// The line under the button: the outcome of the last fetch, or what it
    /// is waiting for.
    private var routesNote: (text: String, isProblem: Bool)? {
        switch routesFetch {
        case .fetching: return (text: "Asking the server…", isProblem: false)
        case .filled(let note): return (text: note, isProblem: false)
        case .failed(let reason): return (text: reason, isProblem: true)
        case .idle: return routesBlocker.map { (text: $0, isProblem: false) }
        }
    }

    /// A rule field changed: the answer to a fetch in flight is no longer
    /// waited for.
    private func dropPendingRoutes() {
        if isFetchingRoutes { routesFetch = .idle }
    }

    /// Ask the draft's server what it routes and put its lists in the two rule
    /// fields, replacing what they held; a failure leaves them alone. Nothing
    /// is saved — that stays with Save. The editor stays usable meanwhile, and
    /// an answer that is no longer waited for is dropped.
    private func fetchRoutes() {
        guard let access = routesAccess, routesBlocker == nil, !isFetchingRoutes else { return }
        let request = UUID()
        let node = draft.serverNodeID
        routesFetch = .fetching(request)
        Task {
            let result = await ServerRoutes.fetch(serverNodeID: node, access: access)
            guard routesFetch == .fetching(request) else { return }
            switch result {
            case .success(let routes):
                if let odd = routes.entryThatIsNotOneRule {
                    routesFetch = .failed(
                        "The server lists \"\(odd)\", which these fields cannot hold as one "
                            + "rule. Nothing was filled in.")
                    return
                }
                // The outcome first: the fields' change handlers then find
                // no fetch to call off.
                routesFetch = .filled(routes.filledNote)
                draft.routedDomains = routes.domains.joined(separator: "\n")
                draft.routedCIDRs = routes.cidrs.joined(separator: "\n")
            case .failure(let failure):
                // The core's word for a key the server does not know.
                let refused = failure.message.hasPrefix("Authentication failed")
                routesFetch = .failed(refused
                    ? "The server refused this device's key. Put its public key on the "
                        + "server's authorized-keys file first."
                    : failure.message)
            }
        }
    }
}
