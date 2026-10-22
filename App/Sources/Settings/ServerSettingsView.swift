import SwiftUI
import PleviDomain
import PleviTransport
import PleviLibraryIndex

/// Everything about the servers themselves: which one is in use, whether it
/// answers, and what the library sync found. Kept behind its own page so the
/// settings you actually adjust are not buried under connection detail.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showAddServer = false
    @State private var showAddPlex = false
    @State private var serverPendingRemoval: ServerConfig?
    @State private var serverBeingEdited: ServerConfig?
    /// The Plex server whose libraries are being listed.
    @State private var switchingLibraryOn: ServerConfig?
    @State private var indexStats: LibraryIndex.Stats?
    /// Presented here rather than handed to the root, so signing in from a
    /// failed row leaves you looking at that row as it turns green.
    @State private var proxySignIn: AppModel.ProxySignInRequest?

    /// The active server, when it is a Plex one — only Plex has more than a
    /// single library to choose between.
    private var activePlexServer: ServerConfig? {
        guard let id = app.servers.activeServerID else { return nil }
        return app.servers.servers.first { $0.id == id && $0.kind == .plex }
    }

    var body: some View {
        List {
            Section("Connection") {
                connectionRow
                Button("Test connection") {
                    Task {
                        await app.connectActive()
                        await app.testAllEndpoints()
                    }
                }
                ForEach(app.endpointChecks) { check in
                    endpointCheckRow(check, onServersOwnNetwork: onServersOwnNetwork)
                }
                // Always a way back in when a proxy session lapses.
                if let request = app.proxySignInOption {
                    Button("Sign in to \(request.url.host() ?? "proxy")…") {
                        proxySignIn = request
                    }
                }
            }

            Section("Servers") {
                ForEach(app.servers.servers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .foregroundStyle(.primary)
                            // Named for what each address is, not for the slot it sits in — see
                            // `ServerAddressKind` — except where that would name them both the same
                            // thing.
                            let names = Self.addressNames(server.addresses)
                            if let local = server.addresses.local {
                                Text("\(names.local): \(Redactor.redacted(local))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let remote = server.addresses.remote {
                                Text("\(names.remote): \(Redactor.redacted(remote))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if server.id == app.servers.activeServerID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Active server")
                        }
                        Button {
                            serverBeingEdited = server
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.tint)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(server.name)")
                    }
                    // Deliberately not a Button: a control inside a
                    // button's label never receives its own taps.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        app.servers.setActive(server.id)
                        Task { await app.connectActive() }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            serverPendingRemoval = server
                        }
                        Button("Edit") {
                            serverBeingEdited = server
                        }
                    }
                    // On the row it belongs to, so the question comes up from
                    // the server being removed.
                    .confirmationDialog(
                        "Remove \(serverPendingRemoval?.name ?? "server")?",
                        isPresented: Binding(
                            get: { serverPendingRemoval?.id == server.id },
                            set: { if !$0, serverPendingRemoval?.id == server.id { serverPendingRemoval = nil } }
                        ),
                        titleVisibility: .visible
                    ) {
                        Button("Remove server and its credentials", role: .destructive) {
                            if let server = serverPendingRemoval {
                                // Before the store forgets it: the watch is told by id,
                                // and afterwards there is nothing left to name.
                                app.forgetServerOnWatch(server.id)
                                // Its libraries' files too, while the configuration that
                                // names them can still be read.
                                app.forgetLibraries(of: server.id)
                                app.servers.remove(server.id)
                                serverPendingRemoval = nil
                                Task { await app.connectActive() }
                            }
                        }
                    } message: {
                        Text("Its credentials are deleted from the Keychain, and its downloaded music, library data and caches are deleted from this phone.")
                    }
                }
                Menu {
                    Button("Navidrome or Subsonic") { showAddServer = true }
                    Button("Plex") { showAddPlex = true }
                } label: {
                    Label("Add server", systemImage: "plus")
                }
            }

            if let plex = activePlexServer {
                Section("Music Library") {
                    LabeledContent("Current", value: plex.library?.title ?? "Not set")
                    Button("Switch library…") { switchingLibraryOn = plex }
                    NavigationLink("Quick switch on Home") {
                        QuickSwitchSettingsView(server: plex)
                    }
                }
            }

            Section("Library") {
                syncRow
                if let stats = indexStats {
                    LabeledContent("Artists", value: stats.artistCount.formatted())
                    LabeledContent("Albums", value: stats.albumCount.formatted())
                    LabeledContent("Songs", value: stats.trackCount.formatted())
                    if let lastSync = stats.lastSyncAt {
                        LabeledContent(
                            "Last synced",
                            value: lastSync.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
                Button(isSyncing ? "Restart sync" : "Sync library now") {
                    app.startBackgroundSync(force: true)
                }
                .disabled(app.provider == nil)
            }

            if case .connected(let info) = app.connection {
                Section("Server details") {
                    LabeledContent("Product", value: info.productName ?? "Unknown")
                    LabeledContent("Version", value: info.productVersion ?? "—")
                    LabeledContent("API", value: info.apiVersion ?? "—")
                    LabeledContent("OpenSubsonic", value: info.isOpenSubsonic ? "Yes" : "No")
                    if !info.extensions.isEmpty {
                        LabeledContent("Extensions", value: info.extensions.sorted().joined(separator: ", "))
                    }
                }
            }
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: statsKey) {
            indexStats = try? app.libraryIndex?.stats()
        }
        .sheet(isPresented: $showAddServer) {
            ServerSetupView()
        }
        .sheet(isPresented: $showAddPlex) {
            PlexSetupView()
        }
        .sheet(item: $switchingLibraryOn) { server in
            PlexLibraryPickerView(server: server)
        }
        .sheet(item: $serverBeingEdited) { server in
            ServerSetupView(editing: server)
        }
        .sheet(item: $proxySignIn) { request in
            ProxySignInView(config: request.config, url: request.url) { session in
                app.adoptProxySession(session)
            }
        }
    }

    /// When to count the library again.
    private var statsKey: String {
        guard case .synced(let at) = app.syncState else { return "\(app.libraryVersion)" }
        return "\(app.libraryVersion)-\(at.timeIntervalSince1970)"
    }

    private var isSyncing: Bool {
        if case .syncing = app.syncState { return true }
        return false
    }

    @ViewBuilder
    private var syncRow: some View {
        switch app.syncState {
        case .idle:
            Label("Not synced yet", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .syncing(let message):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(message)
            }
        case .synced:
            Label("Library synced", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What to call a server's two addresses.
    static func addressNames(
        _ addresses: ServerAddresses
    ) -> (local: String, remote: String) {
        let kinds = (addresses.local?.addressKind, addresses.remote?.addressKind)
        guard let first = kinds.0, let second = kinds.1, first != second else {
            return ("Local", "Remote")
        }
        return (first.label ?? "Local", second.label ?? "Remote")
    }

    /// Whether an address on the server's own network just answered — which is to say, whether this
    /// phone is on that network right now.
    private var onServersOwnNetwork: Bool {
        app.endpointChecks.contains { check in
            guard check.kind == .onYourNetwork else { return false }
            if case .reachable = check.outcome { return true }
            return false
        }
    }

    /// One address's result. Both are shown, because a green tick on the
    /// local address says nothing about whether you can reach the server from
    /// outside — which is the half that breaks.
    private func endpointCheckRow(
        _ check: AppModel.EndpointCheck, onServersOwnNetwork: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                switch check.outcome {
                case .checking:
                    ProgressView().controlSize(.small)
                case .reachable:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .signInRequired:
                    Image(systemName: "person.badge.key.fill").foregroundStyle(.orange)
                case .failed:
                    // A private address that does not answer while you are out is not a fault, and
                    // a red cross for it is the app reporting its own expectations as a problem.
                    if check.kind == .onYourNetwork, !onServersOwnNetwork {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                Text(check.title)
                Spacer()
                Text(Redactor.redacted(check.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            switch check.outcome {
            case .checking:
                EmptyView()
            case .reachable(let product):
                if let product {
                    Text(product).font(.caption).foregroundStyle(.secondary)
                }
            case .signInRequired(let url):
                Text("Behind a sign-in page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                signInButton(for: url)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.secondary)
                // A public address that fails while an address on the server's own network just
                // answered is not necessarily a broken one — it is what most home routers do to a
                // request for their own public address made from inside the network they serve.
                if check.kind == .fromAnywhere, onServersOwnNetwork {
                    Text("This can fail from home even when the address works away from it — many routers won't loop a request for their own public address back in from inside. Worth trying again once you're not on this network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // And the other way about: an address that only exists on the server's own network
                // cannot answer from anywhere else, and saying so is the difference between a fault
                // and a fact.
                if check.kind == .onYourNetwork, !onServersOwnNetwork {
                    Text("Only reachable on your server's own network. If you are on that network now, your server is advertising an address other devices can't reach — a container bridge or VPN interface on the machine it runs on is the usual cause. Plevi asks your server for a better one and switches to it on its own; if this is still here after reopening the app, the server has no other address to offer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Offered on any failure, not just a recognised wall: signing
                // in is harmless when it was not the problem, and there is no
                // reliable way to recognise every proxy's way of refusing.
                signInButton(for: check.url)
            }
        }
    }

    @ViewBuilder
    private func signInButton(for url: URL) -> some View {
        Button("Sign in…") {
            if let config = app.servers.activeServer {
                proxySignIn = .init(config: config, url: url)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var connectionRow: some View {
        switch app.connection {
        case .idle:
            Label("Not connected", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
            }
        case .connected(let info):
            Label(
                "Connected to \(info.productName ?? "server")",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connection failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Hedged on purpose: iOS does not say when Local Network
                // access was refused, so a failure to reach a home-network
                // address can only be offered as one possible reason.
                if app.connectionFailure.isReachabilityProblem,
                   app.servers.activeServer?.addresses.mayNeedLocalNetworkAccess == true {
                    Text("If this server is on your home network, check that Plevi is allowed to find devices on your local network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { UIApplication.shared.open(settings) }
                            .font(.caption)
                    }
                }
            }
        }
    }
}
