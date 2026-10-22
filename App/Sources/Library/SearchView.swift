import SwiftUI
import PleviDomain

struct SearchView: View {
    /// Owned by `RootView`, which declares the field — see the `searchable`
    /// on the search tab, and `tabBarOwnsTheField` below for where the
    /// system then decides to draw it.
    @Binding var query: String
    /// Owned by `RootView`; see `HomeView.path`.
    @Binding var path: NavigationPath

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var results = SearchResults()
    @State private var searching = false
    @State private var recents = RecentSearches()
    /// Every playlist the server holds, fetched once and matched against locally — there is no
    /// playlist search endpoint on either backend, and this is the same list the Playlists tab
    /// already fetches, small enough that a name match over the whole…
    @State private var allPlaylists: [Playlist] = []
    /// Which library the held list belongs to, and which version of it was
    /// fetched — so it can be replaced when it goes stale without being
    /// thrown away first. See `refreshPlaylists`.
    @State private var playlistsServer: ServerID?
    @State private var playlistsVersion: Int?

    private static let thumbnailSize = CompactList.thumbnailSize
    private static let rowInsets = CompactList.rowInsets

    /// How many of each kind the results page shows before the rest go behind a chevron.
    static let sectionCap = 10
    /// Asked of the index and of the server. Sixty is enough that "All 60"
    /// is almost always the true number rather than a floor, and small
    /// enough that the ranking pass behind it stays instant.
    private static let fetchLimit = 60

    /// Everything of one kind that a search found, for the chevron to open.
    struct AllResults: Hashable {
        let kind: SearchResultKind
        let query: String
    }

