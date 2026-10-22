import SwiftUI
import PleviDomain

/// The settings root: a short list of pages, and a search across every setting on them.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    pages
                    Section("About") {
                        LabeledContent("Version", value: Self.versionString)
                        LabeledContent("Build", value: Self.buildString)
                        NavigationLink {
                            RecentProblemsView()
                        } label: {
                            LabeledContent(
                                "Recent problems",
                                value: app.recentProblems.isEmpty ? "None" : "\(app.recentProblems.count)"
                            )
                        }
                        NavigationLink("Remote Control (developer)") { RemoteDebugView() }
                    }
                    signature
                } else {
                    searchResults
                }
            }
            .navigationTitle("Settings")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search settings"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .withoutBottomScrollEdgeBlur()
    }

    /// The app's mark at the foot of its settings, where an app signs its
    /// name. Quiet: it is a signature, not a heading.
    private var signature: some View {
        HStack(spacing: 18) {
            Image("PleviLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 104, height: 104)
            // Twice the size of a title, to match the mark beside it.
            Text("Plevi")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 18)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plevi")
    }

    @ViewBuilder
    private var pages: some View {
        Section {
            NavigationLink {
                ServerSettingsView()
            } label: {
                HStack {
                    Label("Servers", systemImage: "externaldrive.connected.to.line.below")
                        .labelStyle(.accentIcon)
                    Spacer(minLength: 8)
                    connectionIndicator
                }
            }
        }

        // One page per part of the app, rather than one long "Interface" and one long "Playback"
        // holding everything between them.
        Section {
            row("Appearance", "paintbrush") { AppearanceSettingsView() }
            row("Home", "house") { HomeSectionsSettingsView() }
            row("Library", "square.stack") { LibrarySettingsView() }
            row("Search", "magnifyingglass") { SearchSettingsView() }
            row("Playlists", "music.note.list") { PlaylistSettingsView() }
            row("Now Playing", "play.circle") { NowPlayingSettingsView() }
        }

        Section {
            row("Playback", "waveform") { PlaybackSettingsView() }
            row("Remote Control", "iphone.and.arrow.forward") { RemoteControlSettingsView() }
            row("Downloads & Data", "internaldrive") { StorageSettingsView() }
            row("Settings Backup", "icloud") { SettingsBackupView() }
        }

        // What everything does, and the logic behind it. Its own section at
        // the foot of the list: it is not a setting, and it is read when
        // something is unclear rather than when something is being changed.
        Section {
            row("Help", "questionmark.circle") { HelpView() }
        }
    }

    private func row(
        _ title: String,
        _ symbol: String,
        @ViewBuilder destination: @escaping () -> some View
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.accentIcon)
        }
    }

    /// A failed connection must be visible from here, or moving the server
    /// sections down a level would hide the one thing worth noticing.
    @ViewBuilder
    private var connectionIndicator: some View {
        switch app.connection {
        case .idle:
            EmptyView()
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected(let info):
            // Body size, like the row it sits in: this names the server you
            // are on, which is the row's answer, not a footnote to it. Still
            // secondary in colour, the way a value reads beside its label.
            Text(info.productName ?? "Connected")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Connection failed")
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsEntry.results(for: query)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(results) { entry in
                    SettingsSearchResultLink(entry: entry)
                }
            }
        }
    }

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
