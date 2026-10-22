import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// A named set of albums to show as a grid — a shelf's "See All", a genre, a
/// decade, or the whole albums list.
struct AlbumCollection: Hashable {
    var title: String
    var filter: AlbumFilter
    /// Sorting is offered only where it makes sense (the plain album list),
    /// not for inherently ordered collections like "Recently Added".
    var allowsSorting = false
    /// A set the caller already has, when the collection is something worked out elsewhere —
    /// records that sound alike, or an artist's guest spots — rather than a question the library
    /// index can answer.
    var albums: [Album]?
    /// Grid or rows. A "See All" should look like the shelf it came from —
    /// arriving at a wall of sleeves from a list of rows is a different page,
    /// not more of the same one.
    var layout: Layout = .grid
    /// Whether `layout` is the answer or merely a starting point.
    var pinsLayout = false
    /// Caps how many albums this page ever asks for, on top of whatever `filter` would otherwise
    /// return every match of.
    var resultLimit: Int?
    /// Rows name the artist, for a shelf drawn from across the library.
    var showsArtist = false
    /// The picture the page it came from was tinted by. A "See All" opened
    /// from a tinted page keeps that colour: stepping from a record's own
    /// page onto a white one reads as leaving the record behind.
    var artwork: ArtworkID?

    enum Layout: Hashable {
        case grid
        case list
    }

    init(title: String, filter: AlbumFilter = .alphabeticalByName, allowsSorting: Bool = false) {
        self.title = title
        self.filter = filter
        self.allowsSorting = allowsSorting
    }

    init(
        title: String,
        albums: [Album],
        layout: Layout = .grid,
        pinsLayout: Bool = false,
        showsArtist: Bool = false,
        artwork: ArtworkID? = nil
    ) {
        self.title = title
        self.filter = .alphabeticalByName
        self.albums = albums
        self.layout = layout
        self.pinsLayout = pinsLayout
        self.showsArtist = showsArtist
        self.artwork = artwork
    }
}

struct AlbumCollectionView: View {
    let collection: AlbumCollection
    /// Anything the caller wants at the top of the list's own menu — a
    /// collection puts Play, Shuffle and Pin there, since with sort, filter
    /// and shape already folded in there is nowhere else left to put them.
    var extraMenu: () -> AnyView = { AnyView(EmptyView()) }

    @Environment(AppModel.self) private var app

    /// The half of the cache key that belongs to the world rather than to this screen, handed in
    /// rather than read from the environment — see `SongsListView`'s identical fields.
    private let cache: AlbumListCache
    private let seedLibrary: ServerID?
    private let seedVersion: Int
    private let seedOffline: Bool

    /// In bar order when there is a bar at all — `nil` means this page has
    /// none: sorted by date, given outright by the caller, or too short to
    /// be worth jumping around in.
    @State private var albums: [Album]
    @State private var runs: AlphabetIndex.SectionRuns?
    @State private var sort: AlbumSort
    @State private var direction: LibraryIndex.SortDirection = .forward
    @State private var loading = false
    @State private var palette = PaletteLoader()
    @State private var filter: LibraryFilter
    @State private var editingFilter = false
    /// Whether what is already on screen came from the cache, or was given
    /// outright, so the first reload can be skipped.
    @State private var isSeeded: Bool

    init(
        collection: AlbumCollection,
        extraMenu: @escaping () -> AnyView = { AnyView(EmptyView()) },
        cache: AlbumListCache,
        library: ServerID?,
        version: Int,
        offline: Bool
    ) {
        self.collection = collection
        self.extraMenu = extraMenu
        self.cache = cache
        self.seedLibrary = library
        self.seedVersion = version
        self.seedOffline = offline

        if let given = collection.albums {
            _albums = State(initialValue: given)
            _runs = State(initialValue: nil)
            _sort = State(initialValue: .name)
            _filter = State(initialValue: LibraryFilter(subject: .albums))
            _isSeeded = State(initialValue: true)
            return
        }

        // Whatever is held for this exact page — whichever sort it was left on, since a lookup by
        // page alone finds an entry regardless of `query`.
        let page = AlbumListCache.Page(
            filter: collection.filter,
            limit: collection.resultLimit ?? Self.indexLimit
        )
        let held = library.flatMap {
            cache.entry(forPage: page, library: $0, version: version, offline: offline)
        }
        _albums = State(initialValue: held?.albums ?? [])
        _runs = State(initialValue: held?.runs)
        _sort = State(initialValue: held.flatMap { AlbumSort(filter: $0.key.query) } ?? .name)
        _direction = State(initialValue: held?.key.direction ?? .forward)
        _filter = State(initialValue: held?.key.filter ?? LibraryFilter(subject: .albums))
        _isSeeded = State(initialValue: held != nil)
    }

