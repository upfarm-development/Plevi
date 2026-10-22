import SwiftUI
import PleviDomain
import PleviLibraryIndex
import PleviTransport

/// Landing screen: horizontal shelves drawn from the local index, so it
/// paints instantly and costs the server nothing.
struct HomeView: View {
    /// Owned by `RootView` so the stack survives the mini-player accessory
    /// being attached when playback starts.
    @Binding var path: NavigationPath

    @Environment(AppModel.self) private var app
    @State private var shelves: [Shelf] = []
    @State private var showSettings = false
    @State private var loadError: String?
    /// Home is the only screen reachable with nothing playing and no active remote session, so it
    /// is the one place Remote Control's device picker cannot be gated on `remote.inUse` or a mini
    /// bar being on screen — otherwise there would be no way to…
    @State private var showingDevicePicker = false
    /// One name per mounted button, so two of them on screen (Home under Now Playing) do not
    /// release each other's browse (R-10).
    @State private var browseOwner = "home-\(UUID().uuidString)"

    struct Shelf: Identifiable {
        let id: String
        let title: String
        let filter: AlbumFilter
        var albums: [Album]
    }

    @State private var stations: [RadioStation] = []
    @State private var pinned: [PinnedCard] = []
    @State private var onThisDay = OnThisDayStore()
    @State private var madeForYou = MadeForYouStore()
    @State private var editorsChoice = EditorsChoiceStore()
    @State private var spotlight = SpotlightStore()
    @State private var rediscover = RediscoverStore()
    @State private var mostListened = MostListenedStore()
    /// Albums for each custom shelf that asks about records, and how many
    /// songs each custom shelf that asks about songs would play.
    @State private var customAlbums: [UUID: [Album]] = [:]
    @State private var customSongCounts: [UUID: Int] = [:]
    /// The first few songs of a shelf set to draw as a list — only as many
    /// as Home shows, since "More" reads the rest for itself.
    @State private var customSongs: [UUID: [Track]] = [:]
    /// Whether `load` has run for the library now on screen.
    @State private var hasLoaded = false
    /// The connection the last load was for, to tell a new one from a bump.
    @State private var loadedConnection: String?

