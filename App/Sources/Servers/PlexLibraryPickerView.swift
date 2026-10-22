import SwiftUI
import PleviDomain
import PleviPlexProvider
import PleviTransport

/// Switches between the music libraries on the Plex server you are connected to.
struct PlexLibraryPickerView: View {
    let server: ServerConfig

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [PlexLibrarySection] = []
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
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
                        Button {
                            switchTo(section)
                        } label: {
                            HStack {
                                Text(section.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if section.key == server.library?.key {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityLabel("Current library")
                                }
                            }
                        }
                        .disabled(isWorking)
                    }
                } footer: {
                    Text("Each library keeps its own index, artwork and sync state, so switching back later is quick.")
                }
            }
            .navigationTitle("Music Libraries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if sections.isEmpty && message == nil {
                    ProgressView()
                }
            }
        }
        .withoutBottomScrollEdgeBlur()
        .task { await load() }
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
        // Whichever address actually answers, not whichever is listed first: a Plex "local" address
        // is frequently the one that is unreachable — a different network, a phone on cellular —
        // and asking it first would leave this list empty for no good…
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

    private func switchTo(_ section: PlexLibrarySection) {
        guard section.key != server.library?.key else {
            dismiss()
            return
        }
        isWorking = true
        let selection = LibrarySelection(
            key: section.key,
            title: section.title,
            machineIdentifier: server.library?.machineIdentifier ?? ""
        )
        Task {
            await app.switchLibrary(to: selection)
            dismiss()
        }
    }
}
