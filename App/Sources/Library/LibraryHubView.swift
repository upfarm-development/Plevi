import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// Browse hub: the ways into the library, plus a summary of what's indexed.
struct LibraryHubView: View {
    /// Owned by `RootView`; see `HomeView.path`.
    @Binding var path: NavigationPath

    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: LibraryDestination.artists) {
                        Label("Artists", systemImage: "music.mic")
                    }
                    NavigationLink(value: AlbumCollection(
                        title: "Albums",
                        filter: .alphabeticalByName,
                        allowsSorting: true
                    )) {
                        Label("Albums", systemImage: "square.stack")
                    }
                    NavigationLink(value: LibraryDestination.songs) {
                        Label("Songs", systemImage: "music.note")
                    }
                    if app.provider?.capabilities.contains(.collections) == true {
                        // Two rows rather than one list with the kind said on each row: a library
                        // might hold plenty of one and none of the other, and there is no reason to
                        // scroll past a screenful of album collections looking for the one artist
                        // collection at the end.
                        NavigationLink(value: LibraryDestination.artistCollections) {
                            Label("Artist Collections", systemImage: "rectangle.stack.person.crop")
                        }
                        NavigationLink(value: LibraryDestination.albumCollections) {
                            Label("Album Collections", systemImage: "rectangle.stack")
                        }
                    }
                    // Two ways in rather than one. A genre reaches records
                    // and it reaches the people who made them, and which of
                    // those you are after is not something one row can ask.
                    NavigationLink(value: LibraryDestination.genres) {
                        Label("Album Genres", systemImage: "guitars")
                    }
                    NavigationLink(value: LibraryDestination.artistGenres) {
                        Label("Artist Genres", systemImage: "music.mic")
                    }
                    NavigationLink(value: LibraryDestination.decades) {
                        Label("Decades", systemImage: "calendar")
                    }
                    if !app.settings.showsPlaylistsTab {
                        NavigationLink(value: LibraryDestination.playlists) {
                            Label("Playlists", systemImage: "music.note.list")
                        }
                    }
                }

                Section {
                    NavigationLink(value: AlbumCollection(title: "Favourites", filter: .favorites)) {
                        Label("Favourite Albums", systemImage: "heart")
                    }
                    NavigationLink(value: AlbumCollection(title: "Just Added", filter: .recentlyAdded)) {
                        Label("Just Added", systemImage: "clock")
                    }
                    NavigationLink(value: AlbumCollection(title: "Most Played", filter: .mostPlayed)) {
                        Label("Most Played", systemImage: "chart.bar")
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryDestination.self) { destination in
                switch destination {
                case .artists:
                    ArtistsListView(
                        cache: app.artistList,
                        library: app.libraryIndex?.server,
                        version: app.libraryVersion,
                        offline: app.isOffline
                    )
                    // Keyed by library: these keep their rows in @State, so a page still mounted
                    // when the library changes would go on showing the last one's.
                    .id(app.libraryIndex?.server)
                case .songs:
                    SongsListView(
                        cache: app.songList,
                        library: app.libraryIndex?.server,
                        version: app.libraryVersion,
                        offline: app.isOffline
                    )
                    .id(app.libraryIndex?.server)
                case .artistCollections: CollectionsView(kind: .artists)
                case .albumCollections: CollectionsView(kind: .albums)
                case .genres: GenresView()
                case .artistGenres: ArtistGenresView()
                case .decades: DecadesView()
                case .playlists: PlaylistsView()
                }
            }
            .navigationDestination(for: AlbumCollection.self) { collection in
                AlbumCollectionView(
                    collection: collection,
                    cache: app.albumList,
                    library: app.libraryIndex?.server,
                    version: app.libraryVersion,
                    offline: app.isOffline
                )
                .id(app.libraryIndex?.server)
            }
            .navigationDestination(for: ArtistGenre.self) { ArtistGenreView(genre: $0) }
            .navigationDestination(for: MediaCollection.self) { collection in
                switch collection.kind {
                case .albums: CollectionAlbumsView(collection: collection)
                case .artists: ArtistCollectionView(collection: collection)
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: SimilarArtistsRoute.self) { SimilarArtistsListView(route: $0) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        }
    }
}

enum LibraryDestination: Hashable {
    case artists
    case songs
    case artistCollections
    case albumCollections
    case artistGenres
    case genres
    case decades
    case playlists
}

