import SwiftUI
import PleviDomain

/// Playlist browsing and management.
struct PlaylistsView: View {
    var isRoot = false
    /// Only used when this is a tab root; see `HomeView.path`.
    var path: Binding<NavigationPath>?

    @Environment(AppModel.self) private var app
    @State private var store: PlaylistStore?
    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""

    /// Ordered here rather than taken as the server sends it: Plex answers with its smart playlists
    /// first, Subsonic does something else again, and which of those you want is a matter of taste
    /// — so it is a setting and the app applies it.
    private var sortedPlaylists: [Playlist] {
        app.settings.playlistSorting.sorted(
            store?.playlists ?? [],
            pinnedToTop: app.playlistTopPins.ids
        )
    }

    var body: some View {
        Group {
            if isRoot, let path {
                NavigationStack(path: path) {
                    content
                        .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
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
                        .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
                        .navigationDestination(for: SimilarArtistsRoute.self) { SimilarArtistsListView(route: $0) }
                }
            } else {
                content
            }
        }
    }

    /// Where each letter's run sits, with anything held at the top in a run of its own above them.
    private var runs: AlphabetIndex.SectionRuns? {
        let all = sortedPlaylists
        guard app.settings.playlistSorting == .together, all.count >= Self.minimumForIndex else {
            return nil
        }
        let pinnedCount = all.prefix { app.playlistTopPins.isPinned($0) }.count
        let rest = Array(all.dropFirst(pinnedCount))
        let filed = AlphabetIndex.filed(rest) { $0.name }.runs
        guard !filed.isEmpty else { return nil }

        var sections: [String] = []
        var ranges: [Range<Int>] = []
        if pinnedCount > 0 {
            sections.append("↑")
            ranges.append(0..<pinnedCount)
        }
        // Shifted past the pinned block, since the filer counted from zero.
        for (section, range) in zip(filed.sections, filed.ranges) {
            sections.append(section)
            ranges.append((range.lowerBound + pinnedCount)..<(range.upperBound + pinnedCount))
        }
        return AlphabetIndex.SectionRuns(sections: sections, ranges: ranges, count: all.count)
    }

    /// Below this a bar points at almost the whole list — the same floor
    /// every other indexed list in the app uses.
    private static let minimumForIndex = 20