    /// The heading, with a way to the rest of them where there is a rest.
    private func header(_ kind: SearchResultKind, total: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(kind.title)
            Spacer(minLength: 8)
            if total > Self.sectionCap {
                NavigationLink(value: AllResults(kind: kind, query: query)) {
                    HStack(spacing: 2) {
                        // The number only where it is the true one.
                        Text(total < Self.fetchLimit ? "All \(total)" : "More")
                        Image(systemName: "chevron.right")
                    }
                }
            }
        }
    }

    /// Whether the tab bar is the thing drawing the search field.
    private var tabBarOwnsTheField: Bool { horizontalSizeClass == .compact }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    // The title in the list is the stand-in for the bar that
                    // is hidden below; where the bar is showing it would be
                    // the second "Search" on the screen.
                    if tabBarOwnsTheField {
                        Text("Search")
                            .font(.largeTitle.bold())
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    }
                    recentSection
                }
                // Whichever order Settings → Search has them in — see `SearchResultKind`.
                ForEach(app.settings.searchResultOrder) { kind in
                    section(for: kind)
                }
            }
            .listStyle(.plain)
            // A row is as tall as its thumbnail plus the insets above; the
            // default minimum would hold it taller than that.
            .environment(\.defaultMinListRowHeight, 0)
            .navigationTitle("Search")
            // Hidden only where the tab bar has taken the field, and that is the whole of the
            // condition — see `tabBarOwnsTheField`.
            .toolbar(tabBarOwnsTheField ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: SimilarArtistsRoute.self) { SimilarArtistsListView(route: $0) }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: AlbumCollection.self) { collection in
                AlbumCollectionView(
                    collection: collection,
                    cache: app.albumList,
                    library: app.libraryIndex?.server,
                    version: app.libraryVersion,
                    offline: app.isOffline
                )
            }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: AllResults.self) { all in
                SearchAllView(kind: all.kind, query: all.query, results: results)
            }
            // Keyed on the library version rather than a plain `.task`, so switching servers
            // refetches instead of keeping the old server's playlists around under the new one's
            // name.
            .task(id: "\(app.libraryVersion)|\(app.libraryIndex?.server.rawValue.uuidString ?? "")") {
                await refreshPlaylists()
            }
            // Playlists are the one kind of result that does not come from the index, so a list
            // that lands after a search has to be folded into what is already on screen.
            .onChange(of: allPlaylists) {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                results.playlists = matchingPlaylists(trimmed)
            }
            .overlay {
                if query.isEmpty {
                    // With recent searches listed there is already something
                    // on the page; "No Results" belongs to a real query only.
                    if recents.queries.isEmpty {
                        ContentUnavailableView(
                            "Search your library",
                            systemImage: "magnifyingglass",
                            description: Text("Artists, playlists, albums, and songs — instant once your library has synced.")
                        )
                    }
                } else if searching && results.isEmpty {
                    ProgressView()
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            // Everything the search reads, not only what was typed.
            .task(id: "\(query)|\(app.libraryVersion)|\(app.libraryIndex?.server.rawValue.uuidString ?? "")|\(app.isOffline)|\(app.settings.searchesAllQuickLibraries)") { await search() }
        }
        // Recorded once typing settles, so a search-as-you-type query leaves one entry rather than
        // one per keystroke.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            recents.record(query)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recents.queries.isEmpty {
            Section {
                ForEach(recents.queries, id: \.self) { recent in
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: Self.thumbnailSize)
                        Text(recent)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            recents.remove(recent)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(recent) from recent searches")
                    }
                    // The row is not itself a button: a button inside another
                    // button's label never receives its taps.
                    .contentShape(Rectangle())
                    .onTapGesture { query = recent }
                    .listRowInsets(Self.rowInsets)
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") { recents.clear() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
    }

    /// Which library a result came from, for the ones that are not from the
    /// open one — see `LibraryBadge`.
    private var siblingTitles: [ServerID: String] { app.siblingLibraryTitles }

    /// One section of results, whichever kind it is.
    @ViewBuilder
    private func section(for kind: SearchResultKind) -> some View {
        switch kind {
        case .artists:
            if !results.artists.isEmpty {
                Section {
                    ForEach(results.artists.prefix(Self.sectionCap)) { artist in
                        NavigationLink(value: artist) {
                            HStack(spacing: 12) {
                                ArtworkView(
                                    artwork: artist.artwork,
                                    size: Self.thumbnailSize,
                                    cornerRadius: Self.thumbnailSize / 2,
                                    placeholder: .artist
                                )
                                // One line, as in the artists list: a result
                                // row is for picking, not reading.
                                Text(artist.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                LibraryBadge(titles: siblingTitles, server: artist.id.server)
                            }
                        }
                        .listRowInsets(Self.rowInsets)
                        .artistContextMenu(artist, actions: MediaActions(app: app))
                    }
                } header: {
                    header(.artists, total: results.artists.count)
                }
            }
        case .albums:
            if !results.albums.isEmpty {
                Section {
                    ForEach(results.albums.prefix(Self.sectionCap)) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                ArtworkView(artwork: album.artwork, size: Self.thumbnailSize)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(album.name)
                                        .lineLimit(1)
                                    Text(album.artistName ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                LibraryBadge(titles: siblingTitles, server: album.id.server)
                            }
                        }
                        .listRowInsets(Self.rowInsets)
                        .albumContextMenu(album, actions: MediaActions(app: app))
                    }
                } header: {
                    header(.albums, total: results.albums.count)
                }
            }
        case .playlists:
            if !results.playlists.isEmpty {
                Section {
                    ForEach(results.playlists.prefix(Self.sectionCap)) { playlist in
                        NavigationLink(value: playlist) {
                            HStack(spacing: 12) {
                                ArtworkView(artwork: playlist.artwork, size: Self.thumbnailSize, cornerRadius: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(playlist.name)
                                        .lineLimit(1)
                                    if let count = playlist.trackCount {
                                        Text("\(count) song\(count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .listRowInsets(Self.rowInsets)
                    }
                } header: {
                    header(.playlists, total: results.playlists.count)
                }
            }
        case .songs:
            if !results.tracks.isEmpty {
                Section {
                    ForEach(
                        Array(results.tracks.prefix(Self.sectionCap).enumerated()),
                        id: \.element.id
                    ) { index, track in
                        Button {
                            app.activePlayer.play(results.tracks, startingAt: index, from: .songs)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(artwork: track.artwork, size: Self.thumbnailSize)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title)
                                        .lineLimit(1)
                                    Text(track.artistName ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                LibraryBadge(titles: siblingTitles, server: track.id.server)
                                if app.activePlayer.currentTrack?.id == track.id {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(Self.rowInsets)
                        .trackContextMenu(
                            track,
                            actions: MediaActions(app: app),
                            onGoToAlbum: track.albumID.map { id in
                                { app.requestNavigation(.album(id, name: track.albumName)) }
                            },
                            onGoToArtist: track.artistID.map { id in
                                { app.requestNavigation(.artist(id, name: track.artistName)) }
                            }
                        )
                    }
                } header: {
                    header(.songs, total: results.tracks.count)
                }
            }
        }
    }

    /// The same list the Playlists tab holds, kept here so a keystroke only filters a list already
    /// in memory rather than fetching one.
    private func refreshPlaylists() async {
        let server = app.libraryIndex?.server
        // A different library is the one case where what is held is worse
        // than nothing: those are another server's playlists under this
        // one's name.
        if playlistsServer != server {
            allPlaylists = []
            playlistsServer = server
            playlistsVersion = nil
        }
        guard playlistsVersion != app.libraryVersion,
              !app.isOffline,
              let provider = app.provider,
              let fetched = try? await provider.playlists()
        else { return }
        allPlaylists = fetched
        playlistsVersion = app.libraryVersion
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = SearchResults()
            return
        }

        // Local index: instant search-as-you-type, no server round trip.
        if let index = app.libraryIndex,
           let stats = try? index.stats(), !stats.isEmpty,
           var found = try? index.search(
               trimmed, limit: Self.fetchLimit, downloadedOnly: app.isOffline
           ) {
            // After the open library's own, so what is on screen is still ranked the way it always
            // was and the other libraries only add to it.
            if app.settings.searchesAllQuickLibraries {
                let others = await app.searchOtherQuickLibraries(trimmed, limit: Self.fetchLimit)
                guard !Task.isCancelled else { return }
                found.artists += others.artists
                found.albums += others.albums
                found.tracks += others.tracks
            }
            results = found
            results.playlists = matchingPlaylists(trimmed)
            return
        }

        // First launch before the sync lands: server search, debounced.
        guard let provider = app.provider else {
            results = SearchResults()
            return
        }
        searching = true
        defer { searching = false }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        if let found = try? await provider.search(trimmed, limit: Self.fetchLimit) {
            results = found
            results.playlists = matchingPlaylists(trimmed)
        }
    }

    /// Offline, `allPlaylists` is simply whatever was last fetched — `loadPlaylistsIfNeeded` does
    /// not fetch again — so this needs no separate offline guard of its own.
    private func matchingPlaylists(_ trimmed: String) -> [Playlist] {
        PlaylistNameSearch.matching(trimmed, in: allPlaylists)
    }
}

/// Names the library a search result belongs to, when it is not the one that is open — "Kids"
/// beside a song found while the main library is showing.
struct LibraryBadge: View {
    let titles: [ServerID: String]
    let server: ServerID

    var body: some View {
        if let title = titles[server] {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("From \(title)")
        }
    }
}

/// The last few things searched for, kept between launches.
@MainActor
@Observable
final class RecentSearches {
    private static let key = "search.recent"
    private static let limit = 5

    private let defaults: UserDefaults
    private(set) var queries: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        queries = defaults.stringArray(forKey: Self.key) ?? []
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return }
        let folded = trimmed.lowercased()
        var updated = queries.filter { existing in
            !folded.hasPrefix(existing.lowercased())
        }
        updated.insert(trimmed, at: 0)
        write(Array(updated.prefix(Self.limit)))
    }

    func remove(_ query: String) {
        write(queries.filter { $0 != query })
    }

    func clear() {
        write([])
    }

    private func write(_ newValue: [String]) {
        queries = newValue
        if newValue.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(newValue, forKey: Self.key)
        }
    }
}