    /// Everything that makes the Home load worth running again.
    private struct HomeLoadKey: Equatable {
        var version: Int
        var connection: String
        var sections: [CustomHomeSection]
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Measured here, above the `LazyVStack`, rather than by each shelf itself: a row inside
            // that stack is torn down and rebuilt from scratch every time it scrolls far enough
            // off-screen to be evicted, and a shelf whose own first frame always…
            GeometryReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        // In the order Settings says, so the shelves are
                        // arranged the way this listener uses them rather
                        // than the way the app was written.
                        ForEach(app.settings.homeSectionOrder) { section in
                            if app.settings.isEnabled(section) {
                                view(for: section, availableWidth: proxy.size.width)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .overlay {
                    if isEmpty { emptyState }
                }
            }
            // No headline. The app's own name at the top of its own home
            // screen tells you nothing you did not know when you opened it,
            // and it costs the shelves a title's worth of room.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // The remote-control button, not an AirPlay one: the player has the system's
                    // own AirPlay picker, and this is where another Plevi is chosen.
                    DeviceButton(
                        state: deviceButtonState,
                        localGlyph: "ipad.and.iphone",
                        localTint: app.remote.controllingNames.isEmpty ? .primary : .accentColor,
                        controllingTint: .accentColor
                    ) { showingDevicePicker = true }
                        .popover(isPresented: $showingDevicePicker) {
                            DevicePicker(
                                rows: app.remote.pickerRows,
                                showAirPlayRow: false,
                                volume: app.remote.controlledPlayer?.offeredVolume,
                                footer: app.remote.lastError,
                                onSelect: { app.remote.selectDeviceRow(id: $0) },
                                onChangeVolume: { app.remote.controlledPlayer?.setOfferedVolume($0) })
                                .equatable()
                        }
                        .onAppear { app.remote.startBrowsing(owner: browseOwner) }
                        .onDisappear { app.remote.stopBrowsing(owner: browseOwner) }
                }
                if librarySwitcher.count >= 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        librarySwitcherButton
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: SimilarArtistsRoute.self) { SimilarArtistsListView(route: $0) }
            .navigationDestination(for: AlbumCollection.self) { collection in
                AlbumCollectionView(
                    collection: collection,
                    cache: app.albumList,
                    library: app.libraryIndex?.server,
                    version: app.libraryVersion,
                    offline: app.isOffline
                )
            }
            // Reachable from Home only through a pinned playlist, but without
            // it that card is a picture that does nothing when tapped.
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: RadioPicker.self) { RadioPickerView(picker: $0) }
            // Pinned collections open from here too.
            .navigationDestination(for: MediaCollection.self) { collection in
                switch collection.kind {
                case .albums: CollectionAlbumsView(collection: collection)
                case .artists: ArtistCollectionView(collection: collection)
                }
            }
            .navigationDestination(for: CustomSongList.self) {
                CustomSongListView(section: $0.section)
            }
            .navigationDestination(for: SpotlightArchiveRoute.self) { SpotlightArchiveView(history: $0.history) }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            // One task for all three triggers.
            .task(id: HomeLoadKey(
                version: app.libraryVersion,
                connection: app.connectionKey,
                sections: app.customSections.sections
            )) {
                if loadedConnection != app.connectionKey {
                    hasLoaded = false
                    loadedConnection = app.connectionKey
                }
                load()
                await loadCustomSections()
            }
            // Pinning happens from a menu anywhere in the app, including from this screen, so the
            // shelf follows the board rather than waiting for the next sync — but only once
            // `load()` has run at least once.
            .task(id: app.pins.items) {
                guard hasLoaded else { return }
                loadPins()
            }
            // Its records come from the index and its reviews from the server, so this one is asked
            // for separately rather than with the shelves.
            .task(id: shelfKey) {
                await madeForYou.refresh(index: app.libraryIndex, provider: app.providerForActiveLibrary, offline: app.isOffline)
            }
            .task(id: "\(shelfKey)|\(app.isOffline)") {
                rediscover.refresh(index: app.libraryIndex, downloadedOnly: app.isOffline)
            }
            .task(id: shelfKey) {
                editorsChoice.refresh(
                    index: app.libraryIndex,
                    capabilities: app.expectedCapabilities
                )
            }
            .task(id: shelfKey) {
                await spotlight.refresh(
                    index: app.libraryIndex,
                    provider: app.providerForActiveLibrary,
                    capabilities: app.expectedCapabilities
                )
            }
            .task(id: shelfKey) {
                await onThisDay.refresh(
                    index: app.libraryIndex,
                    provider: app.providerForActiveLibrary,
                    offline: app.isOffline
                )
            }
            .task(id: shelfKey) {
                await mostListened.refresh(index: app.libraryIndex, provider: app.providerForActiveLibrary, offline: app.isOffline)
                // A task that was called off has nothing to report, whatever
                // the store left behind.
                if !Task.isCancelled, let diagnostic = mostListened.consumeDiagnosticIfNew() {
                    app.showTransientError(diagnostic)
                }
            }
            .refreshable {
                app.startBackgroundSync(force: true)
                load()
                await loadCustomSections()
                await madeForYou.refresh(index: app.libraryIndex, provider: app.providerForActiveLibrary, offline: app.isOffline)
                rediscover.refresh(index: app.libraryIndex, downloadedOnly: app.isOffline)
                await mostListened.refresh(
                    index: app.libraryIndex, provider: app.providerForActiveLibrary,
                    offline: app.isOffline, userInitiated: true
                )
                if !Task.isCancelled, let diagnostic = mostListened.consumeDiagnosticIfNew() {
                    app.showTransientError(diagnostic)
                }
                editorsChoice.refresh(
                    index: app.libraryIndex,
                    capabilities: app.expectedCapabilities
                )
                await spotlight.refresh(
                    index: app.libraryIndex,
                    provider: app.providerForActiveLibrary,
                    capabilities: app.expectedCapabilities
                )
            }
        }
    }

    /// The libraries worth switching between, chosen in Settings. Fewer than
    /// two is no switcher at all. Only the active server's own: the setting
    /// is one list for every server.
    private var librarySwitcher: [LibrarySelection] {
        app.quickSwitchChoices
    }

    private var currentLibraryKey: String? {
        app.servers.activeServer?.library?.key
    }

    /// With two libraries this is a switch, not a menu: tapping it goes to the other one.
    private var deviceButtonState: DeviceButtonState { app.remote.deviceButtonState }

    /// music should not be a trip through Settings in either case.
    @ViewBuilder
    private var librarySwitcherButton: some View {
        if librarySwitcher.count == 2,
           let other = librarySwitcher.first(where: { $0.key != currentLibraryKey }) {
            Button {
                Task { await app.switchLibrary(to: other) }
            } label: {
                Label("Switch to \(other.title)", systemImage: "square.stack")
            }
            .accessibilityLabel("Switch to \(other.title)")
        } else {
            Menu {
                ForEach(librarySwitcher, id: \.key) { library in
                    Button {
                        Task { await app.switchLibrary(to: library) }
                    } label: {
                        if library.key == currentLibraryKey {
                            Label(library.title, systemImage: "checkmark")
                        } else {
                            Text(library.title)
                        }
                    }
                }
            } label: {
                Label("Library", systemImage: "square.stack")
            }
            .accessibilityLabel("Switch library")
        }
    }

    @ViewBuilder
    private func view(for section: HomeSection, availableWidth: CGFloat) -> some View {
        switch section {
        case .pinned:
            if !pinned.isEmpty {
                PinnedShelf(cards: pinned)
            }
        case .onThisDay:
            if !onThisDay.entries.isEmpty {
                OnThisDayShelf(
                    entries: onThisDay.entries,
                    knownWidth: availableWidth,
                    isFilling: onThisDay.isFilling
                )
            }
        case .radio:
            if !stations.isEmpty {
                RadioShelf(
                    stations: stations,
                    knownWidth: availableWidth,
                    layout: app.settings.homeLayout(.radio)
                )
            }
        case .recentlyPlayed:
            if !app.playLog.entries.isEmpty {
                RecentlyPlayedShelf(entries: app.playLog.entries)
            }
        case .rediscover:
            if !rediscover.albums.isEmpty {
                AlbumShelf(
                    title: HomeSection.rediscover.title,
                    albums: rediscover.albums,
                    // The day's pick itself, not the question that made it:
                    // asked again, "See More" drew a different set.
                    collection: AlbumCollection(
                        title: HomeSection.rediscover.title,
                        albums: rediscover.all,
                        showsArtist: true
                    ),
                    layout: app.settings.homeLayout(.rediscover)
                )
            }
        case .madeForYou:
            // Only where the server can say what sounds like what. On one
            // that cannot, this shelf would be five cards that do nothing.
            if !madeForYou.mixes.isEmpty,
               app.expectedCapabilities.contains(.similarItems) {
                MadeForYouShelf(mixes: madeForYou.mixes, knownWidth: availableWidth) { madeForYou.seeds(for: $0) }
            }
        case .editorsChoice:
            // No card at all rather than an empty one: a day with nothing
            // over the bar, or a server with no reviewer's verdict to give.
            if let album = editorsChoice.pick {
                EditorsChoiceShelf(album: album, knownWidth: availableWidth)
            }
        case .mostListened:
            if !mostListened.albums.isEmpty {
                MostListenedList(
                    monthName: mostListened.monthName,
                    albums: mostListened.albums,
                    totalSeconds: mostListened.totalSeconds
                )
            }
        case .spotlight:
            // No card without a bio: the poster's whole bottom half is built around the hook text,
            // and an artist with nothing written about them is skipped in `SpotlightStore` itself
            // for exactly this reason.
            if let artist = spotlight.artist, let bio = spotlight.bio, !spotlight.albums.isEmpty {
                SpotlightShelf(
                    artist: artist,
                    albums: spotlight.albums,
                    bio: bio,
                    libraryAlbumCount: spotlight.libraryAlbumCount,
                    history: spotlight.history(for: app.libraryIndex?.server.rawValue.uuidString ?? ""),
                    knownWidth: availableWidth
                )
            }
        case .custom(let id):
            if let section = app.customSections.section(id: id) {
                CustomShelf(
                    section: section,
                    albums: customAlbums[id] ?? [],
                    songs: customSongs[id] ?? [],
                    songCount: customSongCounts[id] ?? 0
                )
            }
        default:
            if let shelf = shelves.first(where: { $0.id == section.rawValue }) {
                AlbumShelf(
                    title: shelf.title,
                    albums: shelf.albums,
                    filter: shelf.filter,
                    layout: app.settings.homeLayout(section)
                )
            }
        }
    }

    /// When the shelves that keep their own store should look again.
    private var shelfKey: String {
        "\(app.libraryVersion)|\(app.libraryIndex == nil)|\(app.connectionKey)"
    }

    /// Nothing to show at all — no albums on any shelf and no station worth
    /// offering.
    private var isEmpty: Bool {
        shelves.isEmpty && stations.isEmpty && pinned.isEmpty
            && onThisDay.entries.isEmpty && madeForYou.mixes.isEmpty
            && rediscover.albums.isEmpty && mostListened.albums.isEmpty && spotlight.artist == nil
            // Three that were not counted, each of which can be the only thing a library has: a
            // listener whose Home is their own custom shelves, or nothing but what they played
            // last, was told there was nothing here at all while the screen behind had…
            && app.playLog.entries.isEmpty
            && editorsChoice.pick == nil
            && customAlbums.allSatisfy { $0.value.isEmpty }
            && customSongCounts.allSatisfy { $0.value == 0 }
    }

    @ViewBuilder
    private var emptyState: some View {
        // Before this screen has asked the index anything there is nothing to say yet.
        if !hasLoaded {
            ProgressView()
        } else {
            settledEmptyState
        }
    }

    @ViewBuilder
    private var settledEmptyState: some View {
        switch app.syncState {
        case .syncing:
            ProgressView("Syncing your library…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load your library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { app.startBackgroundSync(force: true) }
            }
        default:
            ContentUnavailableView {
                Label("Nothing here yet", systemImage: "music.note")
            } description: {
                Text("Your library will appear once it has synced.")
            } actions: {
                Button("Sync Now") { app.startBackgroundSync(force: true) }
            }
        }
    }

    /// What a pinned thing opens into.
    private func resolve(_ item: PinnedItem, in index: LibraryIndex) -> PinnedCard.Resolved {
        switch item.kind {
        case .album:
            // Pinned from another library's search results: looked for in the
            // other Quick Switch libraries by its raw id, since the library
            // its identity names is whichever one the pin was made under.
            ((try? index.album(id: item.mediaID)) ?? otherLibraries().lazy.compactMap { try? $0.album(id: item.mediaID) }.first)
                .flatMap { .album($0) } ?? .gone
        case .artist:
            ((try? index.artist(id: item.mediaID)) ?? otherLibraries().lazy.compactMap { try? $0.artist(id: item.mediaID) }.first)
                .flatMap { .artist($0) } ?? .gone
        case .playlist:
            .playlist(item.asPlaylist)
        case .collection:
            // Pinned before collections carried their kind, so there is no
            // screen to send it to. Shown as gone rather than opening the
            // wrong one.
            item.asCollection.flatMap { .collection($0) } ?? .gone
        }
    }

    private func otherLibraries() -> [LibraryIndex] {
        app.isOffline ? [] : app.otherQuickLibraryIndexes().map(\.index)
    }

    /// How deep each shelf's *row* goes — the cards on Home itself, before "See More" is even
    /// tapped.
    private static func shelfLimit(for section: HomeSection) -> Int {
        switch section {
        case .recentlyAdded, .recentlyPlayed: 50
        case .rediscover: 10
        default: 12
        }
    }

    private func load() {
        guard let index = app.libraryIndex else { return }
        defer { hasLoaded = true }
        // Once, and only while there is history to seed from — a library
        // still syncing on first run leaves it for the next load rather than
        // fixing an empty shelf in place. See `PlayLog.seedIfNeeded`.
        app.playLog.seedIfNeeded(from: index, downloadedOnly: app.isOffline)
        var built: [Shelf] = []
        for section in HomeSection.builtIns {
            // Rediscover keeps its choice for the day; drawing it here would choose again on every
            // load, which is the thing being fixed.
            guard section != .rediscover, section != .recentlyPlayed,
                  let filter = section.albumFilter
            else { continue }
            let albums = (try? index.albums(
                filter: filter,
                offset: 0,
                limit: Self.shelfLimit(for: section),
                downloadedOnly: app.isOffline
            )) ?? []
            guard !albums.isEmpty else { continue }
            built.append(Shelf(
                id: section.rawValue,
                title: section.title,
                filter: filter,
                albums: albums
            ))
        }
        shelves = built
        stations = RadioStations.all(index: index, downloadedOnly: app.isOffline)
        loadPins()
    }

    /// What each custom shelf has to show.
    private func loadCustomSections() async {
        guard let index = app.libraryIndex else { return }
        let sections = app.customSections.sections
        let offline = app.isOffline
        let asList = Set(sections.compactMap { section in
            !section.showsAlbums && app.settings.homeLayout(.custom(section.id)) == .list
                ? section.id : nil
        })
        let read = await Task.detached(priority: .userInitiated) {
            Self.readCustomSections(index: index, sections: sections, offline: offline, asList: asList)
        }.value
        // A newer load (another bump, another edit) owns the result.
        guard !Task.isCancelled else { return }
        customAlbums = read.albums
        customSongCounts = read.counts
        customSongs = read.songs
    }

    private struct CustomRead: Sendable {
        var albums: [UUID: [Album]] = [:]
        var counts: [UUID: Int] = [:]
        var songs: [UUID: [Track]] = [:]
    }

    /// The most records a custom album shelf hands to "See More", when it has
    /// no limit of its own. Home draws a dozen; the page behind it is the
    /// whole answer, as far as this.
    nonisolated static let customAlbumCeiling = 2_000

    nonisolated private static func readCustomSections(
        index: LibraryIndex,
        sections: [CustomHomeSection],
        offline: Bool,
        asList: Set<UUID>
    ) -> CustomRead {
        var read = CustomRead()
        for section in sections {
            if Task.isCancelled { break }
            if section.showsAlbums {
                // The whole set, not the dozen Home draws: `CustomShelf` shows the first few and
                // gives "See More" all of them.
                read.albums[section.id] = (try? index.albums(
                    matching: section.filter,
                    order: section.sort?.albumOrder,
                    direction: section.sort?.direction ?? .forward,
                    limit: min(section.limit ?? customAlbumCeiling, customAlbumCeiling),
                    downloadedOnly: offline
                )) ?? []
            } else {
                let found = (try? index.count(
                    matching: section.filter,
                    downloadedOnly: offline
                )) ?? 0
                // A limit is part of what the shelf is: "the hundred most recently played" holds a
                // hundred however many the rules match, and the count under the card should say so.
                read.counts[section.id] = min(found, section.limit ?? found, CustomShelf.playCap)
                if asList.contains(section.id) {
                    read.songs[section.id] = (try? index.tracks(
                        matching: section.filter,
                        order: section.sort?.songOrder,
                        direction: section.sort?.direction ?? .forward,
                        limit: min(AlbumShelf.listLimit, section.limit ?? AlbumShelf.listLimit),
                        downloadedOnly: offline
                    )) ?? []
                }
            }
        }
        return read
    }

    private func loadPins() {
        guard let index = app.libraryIndex else { return }
        pinned = app.pins.items.map { item in
            PinnedCard(item: item, resolved: resolve(item, in: index))
        }
    }
}

