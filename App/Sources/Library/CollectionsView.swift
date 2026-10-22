import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// The sets someone has gathered on the server — of one kind at a time.
struct CollectionsView: View {
    let kind: MediaCollection.Kind

    @Environment(AppModel.self) private var app

    @State private var collections: [MediaCollection] = []
    @State private var loading = true
    @State private var loadError: String?

    private var noun: String { kind == .albums ? "album" : "artist" }

    private var usesGrid: Bool { app.settings.collectionsUseGrid(kind) }

    @State private var sort: CollectionListSort = .name
    @State private var direction: LibraryIndex.SortDirection = .forward

    private var ordered: [MediaCollection] { sort.sorted(collections, direction: direction) }

    var body: some View {
        Group {
            if usesGrid { grid } else { list }
        }
        .navigationTitle(kind == .albums ? "Album Collections" : "Artist Collections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !collections.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    SortMenu(order: $sort, direction: $direction)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The same two shapes a collection itself offers once it
                    // is opened — this screen was the one place that had
                    // only ever been a list.
                    Button {
                        app.settings.setCollectionsUseGrid(!usesGrid, for: kind)
                    } label: {
                        Image(systemName: usesGrid ? "square.grid.2x2.fill" : "list.bullet")
                    }
                    .accessibilityLabel(usesGrid ? "Showing a grid" : "Showing a list")
                }
            }
        }
        .overlay {
            if loading && collections.isEmpty {
                ProgressView()
            } else if collections.isEmpty, let loadError {
                // A failed request is not an empty server.
                FetchFailureView(message: loadError) { Task { await load() } }
            } else if collections.isEmpty {
                ContentUnavailableView(
                    kind == .albums ? "No album collections" : "No artist collections",
                    systemImage: kind == .albums ? "rectangle.stack" : "rectangle.stack.person.crop",
                    description: Text("Nothing has been gathered into a collection on this server.")
                )
            }
        }
        .task { await load() }
    }

    private var list: some View {
        List(ordered) { collection in
            NavigationLink(value: collection) {
                HStack(spacing: 12) {
                    ArtworkView(
                        artwork: collection.artwork,
                        size: CompactList.thumbnailSize,
                        cornerRadius: 6
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(collection.name)
                            .lineLimit(1)
                        if let count = collection.itemCount {
                            Text(count.counted(noun))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listRowInsets(CompactList.indexedRowInsets)
            .contextMenu {
                CollectionMenuContent(
                    collection: collection, actions: MediaActions(app: app), pins: app.pins
                )
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
    }

    /// The same grid a collection draws once it is opened: as many across as
    /// the album pages are set to, at the same spacing, so opening one is not
    /// a change of scale.
    private var grid: some View {
        ScrollView {
            MeasuredWidth { width in
                let metrics = AlbumGridMetrics(
                    availableWidth: width,
                    columns: app.settings.albumColumns,
                    spacing: 10
                )
                LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 16) {
                    ForEach(ordered) { collection in
                        NavigationLink(value: collection) {
                            cell(collection, width: metrics.itemWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            CollectionMenuContent(
                                collection: collection, actions: MediaActions(app: app), pins: app.pins
                            )
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func cell(_ collection: MediaCollection, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(artwork: collection.artwork, size: width, cornerRadius: 8)
            Text(collection.name)
                .font(.subheadline)
                .lineLimit(1)
            // A blank line rather than none where the server gives no count,
            // so the sleeves below stay on one line with each other.
            Text(collection.itemCount.map { $0.counted(noun) } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let provider = app.provider,
              provider.capabilities.contains(.collections)
        else {
            loading = false
            return
        }
        loading = true
        loadError = nil
        defer { loading = false }
        switch await FetchOutcome.attempt({ try await provider.collections() }) {
        case .answered(let all):
            collections = all.filter { $0.kind == kind }
        case .cancelled:
            break
        case .failed(let message):
            // The list already on show, if any, stays.
            loadError = message
        }
    }
}

/// What a browse screen shows when its request failed: the reason and a way
/// to try again, instead of the empty state that would say the server has
/// nothing.
struct FetchFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Can't load this", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

/// One collection of artists. Records get `AlbumCollectionView`, which
/// already knows how to draw a shelf of sleeves.
struct ArtistCollectionView: View {
    let collection: MediaCollection

    @Environment(AppModel.self) private var app
    @State private var fetched = FetchedList<Artist>()
    @State private var sort: CollectionArtistSort = .name
    @State private var direction: LibraryIndex.SortDirection = .forward

    private var artists: [Artist] { fetched.items ?? [] }
    private var ordered: [Artist] { sort.sorted(artists, direction: direction) }

    var body: some View {
        // The jump bar only where the list is actually alphabetical: sorted
        // by album count, or backwards, the letters down the right would
        // point at the right rows under the wrong headings.
        IndexedList(
            items: ordered,
            title: \.name,
            // Out of reach unless the list is actually alphabetical: sorted
            // by album count, or backwards, the letters down the right would
            // point at the right rows under the wrong headings.
            minimumForIndex: sort == .name && direction == .forward ? 20 : .max,
            // Re-ordering the same artists leaves the count alone, and the count is half of what
            // `IndexedList` files by — without this it would keep the filing from the previous
            // sort.
            groupingKey: "\(sort.rawValue)|\(direction.rawValue)"
        ) { artist in
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
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !artists.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    SortMenu(order: $sort, direction: $direction)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Play All", systemImage: "play.fill") {
                            MediaActions(app: app).playCollection(artists: ordered, shuffled: false)
                        }
                        Button("Shuffle", systemImage: "shuffle") {
                            MediaActions(app: app).playCollection(artists: ordered, shuffled: true)
                        }
                        PinMenuItem(item: PinnedItem(collection: collection), pins: app.pins)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .overlay {
            if fetched.isLoading {
                ProgressView()
            } else if fetched.isFailed, let failure = fetched.failure {
                FetchFailureView(message: failure) { Task { await load() } }
            } else if fetched.isEmptyAnswer {
                ContentUnavailableView(
                    "Empty collection",
                    systemImage: "music.mic",
                    description: Text("There are no artists in this collection.")
                )
            }
        }
        .task(id: app.connectionKey) { await load() }
    }

    private func load() async {
        // No server to ask is not an empty collection; the task runs again
        // when one arrives, because it is keyed on the connection.
        guard let provider = app.provider else {
            fetched.apply(.failed(message: "Not connected to a server."))
            return
        }
        fetched.beginRetry()
        fetched.apply(await FetchOutcome.attempt { try await provider.artists(inCollection: collection.id) })
    }
}

/// One collection of records, drawn by the same view the rest of the library
/// uses for a shelf of sleeves.
struct CollectionAlbumsView: View {
    let collection: MediaCollection

    @Environment(AppModel.self) private var app
    @State private var fetched = FetchedList<Album>()
    @State private var sort: CollectionAlbumSort = .name
    @State private var direction: LibraryIndex.SortDirection = .forward

    /// Play, shuffle and pin, plus this screen's own sort — folded into the
    /// list's one menu, since a collection's name needs the whole title bar.
    @ViewBuilder
    private func menuContent(for albums: [Album]) -> some View {
        Section {
            Button("Play All", systemImage: "play.fill") {
                MediaActions(app: app).playCollection(
                    albums: sort.sorted(albums, direction: direction), shuffled: false
                )
            }
            Button("Shuffle", systemImage: "shuffle") {
                MediaActions(app: app).playCollection(albums: albums, shuffled: true)
            }
            PinMenuItem(item: PinnedItem(collection: collection), pins: app.pins)
        }
        Section {
            SortMenuContent(order: $sort, direction: $direction)
        }
    }

    var body: some View {
        Group {
            if let albums = fetched.items {
                // Sorted before it is handed over, not by the screen it is handed to.
                AlbumCollectionView(
                    collection: AlbumCollection(
                        title: collection.name,
                        albums: sort.sorted(albums, direction: direction)
                    ),
                    extraMenu: { AnyView(menuContent(for: albums)) },
                    cache: app.albumList,
                    library: app.libraryIndex?.server,
                    version: app.libraryVersion,
                    offline: app.isOffline
                )
            } else if let failure = fetched.failure {
                FetchFailureView(message: failure) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: app.connectionKey) { await load() }
    }

    private func load() async {
        guard let provider = app.provider else {
            fetched.apply(.failed(message: "Not connected to a server."))
            return
        }
        fetched.beginRetry()
        fetched.apply(await FetchOutcome.attempt { try await provider.albums(inCollection: collection.id) })
    }
}
