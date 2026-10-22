import SwiftUI
import PleviDomain
import PleviTransport
import PleviSubsonicProvider

/// Add-server flow: form → staged diagnostics → optional certificate
/// approval (fingerprint pinning) → save. Credentials go straight to the
/// Keychain; the config file never sees them.
struct ServerSetupView: View {
    var isOnboarding = false
    /// The server being edited, if any. Its ID is kept, so saving replaces
    /// the entry in place rather than adding a second copy of the same
    /// server — which is what changing a password has to do.
    var editing: ServerConfig?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum AuthMethod: String, CaseIterable, Identifiable {
        case password = "Username & password"
        case apiKey = "API key"
        var id: String { rawValue }
    }

    private struct HeaderField: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    private enum Field: Hashable {
        case name
        case localAddress
        case remoteAddress
        case username
        case password
        case apiKey
        case headerName(UUID)
        case headerValue(UUID)
    }

    struct DiagnosticStep: Identifiable {
        enum State {
            case running
            case ok(String?)
            case warning(String)
            case failed(String)
        }

        let id = UUID()
        let title: String
        var state: State
    }

    private struct PendingCertificate: Identifiable {
        let id = UUID()
        let label: String
        let origin: URLOrigin
        let fingerprint: String
        let sha256: Data
    }

    @State private var name = ""
    @State private var localAddressText = ""
    @State private var remoteAddressText = ""
    @State private var authMethod: AuthMethod = .password
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var headers: [HeaderField] = []

    @State private var serverID = ServerID()
    @State private var pins: [PinnedCertificate] = []
    @State private var steps: [DiagnosticStep] = []
    @State private var testing = false
    @State private var pendingCertificate: PendingCertificate?
    @State private var testTask: Task<Void, Never>?
    /// Captured from an SSO proxy's login page during setup, and saved with
    /// the server once the test passes through it.
    @State private var proxySession: ProxySession?
    @State private var proxySignIn: ProxySignInPrompt?
    /// Saved, but with something the user should read first — so the sheet
    /// stays open instead of closing over a warning they never got to see.
    @State private var savedWithWarnings = false

    private struct ProxySignInPrompt: Identifiable {
        let id = UUID()
        let config: ServerConfig
        let url: URL
    }
    @FocusState private var focusedField: Field?