/// How deep each shelf's *page* goes — "See More", once it is tapped. See
/// `HomeView.shelfLimit(for:)` for the row itself, which is capped
/// separately.
extension AlbumFilter {
    /// `nil` where the point of the destination page is to show everything — a genre, a decade, the
    /// plain album list.
    var seeMoreLimit: Int? {
        switch self {
        case .recentlyAdded, .recentlyReleased, .recentlyPlayed: 50
        case .rediscover: 20
        default: nil
        }
    }
}

/// A shelf of albums, drawn the way the listener asked for it.
struct AlbumShelf: View {
    let title: String
    let albums: [Album]
    var filter: AlbumFilter?
    /// Where "See More" goes when the shelf is not a plain library query — a
    /// shelf built from someone's own filter already holds its answer, so it
    /// hands the whole set over rather than a question to ask again.
    var collection: AlbumCollection?
    /// A row that scrolls sideways, a wrapping grid, or a plain list. The
    /// same three the artist page's own sections offer, and the same
    /// component behind each — see `ArtistDetailView.albumSection`.
    var layout: AlbumDisplayStyle = .carousel

    @Environment(AppModel.self) private var app

    private var seeAll: AlbumCollection? {
        if let collection { return collection }
        guard let filter else { return nil }
        var made = AlbumCollection(title: title, filter: filter)
        made.resultLimit = filter.seeMoreLimit
        return made
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        Text("See More")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .carousel:
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album, size: 128, actions: MediaActions(app: app))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        case .grid:
            // Measured above rather than by a `GeometryReader` here, which would collapse: it has
            // no height of its own inside a scrolling stack.
            MeasuredWidth { width in
                let metrics = AlbumGridMetrics(
                    availableWidth: width,
                    columns: app.settings.albumColumns,
                    spacing: 10
                )
                LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(
                                album: album,
                                size: metrics.itemWidth,
                                actions: MediaActions(app: app)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
        case .list:
            VStack(spacing: 0) {
                ForEach(albums.prefix(Self.listLimit)) { album in
                    NavigationLink(value: album) {
                        // Compact, and naming the artist: on Home a shelf is
                        // drawn from across the library, so whose record it
                        // is is half of what the row says.
                        AlbumListRow(album: album, showsArtist: true, compact: true)
                    }
                    .buttonStyle(.plain)
                    .albumContextMenu(album, actions: MediaActions(app: app))
                }
            }
        }
    }