    /// Tinted only when the caller said which picture to take the colour
    /// from; the library's own album list stays as it was.
    private var tinted: Bool { collection.artwork != nil }

    private var style: PageStyle { app.settings.pageStyle }

    private var colors: ArtworkPalette {
        tinted ? .forPage(style, artwork: palette.palette) : .neutral
    }

    enum AlbumSort: String, CaseIterable, Identifiable {
        case name = "Name"
        case artist = "Artist"
        case recentlyAdded = "Date Added"
        case recentlyReleased = "Year"
        case lastPlayed = "Date Played"
        case mostPlayed = "Play Count"
        case highestRated = "Rating"

        var id: String { rawValue }

        var label: String { rawValue }

        var scale: LibraryIndex.SortScale {
            switch self {
            case .name, .artist: .alphabetical
            case .recentlyAdded, .recentlyReleased, .lastPlayed: .recency
            case .mostPlayed, .highestRated: .quantity
            }
        }

        var filter: AlbumFilter {
            switch self {
            case .name: .alphabeticalByName
            case .artist: .alphabeticalByArtist
            case .recentlyAdded: .recentlyAdded
            case .recentlyReleased: .recentlyReleased
            case .lastPlayed: .recentlyPlayed
            case .mostPlayed: .mostPlayed
            case .highestRated: .highestRated
            }
        }

        /// The inverse of `filter` above, for restoring a sort from what a cached page was last
        /// read under.
        init?(filter: AlbumFilter) {
            switch filter {
            case .alphabeticalByName: self = .name
            case .alphabeticalByArtist: self = .artist
            case .recentlyAdded: self = .recentlyAdded
            case .recentlyReleased: self = .recentlyReleased
            case .recentlyPlayed: self = .lastPlayed
            case .mostPlayed: self = .mostPlayed
            case .highestRated: self = .highestRated
            default: return nil
            }
        }
    }

    private static let gridSpacing: CGFloat = 10
    /// The jump bar's strip down the right, which the cards must not run
    /// under.
    private static let indexBarWidth: CGFloat = 18
    /// Below this a jump bar points at almost the whole list — not worth
    /// having. Matches `IndexedList`'s own default, so a page just under it
    /// behaves the same whichever component actually draws it.
    private static let minimumForIndex = 20

    /// Whether — and how — this page is filed for a jump bar.
    private enum Filing: Sendable {
        case none, byName, byArtist
    }

    private var filing: Filing {
        guard collection.albums == nil else { return .none }
        // A–Z down the right is a promise about the order on screen. Running
        // the list backwards keeps the rows right and makes the letters
        // wrong, so the bar stands down rather than misfiling every record.
        guard direction == .forward else { return .none }
        return switch collection.allowsSorting ? sort.filter : collection.filter {
        case .alphabeticalByName: .byName
        case .alphabeticalByArtist: .byArtist
        default: .none
        }
    }

