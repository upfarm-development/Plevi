import SwiftUI
@preconcurrency import WebKit
import PleviDomain
import PleviTransport
import PleviPlexProvider

/// Signing in to Plex: approve on plex.tv, choose a Home user, choose a server, choose a music
/// library.
struct PlexSetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Set only for **Sign In Again**: re-proving this device's sign-in
    /// for an *existing* Plex config, rather than adding a new one.
    var reauthorizing: ServerConfig? = nil

    @State private var step: Step = .start
    @State private var token: String?
    @State private var homeUsers: [PlexHomeUser] = []
    @State private var servers: [PlexResource] = []
    @State private var sections: [PlexLibrarySection] = []
    @State private var chosenUser: PlexHomeUser?
    @State private var chosenServer: PlexResource?
    @State private var chosenSection: PlexLibrarySection?
    @State private var protectedUserPIN = ""
    @State private var userNeedingPIN: PlexHomeUser?
    @State private var error: String?
    @State private var signInURL: URL?
    /// Whichever of the server's addresses answered during setup.
    @State private var reachableURL: URL?
    /// What the flow is waiting on. Silence during a slow step is
    /// indistinguishable from being stuck.
    @State private var status: String?
    @State private var work: Task<Void, Never>?

    private enum Step: Equatable {
        case start
        case signingIn
        case choosingUser
        case choosingServer
        case choosingLibrary
        case connecting
        case done
        case saving
    }

    private var identity: PlexIdentity { PlexInstallation.identity }
    private var client: PlexClient { PlexClient(identity: identity) }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                content
            }
            .navigationTitle(reauthorizing == nil ? "Add Plex" : "Sign In Again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        work?.cancel()
                        dismiss()
                    }
                }
            }
            .sheet(item: Binding(
                get: { signInURL.map(IdentifiedURL.init) },
                set: { if $0 == nil { signInURL = nil } }
            )) { wrapped in
                PlexSignInWebView(url: wrapped.url) { signInURL = nil }
            }
            .alert(
                "PIN for \(userNeedingPIN?.title ?? "this profile")",
                isPresented: Binding(
                    get: { userNeedingPIN != nil },
                    set: { if !$0 { userNeedingPIN = nil; protectedUserPIN = "" } }
                ),
                presenting: userNeedingPIN
            ) { user in
                // A managed profile is locked with a PIN on the Plex Home;
                // without asking, choosing one would simply stall.
                SecureField("PIN", text: $protectedUserPIN)
                    .keyboardType(.numberPad)
                Button("Continue") {
                    let pin = protectedUserPIN
                    protectedUserPIN = ""
                    userNeedingPIN = nil
                    guard let token else { return }
                    work = Task { await switchAndContinue(to: user, pin: pin, token: token) }
                }
                Button("Cancel", role: .cancel) {
                    userNeedingPIN = nil
                    protectedUserPIN = ""
                }
            }
            .onDisappear { work?.cancel() }
        }
        .withoutBottomScrollEdgeBlur()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .start:
            Section {
                Button("Sign in with Plex") { beginSignIn() }
            } footer: {
                Text("Opens Plex's own sign-in page. Plevi never sees your Plex password — Plex hands back a token once you approve.")
            }
        case .signingIn:
            Section {
                busy(status ?? "Waiting for approval on plex.tv…")
                Button("Open the sign-in page again") { reopenSignIn() }
            }
        case .connecting:
            Section {
                busy(status ?? "Connecting…")
            } footer: {
                Text("Plex lists every address a server might answer on. Each is tried in turn, so this can take a moment when the first one isn't reachable from here.")
            }
        case .choosingUser:
            Section("Who is listening?") {
                ForEach(homeUsers) { user in
                    Button {
                        select(user)
                    } label: {
                        HStack {
                            Text(user.title)
                            if user.isAdmin {
                                Text("Admin").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if user.isProtected {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        case .choosingServer:
            Section("Which server?") {
                ForEach(servers) { server in
                    Button {
                        select(server)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            if let url = server.localURL ?? server.remoteURL {
                                Text(Redactor.redacted(url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        case .choosingLibrary:
            Section {
                ForEach(sections) { section in
                    Button(section.title) { select(section) }
                }
            } header: {
                Text("Which music library?")
            } footer: {
                if sections.isEmpty {
                    Text("This server has no music libraries.")
                }
            }
        case .done:
            Section {
                LabeledContent("User", value: chosenUser?.title ?? "—")
                LabeledContent("Server", value: chosenServer?.name ?? "—")
                LabeledContent("Library", value: chosenSection?.title ?? "—")
            } header: {
                Text("Chosen")
            }
            Section {
                Button("Add this library") { save() }
            } footer: {
                Text("Saved as its own server with its own library index — switching between this and Navidrome in Settings swaps everything over.")
            }
        case .saving:
            Section {
                busy(status ?? "Adding…")
            }
        }
    }

    private func busy(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message)
        }
    }

    // MARK: Steps

    private func beginSignIn() {
        error = nil
        step = .signingIn
        work?.cancel()
        work = Task {
            do {
                let pin = try await client.createPin()
                signInURL = PlexAuth.signInURL(pin: pin, identity: identity)
                let poller = PlexSignInPoller()
                guard let claimed = try await poller.awaitToken(for: pin, client: client) else {
                    if !Task.isCancelled {
                        fail("The sign-in wasn't completed. Try again.")
                    }
                    return
                }
                guard !Task.isCancelled else { return }
                signInURL = nil
                token = claimed
                status = "Signed in. Loading your profiles…"
                await loadHomeUsers(token: claimed)
            } catch {
                fail(message(for: error))
            }
        }
    }

    private func reopenSignIn() {
        // The URL is still valid until the PIN lapses, so this only puts the
        // page back rather than starting the whole sign-in again.
        guard signInURL == nil else { return }
        beginSignIn()
    }

    private func loadHomeUsers(token: String) async {
        do {
            let users = try await client.homeUsers(token: token)
            homeUsers = users
            // Nothing to choose between with a single account.
            if users.count <= 1 {
                chosenUser = users.first
                await afterSignIn(token: token)
            } else {
                step = .choosingUser
            }
        } catch {
            // A plain account with no Plex Home returns nothing useful here;
            // that is not a failure, it just means there is no picker.
            await afterSignIn(token: token)
        }
    }

    private func select(_ user: PlexHomeUser) {
        guard let token else { return }
        chosenUser = user
        if user.isProtected {
            userNeedingPIN = user
            return
        }
        // Signing in as the account owner already gives the owner's token,
        // so switching to themselves is a round trip that can only fail.
        if user.isAdmin {
            work = Task { await afterSignIn(token: token) }
            return
        }
        step = .connecting
        status = "Switching to \(user.title)…"
        work = Task { await switchAndContinue(to: user, pin: nil, token: token) }
    }

    private func switchAndContinue(to user: PlexHomeUser, pin: String?, token: String) async {
        do {
            // The switched token is the one everything afterwards must use:
            // their library and their ratings are not the admin's.
            let switched = try await client.switchToHomeUser(id: user.id, pin: pin, token: token)
            self.token = switched
            await afterSignIn(token: switched)
        } catch {
            fail(message(for: error))
            step = .choosingUser
        }
    }

    /// Where sign-in leads once a final token is in hand: choosing a server
    /// and library when adding a new config, or, for **Sign In Again**,
    /// straight to confirming this is still the same server.
    private func afterSignIn(token: String) async {
        if reauthorizing != nil {
            await reauthorize(token: token)
        } else {
            await loadServers(token: token)
        }
    }

    /// **Sign In Again**: confirms the newly signed-in account can still
    /// reach `reauthorizing`'s own server — by its `machineIdentifier`, not just its address, since
    /// Plex tells two different servers apart that way, not…
    private func reauthorize(token: String) async {
        guard let reauthorizing else { return }
        step = .connecting
        status = "Confirming your account…"
        do {
            let found = try await client.servers(token: token)
            guard let server = found.first(where: { $0.clientIdentifier == reauthorizing.library?.machineIdentifier }) else {
                fail("This isn't signed in to the same Plex server as \"\(reauthorizing.name)\".")
                return
            }
            let effectiveToken = server.accessToken ?? token
            // A failure here does not stop the sign-in: the config just
            // takes no part in the iCloud check until it succeeds another
            // time, and other devices ask for a code instead (§4.3.4).
            let accountID = try? await client.currentUser(token: effectiveToken).uuid
            app.servers.setPlexSignIn(accountID: accountID, token: effectiveToken, for: reauthorizing.id)
            await app.connectActive()
            dismiss()
        } catch {
            fail(message(for: error))
        }
    }

    private func loadServers(token: String) async {
        step = .connecting
        status = "Finding your Plex servers…"
        do {
            let found = try await client.servers(token: token)
            servers = found
            if found.count == 1 {
                await select(found[0], token: token)
            } else if found.isEmpty {
                fail("No Plex servers on this account.")
            } else {
                step = .choosingServer
            }
        } catch {
            fail(message(for: error))
        }
    }

    private func select(_ server: PlexResource) {
        guard let token else { return }
        work = Task { await select(server, token: token) }
    }

    private func select(_ server: PlexResource, token: String) async {
        chosenServer = server
        let candidates = server.connectionsInPreferenceOrder
        guard !candidates.isEmpty else {
            fail("That server has no address we can reach.")
            return
        }
        step = .connecting
        // How many addresses are being raced is our business, not the
        // reader's — the useful part is which server is being reached.
        status = "Connecting to \(server.name)…"
        do {
            // Every address Plex offers is tried, each a moment after the one before it.
            let (url, found) = try await client.firstReachableLibrary(
                among: candidates,
                token: server.accessToken ?? token
            )
            reachableURL = url
            sections = found
            if found.count == 1 {
                select(found[0])
            } else {
                step = .choosingLibrary
            }
        } catch {
            fail("Couldn't reach \(server.name) at any of its addresses. \(message(for: error))")
        }
    }

    private func select(_ section: PlexLibrarySection) {
        chosenSection = section
        step = .done
    }

    /// Stores the choices as an ordinary server. Both addresses are kept
    /// where Plex offered them, so the same local-preferred, remote-fallback
    /// behaviour applies as for Navidrome.
    private func save() {
        // Each slot gets an address of its own kind, and the one that just answered goes into
        // whichever slot it belongs to.
        let connections = chosenServer?.connectionsInPreferenceOrder ?? []
        let locals = connections.filter(\.isLocal).map(\.uri)
        let remotes = connections.filter { !$0.isLocal }.map(\.uri)
        let answered = reachableURL
        let local = locals.first { $0 == answered } ?? locals.first
        let remote = remotes.first { $0 == answered } ?? remotes.first
        guard let token,
              let server = chosenServer,
              let section = chosenSection,
              let addresses = ServerAddresses(local: local, remote: remote)
                  ?? answered.map(ServerAddresses.remote)
        else {
            fail("Something is missing — start again.")
            return
        }
        step = .saving
        status = "Adding \(section.title)…"
        // A server the account merely has access to carries its own token;
        // the account's will not open it.
        let effectiveToken = server.accessToken ?? token
        work = Task {
            // A failure here does not stop the setup: the config just takes
            // no part in the iCloud check until Sign In Again succeeds.
            let accountID = try? await client.currentUser(token: effectiveToken).uuid
            let config = ServerConfig(
                name: plexServerName(server, section: section),
                addresses: addresses,
                kind: .plex,
                library: LibrarySelection(
                    key: section.key,
                    title: section.title,
                    machineIdentifier: server.clientIdentifier
                ),
                accountID: accountID
            )
            do {
                try app.servers.addPlexServer(config, token: effectiveToken)
                await app.connectActive()
                dismiss()
            } catch {
                fail("Couldn't store the Plex token in the Keychain.")
                step = .done
            }
        }
    }

    /// Names it after the library when a server has several, so two libraries
    /// from one Plex box are told apart in the server list.
    private func plexServerName(_ server: PlexResource, section: PlexLibrarySection) -> String {
        sections.count > 1 ? "\(server.name) — \(section.title)" : server.name
    }

    private func fail(_ message: String) {
        error = message
        status = nil
        if step == .signingIn || step == .connecting { step = .start }
    }

    private func message(for error: any Error) -> String {
        (error as? ProviderError)?.errorDescription ?? error.localizedDescription
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }

    init(_ url: URL) { self.url = url }
}

/// Plex's sign-in page, shown so the user types their password into Plex and
/// not into us. Non-persistent, so nothing is left behind afterwards.
private struct PlexSignInWebView: View {
    let url: URL
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebViewContainer(url: url)
                .navigationTitle("Sign in to Plex")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            onFinished()
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// The identity this install presents to Plex.
enum PlexInstallation {
    private static let key = "plex.clientIdentifier"

    static var identity: PlexIdentity {
        PlexIdentity(
            clientIdentifier: clientIdentifier,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            platform: "iOS",
            platformVersion: UIDevice.current.systemVersion,
            device: UIDevice.current.model,
            deviceName: UIDevice.current.name
        )
    }

    private static var clientIdentifier: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