/// The full artist list, index-backed.
struct ArtistsListView: View {
    @Environment(AppModel.self) private var app

    /// The half of the cache key that belongs to the world rather than to
    /// this screen — see `SongsListView`'s identical fields for why they
    /// are handed in rather than read from the environment.
    private let cache: ArtistListCache
    private let library: ServerID?
    private let version: Int
    private let offline: Bool

    @State private var artists: [Artist]
    @State private var runs: AlphabetIndex.SectionRuns?
    @State private var loadError: String?
    @State private var filter: LibraryFilter
    @State private var editingFilter = false
    @State private var order: LibraryIndex.ArtistOrder
    @State private var direction: LibraryIndex.SortDirection
    /// Whether what is already on screen came from the cache, so the first
    /// reload can be skipped.
    @State private var isSeeded: Bool

    init(cache: ArtistListCache, library: ServerID?, version: Int, offline: Bool) {
        self.cache = cache
        self.library = library
        self.version = version
        self.offline = offline
        let held = cache.anything().flatMap { entry -> ArtistListCache.Entry? in
            guard let library,
                  entry.key.library == library,
                  entry.key.version == version,
                  entry.key.offline == offline
            else { return nil }
            return entry
        }
        _artists = State(initialValue: held?.artists ?? [])
        _runs = State(initialValue: held?.runs)
        _filter = State(initialValue: held?.key.filter ?? LibraryFilter(subject: .artists))
        _order = State(initialValue: held?.key.order ?? .alphabetical)
        _direction = State(initialValue: held?.key.direction ?? .forward)
        _isSeeded = State(initialValue: held != nil)
    }