    var body: some View {
        Group {
            if loading && albums.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                ContentUnavailableView(
                    "No albums",
                    systemImage: "square.stack",
                    description: Text("Nothing in your library matches this yet.")
                )
            } else if layout == .list {
                if let runs {
                    indexedRows(runs)
                } else {
                    rows
                }
            } else if let runs {
                indexedGrid(runs)
            } else {
                ScrollView {
                    grid(albums)
                        .padding()
                }
                .scrollIndicators(.hidden)
            }
        }
        .background {
            if tinted {
                PageBackground(style: style, artwork: palette.palette)
            }
        }
        .toolbarColorScheme(tinted ? colors.chromeScheme : nil, for: .navigationBar)
        .toolbarBackground(tinted ? .hidden : .automatic, for: .navigationBar)
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingFilter) {
            LibraryFilterSheet(
                subject: .albums, filter: filter,
                within: collection.albums?.map(\.id),
                page: collection.albums == nil
                    ? (collection.allowsSorting ? sort.filter : collection.filter)
                    : nil
            ) { filter = $0 }
        }
        .toolbar {
            // One menu rather than four buttons.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    extraMenu()

                    if collection.allowsSorting {
                        Section {
                            SortMenuContent(order: $sort, direction: $direction)
                        }
                    }

                    Section {
                        if !collection.pinsLayout {
                            Button {
                                @Bindable var settings = app.settings
                                settings.seeAllLayout = layout == .list ? .grid : .list
                            } label: {
                                Label(
                                    layout == .list ? "Show as Grid" : "Show as List",
                                    systemImage: layout == .list ? "square.grid.2x2" : "list.bullet"
                                )
                            }
                        }
                        Button {
                            editingFilter = true
                        } label: {
                            Label(
                                filter.isEmpty ? "Filter…" : "Filter (on)…",
                                systemImage: filter.isEmpty
                                    ? "line.3.horizontal.decrease.circle"
                                    : "line.3.horizontal.decrease.circle.fill"
                            )
                        }
                    }

                } label: {
                    Image(systemName: filter.isEmpty ? "ellipsis.circle" : "ellipsis.circle.fill")
                }
                .accessibilityLabel("List options")
            }
            // Its own button rather than a row inside the menu above.
            if collection.allowsSorting {
                ToolbarItem(placement: .topBarTrailing) {
                    KeepListActions(
                        subject: .albums, filter: filter,
                        songOrder: nil, albumOrder: sort.filter,
                        direction: direction
                    )
                }
            }
        }
        .task(id: loadKey) { await load() }
        // A caller that supplies its own records can supply a *different* list later — a collection
        // being re-sorted above this screen does exactly that.
        .onChange(of: collection.albums) { _, given in
            guard let given else { return }
            albums = given
        }
        .task(id: collection.artwork?.rawValue) {
            guard tinted else { return }
            await palette.load(artwork: collection.artwork, using: app.artwork)
        }
    }

    /// What this page is actually drawing.
    private var layout: AlbumCollection.Layout {
        collection.pinsLayout ? collection.layout : app.settings.seeAllLayout
    }

    /// Which page this is, for the cache — independent of how it is sorted
    /// right now. Constant for the life of this screen: `collection` is a
    /// `let`.
    private var page: AlbumListCache.Page {
        AlbumListCache.Page(filter: collection.filter, limit: collection.resultLimit ?? Self.indexLimit)
    }

    /// Everything one load depends on, as one value.
    private struct LoadKey: Equatable {
        var sort: AlbumSort
        var direction: LibraryIndex.SortDirection
        var filter: LibraryFilter
        var version: Int
        var offline: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(
            sort: sort, direction: direction, filter: filter,
            version: app.libraryVersion, offline: app.isOffline
        )
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(albums) { album in
                    row(for: album)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    /// Rows with the jump bar Artists and Songs already have — the same
    /// component, so the same fix: the filing is done once, where the rows
    /// are read, rather than on the thread drawing the screen.
    private func indexedRows(_ runs: AlphabetIndex.SectionRuns) -> some View {
        IndexedList(items: albums, title: filedTitle, groupingKey: groupingKey, runs: runs) { album in
            row(for: album)
        }
    }

    private var filedTitle: (Album) -> String {
        filing == .byArtist ? { $0.artistName ?? $0.displayName } : { $0.displayName }
    }

    /// `IndexedList` only actually consults this when it has to file rows itself, which never
    /// happens here — `runs` is always supplied already matching `albums`.
    private var groupingKey: String { "\(sort.rawValue)|\(direction.rawValue)|\(filter)" }

    private func row(for album: Album) -> some View {
        NavigationLink(value: album) {
            AlbumListRow(
                album: album,
                palette: colors,
                showsArtist: collection.showsArtist
            )
        }
        .buttonStyle(.plain)
        .albumContextMenu(album, actions: MediaActions(app: app))
    }

    private func grid(_ albums: [Album]) -> some View {
        MeasuredWidth { width in gridSection(albums, width: width) }
    }

    /// One page of cards at a known width — no measuring of its own, so it
    /// can be built freely inside a lazy container without paying for a
    /// `GeometryReader` per section.
    private func gridSection<C: RandomAccessCollection>(
        _ albums: C, width: CGFloat
    ) -> some View where C.Element == Album {
        // The full measured width, not width minus the index bar.
        let metrics = AlbumGridMetrics(
            availableWidth: width,
            columns: app.settings.albumColumns,
            spacing: Self.gridSpacing
        )
        return LazyVGrid(columns: metrics.gridItems, spacing: 16) {
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    AlbumCard(
                        album: album,
                        size: metrics.itemWidth,
                        palette: colors,
                        actions: MediaActions(app: app)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func indexedGrid(_ runs: AlphabetIndex.SectionRuns) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // One reader for the whole screen, not one per section.
                MeasuredWidth { width in
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(runs.ranges.indices, id: \.self) { j in
                            // No letter over each run — the jump bar is the way around, and lands
                            // on the section itself: a card is two lazy containers deep, and a
                            // `ScrollViewReader` can only find an id that has actually been laid
                            // out at least once, which a card…
                            Section {
                                gridSection(albums[runs.ranges[j]], width: width)
                            }
                            .id(runs.sections[j])
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.trailing, Self.indexBarWidth)
                .padding(.bottom)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .trailing) {
                SectionIndexBar(sections: runs.sections) { section in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(section, anchor: .top)
                    }
                }
            }
        }
    }

    private func load() async {
        // Already on screen, and still true: the task fires once when the
        // screen appears whether or not anything needs doing.
        if isSeeded {
            isSeeded = false
            return
        }
        if let given = collection.albums {
            // A collection is the server's own list, handed to this screen rather than queried.
            guard !filter.isEmpty, let index = app.libraryIndex else {
                albums = given
                runs = nil
                return
            }
            let asked = filter
            let ids = given.map(\.id)
            let offline = app.isOffline
            let matching = await Task.detached(priority: .userInitiated) {
                Set(((try? index.albums(
                    matching: asked, within: ids, limit: ids.count, downloadedOnly: offline
                )) ?? []).map(\.id))
            }.value
            guard !Task.isCancelled, asked == filter else { return }
            albums = given.filter { matching.contains($0.id) }
            runs = nil
            return
        }
        let key = loadKey
        loading = true
        // Guarded: `.task(id:)` does not await a superseded firing, so without this a stale load's
        // `defer` could clear the flag a *live* one had just set, showing "No albums" for the whole
        // of a load that was actually still running.
        defer { if key == loadKey { loading = false } }

        let query = collection.allowsSorting ? sort.filter : collection.filter
        // A page reached some other way — a genre, a decade — is not sorted
        // through this screen's menu, so it always runs the way its own
        // filter means.
        let way = collection.allowsSorting ? direction : .forward
        let asked = filter
        let filing = self.filing

        guard let index = app.libraryIndex else {
            // Only when there is no index yet — a first run, mid-sync.
            guard let provider = app.provider else { return }
            let fetched = (try? await provider.albums(filter: query, offset: 0, limit: 200)) ?? []
            guard key == loadKey else { return }
            (albums, runs) = Self.fileIfNeeded(fetched, filing: filing)
            return
        }

        let offline = app.isOffline
        let limit = collection.resultLimit ?? Self.indexLimit
        // Detached for where it runs, cancelled by hand for when it stops —
        // see `SongsListView.load()`, which this mirrors exactly and for
        // the same two reasons.
        let work = Task.detached(priority: .userInitiated) {
            Self.read(
                index, query: query, direction: way, filter: asked,
                limit: limit, offline: offline, filing: filing
            )
        }
        let (rows, filed) = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, key == loadKey else { return }
        albums = rows
        runs = filed
        // Kept for the next visit, under the *live* version rather than the one captured at init:
        // favouriting an album from this very grid bumps it, the key re-fires, and an entry stored
        // under a version already gone stale could never be found again.
        if let library = app.libraryIndex?.server {
            cache.store(AlbumListCache.Entry(
                key: AlbumListCache.Key(
                    library: library,
                    version: app.libraryVersion,
                    offline: offline,
                    page: page,
                    query: query,
                    direction: way,
                    filter: asked
                ),
                albums: rows,
                runs: filed
            ))
        }
    }

    /// The rows, and where each letter's run sits in them, worked out
    /// together off the main actor.
    nonisolated private static func read(
        _ index: LibraryIndex,
        query: AlbumFilter,
        direction: LibraryIndex.SortDirection,
        filter: LibraryFilter,
        limit: Int,
        offline: Bool,
        filing: Filing
    ) -> ([Album], AlphabetIndex.SectionRuns?) {
        let rows = filter.isEmpty
            ? (try? index.albums(
                filter: query, direction: direction, offset: 0,
                limit: limit, downloadedOnly: offline
            )) ?? []
            : (try? index.albums(
                matching: filter, order: query, direction: direction,
                limit: limit, downloadedOnly: offline
            )) ?? []
        // The read itself cannot be interrupted part way, but the filing
        // after it can be skipped for a screen nobody is looking at any more.
        guard !Task.isCancelled else { return ([], nil) }
        return fileIfNeeded(rows, filing: filing)
    }

    private static func fileIfNeeded(
        _ albums: [Album], filing: Filing
    ) -> ([Album], AlphabetIndex.SectionRuns?) {
        guard filing != .none, albums.count >= minimumForIndex else { return (albums, nil) }
        let key: (Album) -> String = filing == .byArtist
            ? { $0.artistName ?? $0.displayName }
            : { $0.displayName }
        let (ordered, runs) = AlphabetIndex.filed(albums, title: key)
        return (ordered, runs)
    }

    /// How many albums the local index is asked for.
    private static let indexLimit = 100_000
}