    private var content: some View {
        IndexedList(
            items: sortedPlaylists,
            title: { $0.name },
            // Out of reach unless the list is one alphabet.
            minimumForIndex: app.settings.playlistSorting == .together
                ? Self.minimumForIndex
                : .max,
            // The order can change without the count changing — pinning one
            // does exactly that — so the filing has to be told.
            groupingKey: "\(app.settings.playlistSorting.rawValue)|\(app.playlistTopPins.ids.sorted().joined(separator: ","))",
            runs: runs
        ) { playlist in
            NavigationLink(value: playlist) {
                PlaylistRow(
                    playlist: playlist,
                    isPinnedToTop: app.playlistTopPins.isPinned(playlist)
                )
            }
            .warmsPlaylist(playlist)
            .contextMenu {
                NavigationLink("Open", value: playlist)
                // The songs are fetched when this is pressed rather than
                // held for every row — see `PlaylistDownloadMenuItems`.
                PlaylistDownloadMenuItems(playlist: playlist, actions: MediaActions(app: app))
                // The songs are fetched on the press, like the download above it: a playlist lives
                // on the server, and holding every playlist's songs to draw a menu is a request per
                // row for something almost nobody opens.
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    Task {
                        app.requestAddToPlaylist(
                            await MediaActions(app: app).tracks(inPlaylist: playlist)
                        )
                    }
                }
                .disabled(app.isOffline)
                TopPinMenuItem(playlist: playlist, pins: app.playlistTopPins)
                PinMenuItem(item: PinnedItem(playlist: playlist), pins: app.pins)
                Button("Rename", systemImage: "pencil") {
                    renameText = playlist.name
                    renaming = playlist
                }
            }
            // No delete, here or anywhere: this app does not remove anything from the server.
            .listRowInsets(CompactList.indexedRowInsets)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar {
            // Gone offline rather than greyed out.
            if !app.isOffline {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        creating = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .disabled(store?.isSupported == false)
                }
            }
        }
        .overlay {
            // Offline the list is empty for a reason that has nothing to do with having no
            // playlists, and the answer is not to offer a new one — making a playlist is something
            // the server does, so the button could only fail.
            if app.isOffline {
                ContentUnavailableView {
                    Label(
                        app.isOfflineByChoice ? "Offline" : "Can't reach the server",
                        systemImage: app.isOfflineByChoice ? "airplane" : "wifi.slash"
                    )
                } description: {
                    Text("Playlists live on your server. The ones you downloaded are in Downloads.")
                }
            } else if let store, store.playlists.isEmpty, !store.isLoading {
                ContentUnavailableView {
                    Label("No playlists", systemImage: "music.note.list")
                } description: {
                    Text(store.lastError ?? "Playlists you create appear here and on your server.")
                } actions: {
                    Button("New Playlist") { creating = true }
                }
            }
        }
        .refreshable { await store?.refresh() }
        .task(id: app.connectionKey) {
            let store = store ?? PlaylistStore(app: app)
            self.store = store
            await store.refresh()
        }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                guard !name.isEmpty else { return }
                Task { await store?.create(named: name) }
            }
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let playlist = renaming else { return }
                renaming = nil
                Task { await store?.rename(playlist, to: name) }
            }
        }

    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    /// Opened from Downloads, where the playlist is what is on the phone and nothing is asked of
    /// the server to show it.
    let downloadedOnly: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The size this page is laying out in — see `PageMetrics`.
    @State private var pageSize: CGSize = .zero
    @State private var loader: PlaylistLoader?
    /// Whether `loader` is reading the phone's copy of the playlist (a kept playlist, offline or
    /// opened from Downloads) rather than the server's list.
    @State private var loaderIsPhoneCopy = false
    @State private var isEditing = false
    @State private var store: PlaylistStore?
    /// Playlists get the same artwork-led page as albums and artists.
    @State private var palette: PaletteLoader

    init(playlist: Playlist, downloadedOnly: Bool = false) {
        self.playlist = playlist
        self.downloadedOnly = downloadedOnly
        _palette = State(initialValue: PaletteLoader(artwork: playlist.artwork))
    }

    /// Whether the songs on screen are the phone's copy rather than the
    /// server's list — offline, or opened from Downloads.
    private var readsFromPhone: Bool { app.isOffline || downloadedOnly }

    /// Whether what is on screen is the server's list, which is the only thing an edit can safely
    /// act on.
    private var isServerList: Bool { loader != nil && !loaderIsPhoneCopy }

    /// Playlists have their own background setting; see
    /// `AppSettings.playlistPageStyle`.
    private var style: PageStyle { app.settings.playlistPageStyle }

    /// `PageMetrics` decides shape; `style` above decides appearance, from
    /// this page's own setting. The two never consult each other.
    private var metrics: PageMetrics {
        PageMetrics(
            size: pageSize,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    private var activePalette: ArtworkPalette {
        .forPage(style, artwork: palette.palette)
    }
    /// Set while the whole playlist is being fetched for something that
    /// cannot work with part of it.
    @State private var fullLoad: FullLoad?
    /// A removal waiting to be confirmed. A swipe is an easy thing to do by
    /// accident, and putting a song back means finding it again.
    @State private var pendingRemoval: PendingRemoval?
    /// How far this page has been pulled past its own top — see
    /// `trackingHeaderPull`.
    @State private var headerPull: CGFloat = 0

    private struct PendingRemoval: Identifiable {
        let id = UUID()
        let entries: [PlaylistEntryID]
        /// What to call the thing being removed, in the question.
        let what: String
    }

    /// Playlists up to this length are fetched all the way through as soon as they open, in the
    /// background.
    private static let fetchWholeUpTo = 1000

    private struct FullLoad {
        var loaded: Int
        var total: Int?
        var task: Task<Void, Never>?
    }

    /// What the last sort produced and what it was a sort of. A reference
    /// type on purpose: filled from inside `body`, where writing `@State`
    /// is not allowed, and it must not itself invalidate anything.
    private final class SortMemo {
        struct Key: Equatable {
            var loader: ObjectIdentifier
            var revision: Int
            var field: PlaylistSongSort
            var ascending: Bool
            var complete: Bool
        }
        var key: Key?
        var entries: [PlaylistEntry] = []
        var tracks: [Track]?
    }
    @State private var memo = SortMemo()

    /// In whichever order the songs are being read right now — the playlist's own order by default,
    /// see `sortedEntries(_:)`.
    private var entries: [PlaylistEntry] {
        guard let loader else { return [] }
        let order = app.settings.playlistTrackOrder
        let key = SortMemo.Key(
            loader: ObjectIdentifier(loader), revision: loader.revision,
            field: order.field, ascending: order.ascending,
            complete: loader.hasEverything
        )
        if memo.key == key { return memo.entries }
        let raw = loader.entries
        memo.entries = (order.field == .added || loader.hasEverything)
            ? sortedEntries(raw)
            : raw
        memo.tracks = nil
        memo.key = key
        return memo.entries
    }

    /// Sorted the way `app.settings.playlistTrackOrder` currently asks for.
    private func sortedEntries(_ raw: [PlaylistEntry]) -> [PlaylistEntry] {
        let order = app.settings.playlistTrackOrder
        switch order.field {
        case .added:
            return order.ascending ? raw : raw.reversed()
        case .artist:
            let sorted = raw.sorted {
                let left = (
                    $0.track.artistName ?? "", $0.track.albumName ?? "",
                    $0.track.discNumber ?? 1, $0.track.trackNumber ?? 0
                )
                let right = (
                    $1.track.artistName ?? "", $1.track.albumName ?? "",
                    $1.track.discNumber ?? 1, $1.track.trackNumber ?? 0
                )
                return left < right
            }
            return order.ascending ? sorted : sorted.reversed()
        case .title:
            let sorted = raw.sorted {
                $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending
            }
            return order.ascending ? sorted : sorted.reversed()
        case .year:
            // A song with no year carries nothing to sort by either way, so it sits at the bottom
            // regardless of direction rather than reading as either the very oldest or the very
            // newest thing here.
            let dated = raw.filter { $0.track.year != nil }
            let undated = raw.filter { $0.track.year == nil }
            let sorted = dated.sorted {
                let leftYear = $0.track.year ?? 0
                let rightYear = $1.track.year ?? 0
                guard leftYear != rightYear else {
                    return $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending
                }
                return leftYear < rightYear
            }
            return (order.ascending ? sorted : sorted.reversed()) + undated
        }
    }

    /// Only where the songs themselves are needed — playing, downloading.
    private var tracks: [Track] {
        let sorted = entries
        if let held = memo.tracks { return held }
        let mapped = sorted.map(\.track)
        memo.tracks = mapped
        return mapped
    }

    private var hasEverything: Bool { loader?.hasEverything ?? false }

    var body: some View {
        page
        // Draws over the header without taking its touches — see the same overlay on
        // `AlbumDetailView` for what that costs when it does.
        .overlay {
            Group {
                // Offline *and* nothing kept.
                if app.isOffline, entries.isEmpty, loader == nil || loader?.hasEverything == true {
                    ContentUnavailableView {
                        Label("Not downloaded", systemImage: "wifi.slash")
                    } description: {
                        Text("None of this playlist is on your phone. It needs the server.")
                    }
                } else if let loader, loader.entries.isEmpty, loader.error == nil, !loader.hasEverything {
                    ProgressView()
                } else if loader?.isEmpty == true {
                    ContentUnavailableView(
                        "Empty playlist",
                        systemImage: "music.note.list",
                        description: Text("Add songs from the menu on any song, album, or artist.")
                    )
                }
            }
            .allowsHitTesting(false)
        }
        // Its own overlay, unlike the messages above, because it has a
        // button and the group above lets no touch through.
        .overlay { loadFailure }
        .overlay {
            if let fullLoad {
                fullLoadProgress(fullLoad)
            }
        }
        // Keyed on the connection: a playlist opened offline is the phone's copy, and it has to
        // give way to the server's list when the server comes back rather than stay the whole
        // playlist for good.
        .task(id: "\(app.isOffline)|\(app.downloads.map { ObjectIdentifier($0).hashValue } ?? 0)|\(app.downloads?.hasReadRecords ?? false)") {
            await load()
        }
        .refreshable { await retryLoad() }
        .task(id: playlist.artwork?.rawValue) {
            await palette.load(artwork: playlist.artwork, using: app.artwork)
        }
        .onDisappear {
            fullLoad?.task?.cancel()
            fullLoad = nil
        }
    }

    /// The list and everything that shapes it; the overlays, dialogs and
    /// tasks sit in `body`, split so neither is too large to type-check.
    private var page: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                    // Zero in both layouts, for two different reasons.
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(entries) { entry in
                    PlaylistTrackRow(
                        entry: entry,
                        isCurrent: app.activePlayer.currentTrack?.id == entry.track.id,
                        palette: activePalette,
                        actions: MediaActions(app: app),
                        play: { play(from: entry) },
                        shuffleRest: { shuffleFromHere(entry.track) },
                        goToAlbum: entry.track.albumID.map { id in
                            { app.requestNavigation(.album(id, name: entry.track.albumName)) }
                        },
                        goToArtist: entry.track.artistID.map { id in
                            { app.requestNavigation(.artist(id, name: entry.track.artistName)) }
                        }
                    )
                    .equatable()
                    .listRowBackground(Color.clear)
                    // "Remove", not "Delete": this takes the song out of the playlist and does
                    // nothing whatever to the file.
                    .swipeActions(edge: .trailing) {
                        if isServerList {
                            Button(role: .destructive) {
                                pendingRemoval = PendingRemoval(
                                    entries: [entry.entryID],
                                    what: entry.track.title
                                )
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                    // The style sets how much air a row gets; everything
                    // else about the insets stays as it was.
                    .listRowInsets(EdgeInsets(
                        top: app.settings.trackRowStyle.verticalPadding,
                        leading: 16,
                        bottom: app.settings.trackRowStyle.verticalPadding,
                        trailing: 16
                    ))
                    .task { await loader?.loadMoreIfNeeded(at: entry) }
                    // On the row being removed, so the question comes up from the song itself
                    // rather than from wherever the page puts a dialog hung on all of it.
                    .confirmationDialog(
                        pendingRemoval.map { "Remove \($0.what) from \(playlist.name)?" } ?? "",
                        isPresented: Binding(
                            get: { pendingRemoval?.entries.first == entry.entryID },
                            set: { if !$0, pendingRemoval?.entries.first == entry.entryID { pendingRemoval = nil } }
                        ),
                        titleVisibility: .visible,
                        presenting: pendingRemoval
                    ) { removal in
                        Button("Remove", role: .destructive) {
                            pendingRemoval = nil
                            Task { await remove(entries: removal.entries) }
                        }
                        Button("Cancel", role: .cancel) { pendingRemoval = nil }
                    } message: { _ in
                        Text("This takes it out of the playlist. The song stays in your library.")
                    }
                }
                .onDelete { offsets in
                    ask(offsets)
                }
                .onMove { offsets, destination in
                    Task { await move(offsets, to: destination) }
                }
                if !hasEverything, !entries.isEmpty {
                    stillLoadingRow
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        // The list draws nothing of its own, so the page shows through.
        .scrollContentBackground(.hidden)
        .background { PageBackground(style: style, artwork: palette.palette) }
        // `PageBackground` carries its own unconditional `.ignoresSafeArea()`,
        // so dropping the page's leaves no bar at the top: the blur and the
        // colour still run edge to edge either way.
        .ignoresSafeArea(edges: metrics.standsSideBySide ? [] : .top)
        // Glass under the clock, arriving as the mosaic leaves — see `TopBlur`.
        .withoutScrollEdgeBlur(topToo: !metrics.standsSideBySide)
        .topBlurAsArtworkLeaves(!metrics.standsSideBySide)
        .trackingHeaderPull($headerPull, active: !metrics.standsSideBySide)
        // `containerSize` rather than `contentOffset`: it changes on a
        // rotation or a window resize only.
        .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in
            if size != pageSize { pageSize = size }
        }
        // The header states the name; a title in a transparent bar over
        // artwork is unreadable anyway. The chrome follows the artwork.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(activePalette.chromeScheme, for: .navigationBar)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        // Only while editing: a "Done" is worth a place in the bar, but an
        // "Edit" competing with the artwork is not — it lives in the menu
        // beside Play, where an album keeps everything it can do.
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { withAnimation { isEditing = false } }
                }
            }
        }
    }

    @ViewBuilder
    private var loadFailure: some View {
        if let message = loader?.error, entries.isEmpty {
            ContentUnavailableView {
                Label("Can't load playlist", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await retryLoad() } }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if metrics.standsSideBySide { wideHeader } else { immersiveHeader }
    }

    /// The mosaic as a card on the page rather than a picture the page is made of.
    private var wideHeader: some View {
        SideBySideHeader(
            artwork: playlist.artwork,
            palette: activePalette,
            placeholder: .music
        ) {
            wideDetails
        } about: { _ in
            // A playlist has no About.
            EmptyView()
        }
    }

    private var wideDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(playlist.name)
                .font(.system(size: 40, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(activePalette.foreground)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                // No shadow, unlike the narrow title. There it is lifting
                // words off four sleeves; here it would be a print fault.

            // Only where there is something to say.
            if !wideFacts.isEmpty {
                Text(wideFacts)
                    .font(.system(size: 17))
                    .foregroundStyle(activePalette.secondaryForeground)
                    .lineLimit(1)
                    .padding(.top, 6)
            }

            HeaderActionRow(
                layout: .labelled,
                onPlay: { play(from: nil) },
                onShuffle: { shuffleEverything() },
                alternativeShuffle: .offering(
                    smart: !app.settings.smartShuffleByDefault
                ) { shuffleEverything(smart: !app.settings.smartShuffleByDefault) },
                palette: activePalette,
                quietFill: 0.18,
                isDisabled: entries.isEmpty,
                bottomGap: 0,
                horizontalInset: 0,
                fixedWidth: metrics.actionRowWidth
            ) {
                playlistMenu
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How many and how long, on one line rather than the narrow header's two.
    private var wideFacts: String {
        var parts: [String] = []
        if let count = songCountText { parts.append(count) }
        if let length = lengthText { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    private var immersiveHeader: some View {
        ImmersiveHeader(
            artwork: playlist.artwork,
            palette: activePalette,
            fade: .playlist,
            // The details below are part of the same block as the name.
            titleBottom: 8,
            titleDrop: 4,
            dissolvesIntoBackground: style.usesBlurredBackground,
            placeholder: .music,
            pulledPast: headerPull
        ) {
            titleBlock
        } content: {
            detailsAndControls
        }
    }

    /// The playlist's name, written into the foot of the mosaic. The count
    /// and the length stand below it, beside the controls.
    private var titleBlock: some View {
        Text(playlist.name)
            .font(.system(size: 31, weight: .bold))
            .tracking(-0.62)
            .foregroundStyle(activePalette.foreground)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 1)
    }

    /// How many and how long, one under the other, with the controls at the end of the same two
    /// lines.
    private var detailsAndControls: some View {
        // No spacing of its own: the gap to the controls is the spacer's `minLength` and nothing
        // else.
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if let count = songCountText {
                    Text(count)
                        .font(.system(size: 15))
                        .foregroundStyle(activePalette.foreground)
                }
                if let length = lengthText {
                    Text(length)
                        .font(.system(size: 14.5))
                        .foregroundStyle(activePalette.secondaryForeground)
                }
            }
            // Comfortably clear of a forty-four point square without
            // taking a word off the line beside it.
            Spacer(minLength: 16)
            HeaderActionRow(
                layout: .compact,
                onPlay: { play(from: nil) },
                onShuffle: { shuffleEverything() },
                alternativeShuffle: .offering(
                    smart: !app.settings.smartShuffleByDefault
                ) { shuffleEverything(smart: !app.settings.smartShuffleByDefault) },
                palette: activePalette,
                quietFill: 0.18,
                isDisabled: entries.isEmpty
            ) {
                playlistMenu
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, HeaderFade.titleInset)
        .padding(.bottom, 18)
    }

    private var songCountText: String? {
        let count = loader?.songCount ?? playlist.trackCount ?? 0
        return count > 0 ? count.counted("song") : nil
    }

    private var lengthText: String? {
        trustedDuration.map(Duration.spoken)
    }

    /// Everything this playlist can do, in one place, the way an album page
    /// keeps its own menu beside Play.
    private var playlistMenu: some View {
        Menu {
            Group {
                // Opened from Downloads, or offline, the page is the phone's
                // copy and the download items above do not apply to it — but
                // taking the copy off the phone does.
                if !isServerList, app.downloads?.isRequested(.playlist(playlist.id)) == true {
                    Button("Remove Download", systemImage: "trash", role: .destructive) {
                        MediaActions(app: app).removeDownload(playlist: playlist)
                        dismiss()
                    }
                    Divider()
                }
                if app.downloads != nil, !entries.isEmpty, hasEverything, isServerList {
                    DownloadMenuItems(
                        kind: .playlist(playlist, tracks: tracks),
                        actions: MediaActions(app: app)
                    )
                    Divider()
                }
                // The whole running order, not what sorting put on screen:
                // this copies the playlist, and a copy in a different order
                // from the thing it was copied from is a different playlist.
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    app.requestAddToPlaylist(tracks)
                }
                .disabled(entries.isEmpty || !hasEverything || !isServerList)
                TopPinMenuItem(playlist: playlist, pins: app.playlistTopPins)
                PinMenuItem(item: PinnedItem(playlist: playlist), pins: app.pins)
                // Reordering sends the whole running order to the server, so it needs the whole
                // running order — and it needs to be looking at that same order, or a drag would
                // tell the server the songs live wherever sorting put them on screen.
                Button("Edit Order", systemImage: "arrow.up.arrow.down") {
                    withAnimation { isEditing = true }
                }
                // Offline too: a new running order is sent to the server, and there is no server.
                .disabled(
                    entries.isEmpty || !hasEverything
                        || app.settings.playlistTrackOrder != .default
                        || !isServerList
                )
                if entries.count > 1 {
                    Divider()
                    // Disabled while editing, not just gated on entry: this stops the sort from
                    // being *entered*, but a drag's reordered positions are read from `entries` too
                    // — a change of sort in the moment between opening Edit Order and actually
                    // dragging a row…
                    sortSection
                        .disabled(isEditing)
                }
            }
            // The tint below is for the button's own circle, and it is a washed-out version of the
            // page's colour.
            .tint(Color.primary)
        } label: {
            Image(systemName: "ellipsis")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    /// Same shape as the Downloads screen's own "Sort by" / "Order" pair —
    /// two sections rather than a submenu, so both choices are one tap away
    /// instead of a tap to open a second menu first.
    @ViewBuilder
    private var sortSection: some View {
        let order = app.settings.playlistTrackOrder
        Section("Sort by") {
            Picker("Sort by", selection: Binding(
                get: { order.field },
                set: { applySort(PlaylistTrackOrder(field: $0, ascending: order.ascending)) }
            )) {
                ForEach(PlaylistSongSort.allCases) { field in
                    Label(field.label, systemImage: field.symbol).tag(field)
                }
            }
            .pickerStyle(.inline)
        }
        Section {
            Picker("Order", selection: Binding(
                get: { order.ascending },
                set: { applySort(PlaylistTrackOrder(field: order.field, ascending: $0)) }
            )) {
                Text(order.field.directionLabel(ascending: true)).tag(true)
                Text(order.field.directionLabel(ascending: false)).tag(false)
            }
            .pickerStyle(.inline)
        }
    }

    /// Sorting by anything but the playlist's own order needs the whole playlist in hand — a page
    /// at a time cannot be told apart by artist or year until the rest has actually arrived, and
    /// songs would otherwise keep jumping to new places as more…
    private func applySort(_ order: PlaylistTrackOrder) {
        // Belt and suspenders alongside the disabled sort controls above:
        // whatever reaches this while a drag is possible is refused here
        // too, rather than trusting the UI alone to have kept the two apart.
        guard !isEditing else { return }
        app.settings.setPlaylistTrackOrder(order)
        guard order.field != .added, !hasEverything else { return }
        startFullLoad {}
    }

    /// The end of what has been fetched so far, on a playlist long enough
    /// that the rest is still coming.
    @ViewBuilder
    private var stillLoadingRow: some View {
        if let loader, loader.error != nil, !loader.isLoadingPage {
            // A page failed. The spinner stays away, or it turns for ever over
            // a load nothing is doing.
            Button {
                Task { await loader.retry() }
            } label: {
                Label("Couldn't load more — Retry", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(activePalette.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
            .listRowSeparator(.hidden)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(loader?.total.map { "\(entries.count.formatted()) of \($0.formatted())" }
                    ?? "Loading more…")
                    .font(.caption)
                    .foregroundStyle(activePalette.secondaryForeground)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
            .listRowSeparator(.hidden)
        }
    }

    private func fullLoadProgress(_ state: FullLoad) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(state.total.map { "Loading \(state.loaded.formatted()) of \($0.formatted())…" }
                ?? "Loading playlist…")
                .font(.subheadline)
            Button("Cancel") {
                fullLoad?.task?.cancel()
                fullLoad = nil
            }
            .font(.subheadline)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// A smart playlist's length is stale for the same reason its song count is — Plex reports what
    /// it was when the playlist was last written.
    private var trustedDuration: TimeInterval? {
        guard playlist.isSmart else {
            return loader?.header?.duration ?? playlist.duration
        }
        guard let loader, loader.hasEverything, loader.everyDurationKnown,
              loader.durationOfLoaded > 0 else { return nil }
        return loader.durationOfLoaded
    }

    // MARK: Playing

    /// Plays from the top, or from a tapped row.
    private func play(from entry: PlaylistEntry?) {
        let loaded = tracks
        guard !loaded.isEmpty else { return }
        let index = entry.flatMap { entry in entries.firstIndex(where: { $0.entryID == entry.entryID }) } ?? 0
        // Read once, before the load below suspends — see PlaybackDestination.
        let player = app.activePlayer
        player.play(loaded, startingAt: index, from: .playlist(loader?.header ?? playlist))
        guard let loader, !loader.hasEverything else { return }
        let mark = player.queueMark()
        Task {
            await loader.loadEverything()
            let rest = Array(loader.entries.dropFirst(loaded.count).map(\.track))
            // Only if this is still the queue we started. Appending sixty
            // thousand songs to whatever the listener has moved on to would
            // be a rude surprise.
            guard !rest.isEmpty else { return }
            player.append(rest, ifStill: mark)
        }
    }

    /// Shuffling half a playlist is not shuffling the playlist, so this waits
    /// for the whole thing.
    private func shuffleEverything(smart: Bool? = nil) {
        guard let loader else { return }
        let player = app.activePlayer
        guard !loader.hasEverything else {
            player.shuffle(tracks, startingWith: nil, from: .playlist(loader.header ?? playlist), smart: smart)
            return
        }
        // The whole playlist has to be here first: a smart shuffle weighs
        // what it can see, and shuffling the first page would quietly make
        // this "shuffle the beginning".
        startFullLoad { player.shuffle(tracks, startingWith: nil, from: .playlist(loader.header ?? playlist), smart: smart) }
    }

    /// Plays one song, then shuffles the rest of the playlist behind it — what a long press on a
    /// song offers, so getting this needs neither the tap, the open, nor the reach for Shuffle on
    /// the screen after that.
    private func shuffleFromHere(_ track: Track) {
        // The destination is fixed now, before the load below suspends:
        // read afterwards, a disconnect in between would start the queue on
        // This iPhone (see PlaybackDestination).
        let actions = MediaActions(app: app, destination: app.playbackDestination)
        guard let loader else { return }
        guard !loader.hasEverything else {
            actions.shuffle(tracks, startingWith: track, from: .playlist(loader.header ?? playlist))
            return
        }
        startFullLoad { actions.shuffle(tracks, startingWith: track, from: .playlist(loader.header ?? playlist)) }
    }

    private func startFullLoad(then finish: @escaping () -> Void) {
        // One at a time: a second tap would otherwise start a load that
        // finds the first one already holding the page, give up, and clear
        // the progress the first one is still making.
        guard let loader, fullLoad == nil else { return }
        fullLoad = FullLoad(loaded: loader.entries.count, total: loader.total, task: nil)
        let task = Task {
            let complete = await loader.loadEverything { loaded, total in
                fullLoad?.loaded = loaded
                fullLoad?.total = total
            }
            guard !Task.isCancelled else { return }
            fullLoad = nil
            if complete {
                finish()
            } else if let message = loader.error {
                // The progress card would otherwise just vanish, and the
                // tap that started it look ignored.
                app.showTransientError(message)
            }
        }
        fullLoad?.task = task
    }

    // MARK: Editing

    /// Asks before removing, wherever the request came from.
    private func ask(_ offsets: IndexSet) {
        guard isServerList else { return }
        let chosen = offsets.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        guard !chosen.isEmpty else { return }
        pendingRemoval = PendingRemoval(
            entries: chosen.map(\.entryID),
            what: chosen.count == 1 ? chosen[0].track.title : chosen.count.counted("song")
        )
    }

    /// Takes songs out of the playlist. The list is asked again afterwards,
    /// so what is on screen is what the server has — either way, since a
    /// conflict means it moved on and a success still moved it.
    private func remove(entries doomed: [PlaylistEntryID]) async {
        guard let store, !doomed.isEmpty else { return }
        _ = await store.remove(entries: doomed, from: playlist)
        await reloadEntries()
    }

    private func move(_ offsets: IndexSet, to destination: Int) async {
        var reordered = entries
        reordered.move(fromOffsets: offsets, toOffset: destination)
        guard let store else { return }
        _ = await store.reorder(playlist, orderedEntries: reordered.map(\.entryID))
        await reloadEntries()
    }

    private func load() async {
        if store == nil {
            store = PlaylistStore(app: app)
        }
        if let loader {
            // Already built.
            guard loaderIsPhoneCopy, !readsFromPhone else {
                await loader.start()
                await fetchRestIfSmall()
                return
            }
            self.loader = nil
        }

        // Playlists live on the server, but a kept one lives here too.
        let source: (any PlaylistPageSource)?
        let kept = readsFromPhone ? (app.downloads?.tracks(inDownloadedPlaylist: playlist.id) ?? []) : []
        if !kept.isEmpty {
            source = DownloadedPlaylistSource(playlist: playlist, tracks: kept)
        } else if app.isOffline {
            // Offline with nothing kept: there is no server to ask and
            // nothing to show — the page says so.
            return
        } else {
            source = app.provider
        }

        let loader = PlaylistLoader(
            playlist: playlist,
            source: source,
            store: kept.isEmpty ? app.playlistPageStore : nil
        )
        loaderIsPhoneCopy = !kept.isEmpty
        self.loader = loader
        await loader.start()
        await fetchRestIfSmall()
    }

    /// After a failed first load: asks the same loader again, or builds one
    /// if there never was one. Also what pulling the page down does.
    private func retryLoad() async {
        guard let loader else {
            await load()
            return
        }
        if loader.error != nil {
            await loader.retry()
        } else if loaderIsPhoneCopy, !readsFromPhone {
            await load()
            return
        } else {
            // A healthy server list has nothing to refresh, and starting it
            // over would throw away every page paged in so far.
            return
        }
        await fetchRestIfSmall()
    }

    /// Starts the list again after an edit, and — for a playlist short enough to hold whole —
    /// fetches all of it again.
    private func reloadEntries() async {
        await loader?.reload()
        await fetchRestIfSmall()
    }

    /// Ordinary playlists finish arriving on their own, so everything that
    /// needs the whole list has it without anyone asking.
    private func fetchRestIfSmall() async {
        guard let loader, let total = loader.total,
              total <= Self.fetchWholeUpTo, !loader.hasEverything else { return }
        await loader.loadEverything()
    }
}

/// One song in a playlist, and everything a long press on it can do.
private struct PlaylistTrackRow: View, Equatable {
    let entry: PlaylistEntry
    let isCurrent: Bool
    let palette: ArtworkPalette
    let actions: MediaActions
    let play: () -> Void
    let shuffleRest: () -> Void
    let goToAlbum: (() -> Void)?
    let goToArtist: (() -> Void)?

    /// Compared off the main actor — everything compared is a value, and
    /// `EquatableView` asks from wherever it is drawing.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry
            && lhs.isCurrent == rhs.isCurrent
            && lhs.palette == rhs.palette
            // Whether the menu offers these at all is part of what it draws;
            // which page they open is not, and cannot change under a row
            // that is still about the same song.
            && (lhs.goToAlbum == nil) == (rhs.goToAlbum == nil)
            && (lhs.goToArtist == nil) == (rhs.goToArtist == nil)
    }

    var body: some View {
        TrackRow(
            track: entry.track,
            isCurrent: isCurrent,
            showsRating: true,
            showsPosition: false,
            showsArtwork: true,
            palette: palette
        )
        // On the row, not behind it: a clear layer behind only catches the touches that miss
        // everything, and text is opaque to hit-testing, so tapping a song's title landed on the
        // title and stopped there.
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .trackContextMenu(
            entry.track,
            actions: actions,
            onShuffleRest: shuffleRest,
            onGoToAlbum: goToAlbum,
            onGoToArtist: goToArtist
        )
    }
}


/// Fetches a playlist's first page once its row has stayed on screen for half
/// a second, so tapping it opens with the songs already in hand. A row that
/// scrolls straight past cancels the wait and asks for nothing.
private struct WarmsPlaylist: ViewModifier {
    @Environment(AppModel.self) private var app
    let playlist: Playlist

    func body(content: Content) -> some View {
        content.task(id: playlist.id) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await app.warmPlaylist(playlist)
        }
    }
}

extension View {
    func warmsPlaylist(_ playlist: Playlist) -> some View {
        modifier(WarmsPlaylist(playlist: playlist))
    }
}