    /// How many rows a shelf shows when it is drawn as a list.
    static let listLimit = 5
}

/// Artwork plus two lines of text, used in shelves and grids.
struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 128
    var palette: ArtworkPalette = .neutral
    /// Off on an artist's own page, where every album is by the artist whose name is at the top of
    /// the screen and repeating it says nothing.
    var showsArtist = true
    /// Given here rather than by the caller putting a menu around the whole card, so that a long
    /// press lifts the sleeve alone.
    var actions: MediaActions?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(artwork: album.artwork, size: size)
                .modifier(OptionalAlbumMenu(album: album, actions: actions))
            Text(album.displayName)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(palette.foreground)
            // The year takes the artist's place rather than the line being dropped.
            Text(secondLine ?? " ")
                .font(.caption)
                .foregroundStyle(palette.secondaryForeground)
                .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.displayName), \(album.artistName ?? "unknown artist")")
    }

    /// Who it is by, or — where that is the page you are already on — when
    /// it came out.
    private var secondLine: String? {
        showsArtist ? album.artistName : album.year.map(String.init)
    }
}

/// The album menu, when there is somebody to act on it.
private struct OptionalAlbumMenu: ViewModifier {
    let album: Album
    let actions: MediaActions?

    func body(content: Content) -> some View {
        if let actions {
            content.albumContextMenu(album, actions: actions)
        } else {
            content
        }
    }
}

