import SwiftUI
import PleviTransport

/// Settings: what there is to decide, and the truth about where things stand.
struct SettingsPage: View {
    @Environment(WatchModel.self) private var model
    @State private var confirmingClear = false
    @State private var confirmingClearOthers = false
    /// Read when the screen opens and after a clear, rather than from the body: both of these walk
    /// the file system, and a `List` asks its rows for their content more often than a watch should
    /// be reading a directory.
    @State private var usage: Int64 = 0
    @State private var freeBytes: Int64?

    var body: some View {
        @Bindable var settings = model.settings

        List {
            Section {
                Picker("Start page", selection: $settings.startPage) {
                    ForEach(StartPage.allCases) { page in
                        Text(page.label).tag(page)
                    }
                }
                .frame(minHeight: WatchMetrics.row)
            } footer: {
                Text("Which page the app opens on.")
            }

            audioSection(
                "Streaming",
                choice: $settings.streaming,
                footer: streamingFootnote
            )

            audioSection(
                "Downloads",
                choice: $settings.downloads,
                footer: "What is kept on the watch. Smaller files leave room for more, and play with no server in reach."
            )

            Section {
                LabeledContent("Downloads", value: used)
                LabeledContent("Free", value: free)
                Button("Clear Downloads", role: .destructive) { confirmingClear = true }
                    .frame(minHeight: WatchMetrics.row)
                    .disabled(usage == 0)
                // Libraries the phone has been pointed at since.
                if model.otherLibraryBytes > 0 {
                    LabeledContent(
                        "Other libraries",
                        value: ByteCountFormatter.string(
                            fromByteCount: model.otherLibraryBytes, countStyle: .file
                        )
                    )
                    Button("Remove Other Libraries", role: .destructive) {
                        confirmingClearOthers = true
                    }
                    .frame(minHeight: WatchMetrics.row)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("The files go; nothing on your server is touched.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
            }

            Section("Library") {
                LabeledContent("Server", value: model.serverName ?? "None")
                LabeledContent("Songs", value: songCount)
                LabeledContent("Sent", value: sentAt)
            }

            // What the watch actually reached, said plainly.
            Section {
                LabeledContent("Reached", value: reached)
                LabeledContent("Address", value: address)
                if let problem = model.connectionProblem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // The other half of the picture.
                if let local = localAttempt {
                    LabeledContent(localAttemptLabel, value: local.host)
                    if let failure = local.failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Which of your server's addresses this watch is using.")
            }

            // Whether the songs behind this one are actually being got
            // ready. Nothing else on the watch can say so, and "it does not
            // start instantly" is the same sentence whether they are or not.
            if model.player.currentTrack != nil {
                Section("Playback") {
                    LabeledContent(
                        "Ready ahead",
                        value: "\(model.player.readyAhead.ready) of \(model.player.readyAhead.of)"
                    )
                }
            }

            // The playing screen says this too, in three lines that a conversion failure quoting
            // the server back at you does not fit in — and loses it the moment anything else plays.
            if let problem = model.player.lastProblem {
                Section("Last playback problem") {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        // Measured when the screen opens, again when the downloads arrive, and again when a batch
        // starts or ends.
        .task(id: measureKey) { measure() }
        .task(id: model.libraryVersion) { await model.measureOtherLibraries() }
        .confirmationDialog(
            "Remove the libraries and music this watch kept from other servers?",
            isPresented: $confirmingClearOthers,
            titleVisibility: .visible
        ) {
            Button("Remove Other Libraries", role: .destructive) {
                Task { await model.removeOtherLibraries() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove everything downloaded to this watch?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Downloads", role: .destructive) {
                model.downloads?.removeEverything()
                measure()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Changes when there is something new to count: the downloads arriving,
    /// or a batch starting or finishing.
    private var measureKey: String {
        let ready = model.downloads != nil
        let running = model.downloads?.isDownloading ?? false
        return "\(ready)-\(running)"
    }

    private func measure() {
        usage = model.downloads?.usage() ?? 0
        freeBytes = Self.freeSpace()
    }

    /// One section, asked the same way for playing and for keeping.
    private func audioSection(
        _ title: String,
        choice: Binding<WatchAudioChoice>,
        footer: String
    ) -> some View {
        Section {
            Toggle("Transcode", isOn: choice.converts)
                .frame(minHeight: WatchMetrics.row)
            if choice.wrappedValue.converts {
                // One format, so it is stated rather than chosen — see
                // `WatchAudioFormat` for what happened to the other one.
                if WatchAudioFormat.allCases.count > 1 {
                    Picker("Format", selection: choice.format) {
                        ForEach(WatchAudioFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .frame(minHeight: WatchMetrics.row)
                }
                Picker("Quality", selection: choice.kbps) {
                    ForEach(WatchSettings.bitRates, id: \.self) { rate in
                        Text("\(rate) kbps").tag(rate)
                    }
                }
                .frame(minHeight: WatchMetrics.row)
            }
        } header: {
            Text(title)
        } footer: {
            Text(choice.wrappedValue.converts
                 ? footer
                 : "Songs come as your server keeps them. Formats this watch cannot play are converted anyway.")
        }
    }

    /// What the Streaming section says under itself.
    private var streamingFootnote: String {
        switch model.settings.streaming.format {
        case .mp3: "MP3 starts playing almost immediately."
        }
    }

    private var used: String {
        usage > 0 ? ByteCountFormatter.string(fromByteCount: usage, countStyle: .file) : "None"
    }

    private var free: String {
        guard let freeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }

    /// Space left on the watch.
    private static func freeSpace() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// The marketing version and the build, from this app's own bundle.
    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(marketing) (\(build))"
    }()

    /// Whether the last attempt got through, from the same flag the rest of
    /// the app reads.
    private var reached: String {
        guard model.link.provisioning?.config != nil else { return "No server yet" }
        return model.connectionProblem == nil ? "Yes" : "No"
    }

    /// The host in use, and which of the two it is.
    private var address: String {
        guard let choice = model.reachedAddress else { return "Not tried yet" }
        let host = choice.url.host() ?? choice.url.absoluteString
        guard let kind = choice.url.addressKind.label else { return host }
        return "\(host) (\(kind.lowercased()))"
    }

    /// The local address and what became of it, when this server has one and it is not already the
    /// address shown above.
    private var localAttempt: (host: String, failure: String?)? {
        guard let choice = model.reachedAddress, !choice.isLocal,
              let host = choice.localHost
        else { return nil }
        // Only worth a line when it failed for a reason worth reading.
        guard ServerAddressKind(host: host) != .onYourNetwork
                || model.reachedAddress?.url.addressKind == .onYourNetwork
        else { return (host, "Only answers on your server's own network.") }
        return (host, choice.localFailure)
    }

    /// What to call the address that is not in use — again from the address
    /// rather than the slot.
    private var localAttemptLabel: String {
        guard let host = model.reachedAddress?.localHost else { return "Other address" }
        return ServerAddressKind(host: host).label.map { "\($0) address" } ?? "Other address"
    }

    private var songCount: String {
        guard let library = model.library else { return "None yet" }
        let count = library.trackCount
        return count == 1 ? "1 song" : "\(count) songs"
    }

    private var sentAt: String {
        guard let date = model.link.provisioning?.librarySentAt else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}