    /// How long an address gets to answer before the setup flow gives up.
    private static let probeTimeout: TimeInterval = 5
    private static let signInTimeout: TimeInterval = 12

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Home Navidrome)", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .localAddress }
                } header: {
                    Text("Server")
                }

                Section {
                    TextField("Local address", text: $localAddressText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .localAddress)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .remoteAddress }
                    TextField("Remote address", text: $remoteAddressText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .remoteAddress)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .username }
                } header: {
                    Text("Addresses")
                } footer: {
                    Text("Fill in either one, or both. IP or hostname with the port if it isn't standard — Navidrome's default is 4533; http or https is detected for you.\n\nLocal is your server's address on your own network. Remote reaches it from anywhere. With both, the app uses the local address whenever it answers and falls back to the remote one.")
                }

                Section("Sign in") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    switch authMethod {
                    case .password:
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                        SecureField("Password", text: $password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { startTest() }
                    case .apiKey:
                        SecureField("API key", text: $apiKey)
                            .focused($focusedField, equals: .apiKey)
                            .submitLabel(.go)
                            .onSubmit { startTest() }
                    }
                }

                Section {
                    ForEach($headers) { $header in
                        HStack {
                            TextField("Header", text: $header.name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .headerName(header.id))
                            SecureField("Value", text: $header.value)
                                .focused($focusedField, equals: .headerValue(header.id))
                        }
                    }
                    .onDelete { headers.remove(atOffsets: $0) }
                    Button("Add header") {
                        headers.append(HeaderField())
                    }
                } header: {
                    Text("Custom headers")
                } footer: {
                    Text("For proxies like Cloudflare Access (CF-Access-Client-Id / CF-Access-Client-Secret). Values are stored in the Keychain.")
                }

                if !steps.isEmpty {
                    Section("Connection test") {
                        ForEach(steps) { step in
                            DiagnosticRow(step: step)
                        }
                    }
                }

                Section {
                    if testing {
                        Button(role: .destructive) {
                            stopTest()
                        } label: {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Stop")
                            }
                        }
                    } else {
                        Button("Test & Save") {
                            startTest()
                        }
                        .disabled(
                            localAddressText.trimmingCharacters(in: .whitespaces).isEmpty
                                && remoteAddressText.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navigationTitle)
            .toolbar {
                if !isOnboarding || savedWithWarnings {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(savedWithWarnings ? "Done" : "Cancel") { dismiss() }
                    }
                }
            }
            // Editing anything abandons the run in flight and clears its
            // results, so correcting a typo neither waits for the old attempt
            // to time out nor leaves its error on screen.
            .onChange(of: localAddressText) { resetTest() }
            .onChange(of: remoteAddressText) { resetTest() }
            .onChange(of: username) { resetTest() }
            .onChange(of: password) { resetTest() }
            .onChange(of: apiKey) { resetTest() }
            .onDisappear { testTask?.cancel() }
            .task { loadServerBeingEdited() }
            .sheet(item: $proxySignIn) { prompt in
                ProxySignInView(config: prompt.config, url: prompt.url) { session in
                    proxySession = session
                    // Straight back into the test, now that we can get through.
                    startTest()
                }
            }
            .sheet(item: $pendingCertificate) { pending in
                CertificateApprovalView(
                    addressLabel: pending.label,
                    host: pending.origin.host,
                    fingerprint: pending.fingerprint,
                    onApprove: {
                        pins.append(PinnedCertificate(origin: pending.origin, sha256: pending.sha256))
                        pendingCertificate = nil
                        Task { await testAndSave() }
                    },
                    onCancel: {
                        pendingCertificate = nil
                        setState(of: "Certificates", to: .failed("Certificate was not approved."))
                        testing = false
                    }
                )
            }
        }
        .withoutBottomScrollEdgeBlur()
    }

    // MARK: Diagnostics flow

    private func startTest() {
        // Get the keyboard out of the way so the diagnostic steps are visible
        // while they run.
        focusedField = nil
        testTask?.cancel()
        testing = true
        testTask = Task {
            await testAndSave()
            testing = false
            testTask = nil
        }
    }

    /// Abandons an in-flight test and marks the step it was on, leaving the
    /// results visible.
    private func stopTest() {
        testTask?.cancel()
        testTask = nil
        testing = false
        if let index = steps.indices.last, case .running = steps[index].state {
            steps[index].state = .failed("Stopped.")
        }
    }

    /// Abandons an in-flight test and clears the results.
    private func resetTest() {
        testTask?.cancel()
        testTask = nil
        testing = false
        steps = []
    }

    private var navigationTitle: String {
        if editing != nil { return "Edit server" }
        return isOnboarding ? "Connect a server" : "Add server"
    }

    /// Fills the form from the stored config and its Keychain entries.
    private func loadServerBeingEdited() {
        guard let editing, serverID != editing.id else { return }
        serverID = editing.id
        name = editing.name
        switch editing.addresses {
        case .local(let url):
            localAddressText = url.absoluteString
        case .remote(let url):
            remoteAddressText = url.absoluteString
        case .both(let local, let remote):
            localAddressText = local.absoluteString
            remoteAddressText = remote.absoluteString
        }
        pins = editing.pinnedCertificates

        switch app.servers.credentials(for: editing.id) {
        case .usernamePassword(let user, let secret):
            authMethod = .password
            username = user
            password = secret
        case .apiKey(let key):
            authMethod = .apiKey
            apiKey = key
        case nil:
            break
        }

        let values = app.servers.headerValues(for: editing)
        headers = editing.customHeaderNames.map { HeaderField(name: $0, value: values[$0] ?? "") }
    }

    private func testAndSave() async {
        steps = []
        savedWithWarnings = false

        let localText = localAddressText.trimmingCharacters(in: .whitespaces)
        let remoteText = remoteAddressText.trimmingCharacters(in: .whitespaces)

        // Step 1 — interpret each address that was filled in. Explicit
        // schemes are kept; bare private hosts are probed https-then-http.
        appendStep("Addresses", .running)
        guard !localText.isEmpty || !remoteText.isEmpty else {
            setState(of: "Addresses", to: .failed("Enter a local address, a remote address, or both."))
            return
        }

        var localURL: URL?
        var remoteURL: URL?
        var unreachable: [String] = []

        if !localText.isEmpty {
            switch await resolveAddress(localText, label: "Local") {
            case .resolved(let url):
                localURL = url
            case .unreachable:
                // A local address is expected to be unreachable when away
                // from home, so this only blocks when nothing else works.
                unreachable.append("local")
            case .invalid:
                return
            }
        }
        if Task.isCancelled { return }
        if !remoteText.isEmpty {
            switch await resolveAddress(remoteText, label: "Remote") {
            case .resolved(let url):
                remoteURL = url
            case .unreachable:
                unreachable.append("remote")
            case .invalid:
                return
            }
        }
        if Task.isCancelled { return }

        // Keep an address the user typed even if it didn't answer just now,
        // as long as something else did — the config should still describe
        // their server correctly.
        if localURL == nil, !localText.isEmpty, remoteURL != nil {
            localURL = EndpointValidation.candidateURLs(forUserInput: localText).first
        }
        if remoteURL == nil, !remoteText.isEmpty, localURL != nil {
            remoteURL = EndpointValidation.candidateURLs(forUserInput: remoteText).first
        }

        guard let addresses = ServerAddresses(local: localURL, remote: remoteURL) else {
            let which = unreachable.count > 1 ? "those addresses" : "that address"
            setState(of: "Addresses", to: .failed(
                "Nothing answered at \(which). Check the address and port — Navidrome's default port is 4533."
            ))
            return
        }

        if !unreachable.isEmpty {
            setState(of: "Addresses", to: .warning(
                "The \(unreachable.joined(separator: " and ")) address didn't answer from here — saved anyway; it will be used when reachable."
            ))
        } else if addresses.inPreferenceOrder.contains(where: { $0.scheme == "http" }) {
            setState(of: "Addresses", to: .warning("Using an unencrypted connection — acceptable only on your own network."))
        } else {
            setState(of: "Addresses", to: .ok(addresses.local != nil && addresses.remote != nil
                ? "Local preferred, remote as fallback."
                : nil))
        }

        // Step 2 — TLS, evaluated per address so a self-signed certificate on
        // one never affects trust for the other.
        appendStep("Certificates", .running)
        for url in addresses.inPreferenceOrder where url.scheme == "https" {
            guard let origin = URLOrigin(url: url) else { continue }
            if pins.contains(where: { $0.origin == origin }) { continue }
            switch await TrustProber.probe(url) {
            case .trusted, .unreachable:
                continue
            case .untrusted(let fingerprint, let sha256):
                pendingCertificate = PendingCertificate(
                    label: url == addresses.local ? "local" : "remote",
                    origin: origin,
                    fingerprint: fingerprint,
                    sha256: sha256
                )
                return
            }
        }
        let pinCount = pins.count
        setState(of: "Certificates", to: .ok(pinCount > 0
            ? pinCount.counted("certificate") + " pinned to your approval."
            : nil))

        // Step 3 — authenticate against the server.
        appendStep("Sign in", .running)
        let credentials: SubsonicCredentials
        switch authMethod {
        case .password:
            let trimmedUser = username.trimmingCharacters(in: .whitespaces)
            guard !trimmedUser.isEmpty, !password.isEmpty else {
                setState(of: "Sign in", to: .failed("Enter your username and password."))
                return
            }
            credentials = .usernamePassword(username: trimmedUser, password: password)
        case .apiKey:
            guard !apiKey.isEmpty else {
                setState(of: "Sign in", to: .failed("Enter your API key."))
                return
            }
            credentials = .apiKey(apiKey)
        }
        let headerFields = headers.filter { !$0.name.isEmpty && !$0.value.isEmpty }
        let config = ServerConfig(
            id: serverID,
            name: name.isEmpty ? (addresses.preferred.host() ?? "Server") : name,
            addresses: addresses,
            pinnedCertificates: pins,
            customHeaderNames: headerFields.map(\.name)
        )
        let provider = SubsonicProvider(
            config: config,
            credentials: credentials,
            customHeaders: Dictionary(
                headerFields.map { ($0.name, $0.value) },
                uniquingKeysWith: { first, _ in first }
            ),
            transport: ServerHTTPTransport(
                config: config,
                timeout: Self.signInTimeout,
                proxySessions: ProxySessionHolder(proxySession)
            )
        )
        do {
            let info = try await provider.testConnection()
            if Task.isCancelled { return }
            let product = [info.productName, info.productVersion]
                .compactMap(\.self)
                .joined(separator: " ")
            setState(of: "Sign in", to: .ok(product.isEmpty ? nil : "Connected to \(product)."))
        } catch ProviderError.proxySignInRequired(let wallURL) {
            if Task.isCancelled { return }
            // Not the music server talking: a proxy in front of it wants a
            // browser session first. Offer its page rather than reporting
            // credentials the user has no reason to doubt.
            setState(of: "Sign in", to: .warning("This address is behind a sign-in page."))
            proxySignIn = ProxySignInPrompt(config: config, url: wallURL)
            return
        } catch {
            if Task.isCancelled { return }
            let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            setState(of: "Sign in", to: .failed(message))
            return
        }

        // Step 3b — with both addresses filled in, the one the sign-in test did not use is still
        // unproven.
        if case .both(_, let remote) = addresses {
            appendStep("Remote access", .running)
            let remoteProvider = SubsonicProvider(
                config: config,
                credentials: credentials,
                customHeaders: Dictionary(
                    headerFields.map { ($0.name, $0.value) },
                    uniquingKeysWith: { first, _ in first }
                ),
                transport: ServerHTTPTransport(
                    config: config,
                    timeout: Self.signInTimeout,
                    proxySessions: ProxySessionHolder(proxySession)
                )
            )
            await remoteProvider.setBaseURL(remote)
            do {
                _ = try await remoteProvider.testConnection()
                if Task.isCancelled { return }
                setState(of: "Remote access", to: .ok("Reachable from outside your network."))
            } catch ProviderError.proxySignInRequired(let wallURL) {
                if Task.isCancelled { return }
                setState(of: "Remote access", to: .warning("The remote address is behind a sign-in page."))
                proxySignIn = ProxySignInPrompt(config: config, url: wallURL)
                return
            } catch {
                if Task.isCancelled { return }
                // Plenty of setups cannot reach their own remote address from
                // inside the network. Not a reason to refuse the server.
                setState(of: "Remote access", to: .warning(
                    "Couldn't check the remote address from here — saved anyway."
                ))
            }
        }

        // Step 4 — persist and activate.
        do {
            try app.servers.add(
                config,
                credentials: credentials,
                headerValues: Dictionary(
                    headerFields.map { ($0.name, $0.value) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        } catch {
            appendStep("Save", .failed("Could not store credentials in the Keychain."))
            return
        }
        app.servers.setProxySession(proxySession, for: config.id)
        await app.connectActive()
        if steps.contains(where: { if case .warning = $0.state { return true } else { return false } }) {
            appendStep("Saved", .ok("Saved. Review the warnings above, then tap Done."))
            savedWithWarnings = true
            return
        }
        dismiss()
    }

    private enum AddressResolution {
        case resolved(URL)
        /// Well-formed but nothing answered.
        case unreachable
        /// Rejected outright; a diagnostic message has been shown.
        case invalid
    }

    /// Turns whatever the user typed into a working URL.
    private func resolveAddress(_ text: String, label: String) async -> AddressResolution {
        let candidates = EndpointValidation.candidateURLs(forUserInput: text)
        guard !candidates.isEmpty else {
            setState(of: "Addresses", to: .failed(
                "\(label): enter a valid address, e.g. music.example.com or 192.168.1.20:4533"
            ))
            return .invalid
        }
        for candidate in candidates {
            if let issue = EndpointValidation.validate(candidate) {
                setState(of: "Addresses", to: .failed("\(label): \(message(for: issue))"))
                return .invalid
            }
        }

        for candidate in candidates {
            if Task.isCancelled { return .invalid }
            setState(of: "Addresses", to: .running)
            switch await TrustProber.probe(candidate, timeout: Self.probeTimeout) {
            case .trusted, .untrusted:
                // Untrusted just means a certificate we haven't approved yet —
                // the certificate step handles the approval flow.
                return .resolved(candidate)
            case .unreachable:
                continue
            }
        }
        return .unreachable
    }

    private func message(for issue: EndpointValidation.Issue) -> String {
        switch issue {
        case .notHTTPURL:
            return "Enter a valid http(s) URL."
        case .embedsCredentials:
            return "Remove the username/password from the URL — credentials are entered below."
        case .plainHTTPToPublicHost:
            return "Public servers must use https://. Unencrypted HTTP is only allowed for private addresses."
        }
    }

    private func appendStep(_ title: String, _ state: DiagnosticStep.State) {
        steps.append(DiagnosticStep(title: title, state: state))
    }

    private func setState(of title: String, to state: DiagnosticStep.State) {
        guard let index = steps.lastIndex(where: { $0.title == title }) else { return }
        steps[index].state = state
    }
}

private struct DiagnosticRow: View {
    let step: ServerSetupView.DiagnosticStep

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            switch step.state {
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        switch step.state {
        case .running:
            return nil
        case .ok(let message):
            return message
        case .warning(let message), .failed(let message):
            return message
        }
    }
}

/// Shows the untrusted certificate's SHA-256 fingerprint for out-of-band
/// verification before pinning it for this server.
struct CertificateApprovalView: View {
    let addressLabel: String
    let host: String
    let fingerprint: String
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Certificate not trusted", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.headline)
                    Text("Your \(addressLabel) address (\(host)) presented a certificate iOS does not trust — typical for self-signed certificates. Compare this SHA-256 fingerprint with the one on your server before approving. If they differ, someone may be intercepting the connection.")
                        .font(.callout)
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Text("Approving pins this exact certificate for this address only: connections to it will fail if it ever presents a different one until you re-approve. Your other address is unaffected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Verify certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve & Pin", action: onApprove)
                }
            }
        }
        .withoutBottomScrollEdgeBlur()
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}
