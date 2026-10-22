import SwiftUI
import PleviDomain
import PleviPlexProvider
import PleviTransport

/// Which libraries the Home screen's switcher offers.
struct QuickSwitchSettingsView: View {
    let server: ServerConfig

    @Environment(AppModel.self) private var app

    @State private var sections: [PlexLibrarySection] = []
    @State private var message: String?

    /// This server's own ticks. The setting is one list for every server, so
    /// the rest of it belongs to other servers and is left as it is.
    private var chosen: [LibrarySelection] {
        server.quickSwitchChoices(from: app.settings.quickSwitchLibraries)
    }

    var body: some View {
        List {
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(sections) { section in
                    let isOn = chosen.contains { $0.key == section.key }
                    SettingToggle(section.title, isOn: Binding(
                        get: { isOn },
                        set: { wanted in toggle(section, on: wanted) }
                    ))
                }
            } header: {
                Text("Libraries")
            } footer: {
                if chosen.count < 2 {
                    Text("Tick two or more to get a switcher on Home.")
                }
            }
        }
        .navigationTitle("Quick Switch")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if sections.isEmpty && message == nil {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func toggle(_ section: PlexLibrarySection, on wanted: Bool) {
        var updated = app.settings.quickSwitchLibraries
        let machine = server.library?.machineIdentifier ?? ""
        // A section key is only unique within its server: "1" on one Plex
        // machine is not "1" on another.
        func isThis(_ selection: LibrarySelection) -> Bool {
            selection.key == section.key && selection.machineIdentifier == machine
        }
        if wanted {
            guard !updated.contains(where: isThis) else { return }
            updated.append(LibrarySelection(
                key: section.key,
                title: section.title,
                machineIdentifier: machine
            ))
        } else {
            updated.removeAll(where: isThis)
        }
        app.settings.quickSwitchLibraries = updated
        // A library just ticked is read now, in the background, so a search
        // across libraries can find it without ever having switched to it.
        if wanted { app.syncOtherQuickLibraries() }
    }

    private func load() async {
        guard let token = app.servers.plexToken(for: server.id) else {
            message = "No stored Plex token for this server — add it again from Settings."
            return
        }
        // Offline Mode is a promise about the network, and the token would
        // travel with this request.
        guard !app.settings.offlineMode else {
            message = "Offline Mode is on. Turn it off to see this server's libraries."
            return
        }
        // Whichever address answers, as everywhere else.
        let selector = EndpointSelector(config: server)
        let url = await selector.activeBaseURL()
        await selector.close()
        do {
            sections = try await PlexClient(identity: PlexInstallation.identity)
                .musicSections(server: url, token: token, transport: app.settingsTransport(for: server))
            if sections.isEmpty {
                message = "This Plex server has no music libraries."
            }
        } catch {
            message = "Couldn't reach the server: \(error.localizedDescription)"
        }
    }
}