    var body: some View {
        Group {
            if artists.isEmpty {
                ContentUnavailableView(
                    "No artists",
                    systemImage: "music.mic",
                    description: Text(
                        loadError
                        ?? (filter.isEmpty
                            ? "Your library will appear once it has synced."
                            : "No artists match the filter.")
                    )
                )
            } else {
                // No runs means the list is not alphabetical (or is too short for a bar): it must
                // be drawn in the order it arrived in, not re-filed A to Z by `IndexedList` — so
                // the bar is put out of reach — and the sort is part of the key, or a change from…
                IndexedList(
                    items: artists, title: \.name,
                    minimumForIndex: runs == nil ? .max : 20,
                    groupingKey: "\(filter)|\(order.rawValue)|\(direction.rawValue)",
                    runs: runs
                ) { artist in
                    row(for: artist)
                }
            }
        }
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingFilter = true
                } label: {
                    Image(systemName: filter.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel(filter.isEmpty ? "Filter" : "Filter, on")
            }
            ToolbarItem(placement: .topBarTrailing) {
                SortMenu(order: $order, direction: $direction)
            }
            ToolbarItem(placement: .topBarTrailing) {
                KeepListActions(
                    subject: .artists, filter: filter,
                    songOrder: nil, albumOrder: nil, direction: direction
                )
            }
        }
        .sheet(isPresented: $editingFilter) {
            LibraryFilterSheet(subject: .artists, filter: filter) { filter = $0 }
        }
        .task(
            id: "\(app.libraryVersion)|\(app.isOffline)|\(filter)|\(order.rawValue)|\(direction.rawValue)"
        ) { await load() }
    }

    private func row(for artist: Artist) -> some View {
        NavigationLink(value: artist) {
            HStack(spacing: 12) {
                ArtworkView(
                    artwork: artist.artwork,
                    size: CompactList.thumbnailSize,
                    cornerRadius: CompactList.thumbnailSize / 2,
                    placeholder: .artist
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(artist.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let count = artist.albumCount {
                        Text(count.counted("album"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .artistContextMenu(artist, actions: MediaActions(app: app))
        // Warm the artist page while the row is on screen, so opening it
        // paints complete instead of filling in section by section.
        .task(id: artist.id) { await app.artistPrefetcher.prefetchWhenVisible(artist) }
    }

    private func load() async {
        // Already on screen, and still true: the task fires once when the
        // screen appears whether or not anything needs doing.
        if isSeeded {
            isSeeded = false
            return
        }
        let asked = filter
        let sortedBy = order
        let way = direction
        let offlineNow = app.isOffline

        if let index = app.libraryIndex {
            // Detached for where it runs, cancelled by hand for when it stops — see
            // `SongsListView.load()`, which this mirrors for the same two reasons: a `nonisolated`
            // function only leaves the main actor by default, and a detached task has no parent to…
            let work = Task.detached(priority: .userInitiated) {
                Self.read(
                    index, filter: asked, order: sortedBy,
                    direction: way, offline: offlineNow
                )
            }
            let (rows, filed) = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, asked == filter, sortedBy == order,
                  way == direction, offlineNow == app.isOffline
            else { return }
            // A filter that legitimately matches nothing says so.
            if !asked.isEmpty || !rows.isEmpty || offlineNow {
                artists = rows
                runs = filed
                if let library = app.libraryIndex?.server {
                    cache.store(ArtistListCache.Entry(
                        key: ArtistListCache.Key(
                            library: library, version: app.libraryVersion,
                            offline: offlineNow, filter: asked,
                            order: sortedBy, direction: way
                        ),
                        artists: rows,
                        runs: filed
                    ))
                }
                return
            }
        }

        guard let provider = app.provider else { return }
        do {
            let fetched = try await provider.artists()
            guard asked == filter, offlineNow == app.isOffline else { return }
            (artists, runs) = Self.filed(fetched)
        } catch {
            loadError = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
        }
    }

    nonisolated private static func read(
        _ index: LibraryIndex,
        filter: LibraryFilter,
        order: LibraryIndex.ArtistOrder,
        direction: LibraryIndex.SortDirection,
        offline: Bool
    ) -> ([Artist], AlphabetIndex.SectionRuns?) {
        // A filter is answered from the index alone; the server has no idea
        // what rules were written here.
        let rows = !filter.isEmpty
            ? (try? index.artists(
                matching: filter, order: order, direction: direction, downloadedOnly: offline
            )) ?? []
            : (try? index.artists(
                downloadedOnly: offline, order: order, direction: direction
            )) ?? []
        guard !Task.isCancelled else { return ([], nil) }
        // The jump bar belongs to the alphabet and to nothing else: sorted by
        // play date, or backwards, the letters down the right would point at
        // the right rows under the wrong headings. It stands down instead.
        guard order.isAlphabetical, direction == .forward else { return (rows, nil) }
        return filed(rows)
    }

    /// Below this a jump bar points at almost the whole list — not worth
    /// having. Matches `IndexedList`'s own default.
    private static let minimumForIndex = 20

    private static func filed(_ artists: [Artist]) -> ([Artist], AlphabetIndex.SectionRuns?) {
        guard artists.count >= minimumForIndex else { return (artists, nil) }
        let (ordered, runs) = AlphabetIndex.filed(artists) { $0.name }
        return (ordered, runs)
    }
}

struct GenresView: View {
    @Environment(AppModel.self) private var app
    @State private var fetched = FetchedList<Genre>()

    var body: some View {
        IndexedList(items: fetched.items ?? [], title: \.name) { genre in
            NavigationLink(value: AlbumCollection(title: genre.name, filter: .genre(genre.name))) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(genre.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let count = genre.trackCount {
                        Text(count.counted("song"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Album Genres")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if fetched.isFailed, let failure = fetched.failure {
                FetchFailureView(message: failure) { Task { await load() } }
            } else if fetched.isEmptyAnswer {
                ContentUnavailableView("No genres", systemImage: "guitars")
            }
        }
        .task(id: "\(app.libraryVersion)|\(app.connectionKey)") { await load() }
    }

    /// The library's own index where it has genres; the server's list
    /// otherwise. A failed server request keeps whatever list is on show.
    private func load() async {
        if let index = app.libraryIndex, let indexed = try? index.genres(), !indexed.isEmpty {
            fetched.apply(.answered(indexed))
        } else if let provider = app.provider {
            fetched.apply(await FetchOutcome.attempt { try await provider.genres() })
        } else {
            // An empty index and nobody to ask: there is nothing to list.
            fetched.apply(.answered([]))
        }
    }
}

struct DecadesView: View {
    @Environment(AppModel.self) private var app
    @State private var decades: [Int] = []

    var body: some View {
        List(decades, id: \.self) { decade in
            NavigationLink(value: AlbumCollection(
                title: "\(decade)s",
                filter: .yearRange(from: decade, to: decade + 9)
            )) {
                Text("\(String(decade))s")
            }
        }
        .listStyle(.plain)
        .navigationTitle("Decades")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if decades.isEmpty {
                ContentUnavailableView(
                    "No decades",
                    systemImage: "calendar",
                    description: Text("Albums need release years for this view.")
                )
            }
        }
        .task(id: app.libraryVersion) {
            decades = (try? app.libraryIndex?.decades()) ?? []
        }
    }
}


/// Genres as a way into artists.
struct ArtistGenresView: View {
    @Environment(AppModel.self) private var app
    @State private var fetched = FetchedList<Genre>()

    var body: some View {
        IndexedList(items: fetched.items ?? [], title: \.name) { genre in
            NavigationLink(value: ArtistGenre(genre: genre)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(genre.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // A blank second line where there is no count, so these
                    // rows stand as tall as the album genres' do rather than
                    // collapsing to one line and stepping differently.
                    Text(genre.artistCount.map { $0.counted("artist") } ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Artist Genres")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if fetched.items == nil, app.isOffline {
                ContentUnavailableView(
                    "No genres",
                    systemImage: "music.mic",
                    description: Text("The server files these, so they need a connection.")
                )
            } else if fetched.isFailed, let failure = fetched.failure {
                FetchFailureView(message: failure) { Task { await load() } }
            } else if fetched.isEmptyAnswer {
                ContentUnavailableView(
                    "No genres",
                    systemImage: "music.mic",
                    description: Text("This server files no artists under a genre.")
                )
            }
        }
        .task(id: "\(app.libraryVersion)|\(app.connectionKey)") { await load() }
    }

    /// A failed or called-off request keeps the list already on show; only
    /// an answer replaces it.
    private func load() async {
        guard let provider = app.provider else {
            fetched.apply(.failed(message: "Not connected to a server."))
            return
        }
        guard provider.capabilities.contains(.genreBrowsing) else {
            fetched.apply(.answered([]))
            return
        }
        // Not while offline: there is nobody to ask, and the screen says so.
        guard !app.isOffline else { return }
        fetched.beginRetry()
        switch await FetchOutcome.attempt({ try await provider.artistGenres() }) {
        case .cancelled:
            return
        case .failed(let message):
            fetched.apply(.failed(message: message))
            return
        case .answered(let listed):
            // The server names the genres its artists are filed under but does not say how many are
            // in each, so the count comes from the library's own index, matched by name.
            let counts = Dictionary(
                ((try? app.libraryIndex?.genres()) ?? [])
                    .compactMap { genre in genre.artistCount.map { (genre.name.lowercased(), $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            fetched.apply(.answered(listed.map { genre in
                var out = genre
                out.artistCount = counts[genre.name.lowercased()]
                return out
            }))
        }
    }
}

/// A genre being browsed for its artists, so the destination is distinct
/// from the same genre browsed for its records.
struct ArtistGenre: Hashable {
    let genre: Genre
    var name: String { genre.name }
}

struct ArtistGenreView: View {
    let genre: ArtistGenre

    @Environment(AppModel.self) private var app
    @State private var fetched = FetchedList<Artist>()

    var body: some View {
        IndexedList(items: fetched.items ?? [], title: \.name) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    ArtworkView(
                        artwork: artist.artwork,
                        size: CompactList.thumbnailSize,
                        cornerRadius: CompactList.thumbnailSize / 2,
                        placeholder: .artist
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(artist.name).lineLimit(1)
                        if let count = artist.albumCount {
                            Text(count.counted("album"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .artistContextMenu(artist, actions: MediaActions(app: app))
            .task(id: artist.id) { await app.artistPrefetcher.prefetchWhenVisible(artist) }
        }
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if fetched.isLoading {
                ProgressView()
            } else if fetched.isFailed, let failure = fetched.failure {
                FetchFailureView(message: failure) { Task { await load() } }
            } else if fetched.isEmptyAnswer {
                ContentUnavailableView("No artists", systemImage: "music.mic")
            }
        }
        .task(id: "\(genre.name)|\(app.connectionKey)") { await load() }
    }

    private func load() async {
        guard let provider = app.provider else {
            fetched.apply(.failed(message: "Not connected to a server."))
            return
        }
        fetched.beginRetry()
        fetched.apply(await FetchOutcome.attempt { try await provider.artists(inGenre: genre.genre) })
    }
}
