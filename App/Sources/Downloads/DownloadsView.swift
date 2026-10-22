import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// The phone's own library: everything kept for offline, browsed the way the server's library is.
struct DownloadsView: View {
    enum Shelf: String, CaseIterable, Identifiable {
        case artists
        case albums
        case songs
        case playlists

        var id: String { rawValue }

        var label: String {
            switch self {
            case .artists: "Artists"
            case .albums: "Albums"
            case .songs: "Songs"
            case .playlists: "Playlists"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @State private var shelf: Shelf = .albums
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    @State private var songs: [Track] = []
    @State private var inProgress: [Track] = []
    /// Songs that gave up. Kept apart from `inProgress`: a failed song is not
    /// coming, and listing it under "Downloading N songs" left a strip that
    /// never cleared and a Stop that did nothing to it.
    @State private var failedSongs: [Track] = []
    @State private var playlists: [DownloadedPlaylistRecord] = []
    /// What the other libraries have kept, read when the screen opens and when
    /// the library changes rather than on every transfer that moves: it is a
    /// walk of their tables and their folders. Empty unless the setting is on.
    @State private var siblings: [AppModel.SiblingDownloads] = []
    @State private var usage: Int64 = 0
    /// How many songs the figure above was worked out for.
    @State private var usageForCount = -1
    @State private var confirmingRemoveAll = false
    @State private var snapshotTask: Task<Void, Never>?

    private var manager: DownloadManager? { app.downloads }
    private var actions: MediaActions { MediaActions(app: app) }

    private static let gridSpacing: CGFloat = 10

    /// Says what is holding the queue up, and offers the one way past it that is not a trip to
    /// Settings.
    private var heldForWiFi: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for Wi-Fi")
                    .font(.subheadline.weight(.semibold))
                Text("Downloading over mobile data is off in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Download Anyway") {
                app.downloads?.downloadAnyway()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $shelf) {
                    ForEach(Shelf.allCases) { shelf in
                        Text(shelf.label).tag(shelf)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.bottom, 8)

                if app.downloads?.isWaitingForNetwork == true {
                    heldForWiFi
                }

                if !inProgress.isEmpty {
                    downloadingStrip
                }

                shelfContent
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !songs.isEmpty || !inProgress.isEmpty || !failedSongs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            // Stopping and removing are different things, and until now only the
                            // second existed: calling off a download meant throwing away the songs
                            // that had already arrived with it.
                            if manager?.isDownloading == true {
                                Button("Stop Downloading", systemImage: "stop.circle") {
                                    manager?.stopDownloading()
                                    reload()
                                }
                            }
                            if !playlists.isEmpty {
                                Button("Refresh Playlists", systemImage: "arrow.clockwise") {
                                    Task { await refreshPlaylists() }
                                }
                            }
                            sortSection
                            Section("\(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file)) on this phone") {
                                Button("Remove All Downloads", systemImage: "trash", role: .destructive) {
                                    confirmingRemoveAll = true
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        // On the button it came from, so the question rises
                        // from the menu that asked it.
                        .confirmationDialog(
                            "Remove every download?",
                            isPresented: $confirmingRemoveAll,
                            titleVisibility: .visible
                        ) {
                            Button("Remove All", role: .destructive) {
                                manager?.removeEverything()
                                reload()
                            }
                        } message: {
                            Text("The files go; nothing on the server is touched.")
                        }
                    }
                }
            }
            // Pull to bring the downloaded playlists up to date with the
            // server: songs added since arrive, songs taken out go.
            .refreshable { await refreshPlaylists() }
            // Opened from here, a record or an artist is only what is on
            // the phone. The same screens reached from Library show
            // everything, which is what Library is for.
            .navigationDestination(for: Album.self) {
                AlbumDetailView(album: $0, downloadedOnly: true)
            }
            .navigationDestination(for: Artist.self) {
                ArtistDetailView(artist: $0, downloadedOnly: true)
            }
            .navigationDestination(for: SimilarArtistsRoute.self) { SimilarArtistsListView(route: $0) }
            .navigationDestination(for: DownloadedPlaylistLink.self) { link in
                // The same screen every other playlist gets — header, artwork, play and shuffle,
                // ratings — rather than a bare list standing in for it.
                PlaylistDetailView(
                    playlist: Playlist(
                        id: link.id,
                        name: link.name,
                        artwork: link.artwork
                    ),
                    downloadedOnly: true
                )
            }
            .overlay {
                if isEmpty, !awaitingRecords {
                    ContentUnavailableView {
                        Label("Nothing downloaded", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Hold an album, a song, a playlist or an artist and choose Download to keep it on this phone.")
                    }
                }
            }
            // The manager's counter changes whenever a transfer moves, so the
            // screen follows without polling.
            .task(id: "\(manager?.version ?? -1)|\(manager?.hasReadRecords ?? false)") { reload() }
            .task(id: "\(app.libraryVersion)|\(app.libraryIndex?.server.rawValue.uuidString ?? "")|\(app.settings.mergesDownloads)") {
                siblings = app.siblingDownloads()
                reload()
            }
        }
    }

    /// Ordering, for the shelf being looked at.
    @ViewBuilder
    private var sortSection: some View {
        let order = app.settings.downloadOrder(for: shelf.rawValue)

        if shelf != .artists {
            Section("Sort by") {
                Picker("Sort by", selection: Binding(
                    get: { order.field },
                    set: {
                        app.settings.setDownloadOrder(
                            DownloadOrder(field: $0, ascending: order.ascending),
                            for: shelf.rawValue
                        )
                        reload()
                    }
                )) {
                    ForEach(DownloadSort.allCases) { field in
                        Label(field.label, systemImage: field.symbol).tag(field)
                    }
                }
                .pickerStyle(.inline)
            }
        }

        Section {
            Picker("Order", selection: Binding(
                get: { order.ascending },
                set: {
                    app.settings.setDownloadOrder(
                        DownloadOrder(field: order.field, ascending: $0),
                        for: shelf.rawValue
                    )
                    reload()
                }
            )) {
                Text(order.field.directionLabel(ascending: true)).tag(true)
                Text(order.field.directionLabel(ascending: false)).tag(false)
            }
            .pickerStyle(.inline)
        }
    }

    /// A library is open but its downloads have not been read yet: what the
    /// lists say is not an answer, and "Nothing downloaded" over it would be
    /// a false one.
    private var awaitingRecords: Bool {
        app.libraryIndex != nil && manager?.hasReadRecords != true
    }

    private var isEmpty: Bool {
        songs.isEmpty && inProgress.isEmpty && failedSongs.isEmpty && playlists.isEmpty
    }

    // MARK: What is still coming

    private var downloadingStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(inProgress.count == 1 ? "Downloading 1 song" : "Downloading \(inProgress.count) songs")
                    .font(.footnote.weight(.medium))
                Spacer()
                Button("Show") { shelf = .songs }
                    .font(.footnote)
                    .opacity(shelf == .songs ? 0 : 1)
                // Shown when the count says songs are coming and nothing is actually moving.
                if manager?.isStalled == true {
                    Button("Resume") {
                        Task {
                            await manager?.restartQueue()
                            reload()
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.leading, 14)
                }
                // Beside the thing it stops rather than behind a menu: this is where anyone who
                // wants a download to stop is already looking.
                Button("Stop") {
                    manager?.stopDownloading()
                    reload()
                }
                .font(.footnote.weight(.medium))
                .padding(.leading, 14)
            }
            ProgressView(value: manager?.batchProgress ?? 0)
                .tint(.accentColor)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: The four ways in

    @ViewBuilder
    private var shelfContent: some View {
        switch shelf {
        case .artists: artistList
        case .albums: albumGrid
        case .songs: songList
        case .playlists: playlistList
        }
    }

    private var artistList: some View {
        List(artists) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    ArtworkView(
                        artwork: artist.artwork,
                        size: CompactList.thumbnailSize,
                        cornerRadius: CompactList.thumbnailSize / 2,
                        placeholder: .artist
                    )
                    Text(artist.name).lineLimit(1)
                    LibraryBadge(titles: app.siblingLibraryTitles, server: artist.id.server)
                }
            }
            .listRowInsets(CompactList.rowInsets)
            .artistContextMenu(artist, actions: actions)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollIndicators(.hidden)
        .overlay {
            if artists.isEmpty && !isEmpty {
                ContentUnavailableView("No artists yet", systemImage: "music.mic")
            }
        }
    }

    private var albumGrid: some View {
        ScrollView {
            MeasuredWidth { width in
                let metrics = AlbumGridMetrics(
                    availableWidth: width,
                    columns: app.settings.albumColumns,
                    spacing: Self.gridSpacing
                )
                LazyVGrid(columns: metrics.gridItems, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album, size: metrics.itemWidth, actions: actions)
                                .overlay(alignment: .topLeading) {
                                    LibraryBadge(titles: app.siblingLibraryTitles, server: album.id.server)
                                        .padding(6)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .overlay {
            if albums.isEmpty && !isEmpty {
                ContentUnavailableView("No albums yet", systemImage: "square.stack")
            }
        }
    }

    private var songList: some View {
        List {
            // Sections only when there is something to tell apart. An empty
            // header still takes a header's worth of room, which reads as the
            // list starting halfway down the screen.
            if !failedSongs.isEmpty {
                Section {
                    ForEach(failedSongs) { track in
                        failedRow(track)
                    }
                } header: {
                    HStack {
                        Text(failedSongs.count == 1 ? "Did not download" : "Did not download (\(failedSongs.count))")
                        Spacer()
                        Button("Try All Again") {
                            Task {
                                await manager?.retryFailed()
                                reload()
                            }
                        }
                        .font(.footnote.weight(.medium))
                        .textCase(nil)
                    }
                }
            }
            if inProgress.isEmpty {
                ForEach(songs) { track in
                    songRow(track, isWaiting: false)
                }
            } else {
                // No heading on this one.
                Section {
                    ForEach(inProgress) { track in
                        songRow(track, isWaiting: true)
                    }
                }
                if !songs.isEmpty {
                    Section {
                        ForEach(songs) { track in
                            songRow(track, isWaiting: false)
                        }
                    } header: {
                        onThisPhoneHeader
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollIndicators(.hidden)
    }

    /// The heading for the songs that have finished, with a wash of its own.
    private var onThisPhoneHeader: some View {
        Text("On this phone")
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Rectangle()
                    .fill(.regularMaterial)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: .white, location: 0.16),
                                .init(color: .white, location: 0.72),
                                .init(color: .white.opacity(0), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.horizontal, -60)
                    .padding(.top, -12)
                    .padding(.bottom, -22)
                    .allowsHitTesting(false)
            }
    }

    /// Wide enough for "Waiting", the longest thing the trailing slot says.
    private static let progressColumn: CGFloat = 50

    @ViewBuilder
    private func songRow(_ track: Track, isWaiting: Bool) -> some View {
        let state = manager?.state(for: track.id)
        HStack(spacing: 12) {
            ArtworkView(artwork: track.artwork, size: 40, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(track.artistName ?? track.albumName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Group {
                    if state?.isRunning == true {
                        // Indeterminate where the size is unknown, which for
                        // a conversion is always: a bar pinned at nothing
                        // reads as a download that is stuck.
                        if let fraction = manager?.fraction(for: track.id) {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    } else {
                        // The same bar, drawn as nothing, so the row is the height it will be when
                        // its turn comes.
                        ProgressView(value: 0)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }
                .progressViewStyle(.linear)
                .tint(.accentColor)
            }
            Spacer(minLength: 0)
            LibraryBadge(titles: app.siblingLibraryTitles, server: track.id.server)
            switch state {
            case .queued:
                Text("Waiting").font(.caption).foregroundStyle(.secondary)
                    .frame(width: Self.progressColumn, alignment: .trailing)
            case .running:
                Text(manager?.fraction(for: track.id).map { "\(Int($0 * 100))%" } ?? "…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    // The same width for every state it passes through, so the title beside it is
                    // cut in the same place from "Waiting" to "100%" instead of growing and
                    // shrinking with each figure.
                    .frame(width: Self.progressColumn, alignment: .trailing)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(message)
            case .done, .none:
                EmptyView()
            }
        }
        .listRowInsets(CompactList.rowInsets)
        .contentShape(Rectangle())
        .onTapGesture {
            // A song that is not here yet has nothing to play.
            guard !isWaiting else { return }
            let start = songs.firstIndex { $0.id == track.id } ?? 0
            // Loose downloaded songs, not a playlist — this claimed to be
            // one, which meant it followed the wrong Smart Continue setting
            // and would now record a playlist that does not exist.
            app.activePlayer.play(songs, startingAt: start, from: .songs)
        }
        .trackContextMenu(
            track,
            actions: actions,
            onGoToAlbum: track.albumID.map { id in
                { app.requestNavigation(.album(id, name: track.albumName)) }
            },
            onGoToArtist: track.artistID.map { id in
                { app.requestNavigation(.artist(id, name: track.artistName)) }
            }
        )
        .swipeActions(edge: .trailing) {
            Button(isWaiting ? "Cancel" : "Remove", systemImage: "trash", role: .destructive) {
                actions.removeDownload(track: track)
                reload()
            }
        }
    }

    /// A song that could not be fetched, with why, and a way to try again.
    /// The reason used to exist only as a spoken label on a bare warning
    /// triangle, and a tap did nothing.
    private func failedRow(_ track: Track) -> some View {
        var message = "Download failed."
        if case .failed(let said)? = manager?.state(for: track.id) { message = said }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Button("Try Again") {
                Task {
                    await manager?.retryFailed([track.id])
                    reload()
                }
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.borderless)
        }
        .listRowInsets(CompactList.rowInsets)
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                manager?.remove(track: track.id)
                reload()
            }
        }
    }

    /// The playlist's own picture while it is on the phone or there is a
    /// connection to fetch it; otherwise the picture of its first kept song.
    private func playlistPicture(_ link: DownloadedPlaylistLink) -> ArtworkID? {
        guard app.isOffline, let own = link.artwork, let loader = app.artwork, !loader.isOnPhone(own) else {
            return link.artwork
        }
        return app.downloads?.tracks(inDownloadedPlaylist: link.id).first?.artwork ?? own
    }

    private var playlistList: some View {
        List(playlists, id: \.id) { playlist in
            let link = DownloadedPlaylistLink(
                id: MediaID(server: app.libraryIndex?.server ?? ServerID(), rawValue: playlist.id),
                name: playlist.name,
                artwork: playlist.artworkId.map { ArtworkID(server: app.libraryIndex?.server ?? ServerID(), rawValue: $0) }
            )
            NavigationLink(value: link) {
                HStack(spacing: 12) {
                    // The playlist's own picture, or — where that is not on the phone, as it is not
                    // after the artwork cache has been cleared with no connection — the picture of
                    // its first kept song, which the downloads hold for themselves.
                    ArtworkView(artwork: playlistPicture(link), size: CompactList.thumbnailSize)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playlist.name).lineLimit(1)
                        // A playlist the server no longer has is kept — it may be the only copy
                        // left — but it has stopped tracking anything, and one that has quietly
                        // stopped tracking looks exactly like one that is up to date.
                        if playlist.missingFromServer {
                            Label("Not on the server any more", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(playlist.tracks.count.counted("song"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowInsets(CompactList.rowInsets)
            .contextMenu {
                NavigationLink("Open", value: link)
                Button("Play", systemImage: "play.fill") {
                    playDownloaded(link, shuffled: false)
                }
                Button("Shuffle", systemImage: "shuffle") {
                    playDownloaded(link, shuffled: true)
                }
                Divider()
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    manager?.remove(reason: .playlist(link.id))
                    reload()
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    manager?.remove(reason: .playlist(link.id))
                    reload()
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollIndicators(.hidden)
        .overlay {
            if playlists.isEmpty && !isEmpty {
                ContentUnavailableView(
                    "No playlists yet",
                    systemImage: "music.note.list",
                    description: Text("Download one from its own page and it is kept whole — name, order and all.")
                )
            }
        }
    }

    /// Plays what is kept of a downloaded playlist, without opening it.
    private func playDownloaded(_ link: DownloadedPlaylistLink, shuffled: Bool) {
        let songs = manager?.tracks(inDownloadedPlaylist: link.id) ?? []
        guard !songs.isEmpty else { return }
        let source = Playlist(id: link.id, name: link.name, artwork: link.artwork)
        if shuffled {
            app.activePlayer.shuffle(songs, startingWith: nil, from: .playlist(source), smart: nil)
        } else {
            app.activePlayer.play(songs, startingAt: 0, from: .playlist(source))
        }
    }

    // MARK: Reading

    private func reload() {
        guard let manager, manager.hasReadRecords, let index = app.libraryIndex else {
            // The manager arrives, and reads its table, some seconds after the screen can be opened
            // on a launch.
            if let index = app.libraryIndex, let remembered = DownloadsSnapshot.load(for: index.server) {
                artists = remembered.artists
                albums = remembered.albums
                songs = remembered.songs
                playlists = remembered.playlists
                inProgress = []; failedSongs = []
            } else {
                artists = []; albums = []; songs = []; inProgress = []; failedSongs = []; playlists = []
            }
            return
        }
        var kept: [Track] = []
        var coming: [Track] = []
        var failed: [Track] = []
        let partition = DownloadManager.partition(manager.states)
        for id in partition.kept {
            if let track = manager.track(id) { kept.append(track) }
        }
        for id in partition.active {
            if let track = manager.track(id) { coming.append(track) }
        }
        for id in partition.failed {
            if let track = manager.track(id) { failed.append(track) }
        }
        let newFailed = failed.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if failedSongs != newFailed { failedSongs = newFailed }
        // What the other libraries under Quick Switch have kept, when the
        // setting asks for one list. A song also kept by this library's own
        // table is listed once, from this one.
        let others = siblings
        var haveRaw = Set(kept.map(\.id.rawValue))
        for other in others {
            for song in other.songs where haveRaw.insert(song.id.rawValue).inserted {
                kept.append(song)
            }
        }
        // Each list is written only when it differs.
        let newSongs = sorted(kept, asked: manager.requestedAt())
        if songs != newSongs { songs = newSongs }
        // In the order they will actually arrive, not alphabetically.
        let asked = manager.requestedAt()
        let newInProgress = coming.sorted { first, second in
            let firstRunning = manager.state(for: first.id)?.isRunning ?? false
            let secondRunning = manager.state(for: second.id)?.isRunning ?? false
            if firstRunning != secondRunning { return firstRunning }
            let firstAsked = asked[first.id] ?? .distantFuture
            let secondAsked = asked[second.id] ?? .distantFuture
            if firstAsked != secondAsked { return firstAsked < secondAsked }
            // Two asked for in the same breath — a whole album arrives with
            // one timestamp — so they fall back to the order they play in.
            return (first.discNumber ?? 1, first.trackNumber ?? 0, first.title)
                < (second.discNumber ?? 1, second.trackNumber ?? 0, second.title)
        }
        if inProgress != newInProgress { inProgress = newInProgress }
        // Only what was asked for by name: a playlist's songs come from
        // records all over the library, and listing those would fill Albums
        // with things you have three songs of.
        let shelves = app.downloadedShelves(including: others)
        let newArtists = sortedArtists(shelves.artists)
        if artists != newArtists { artists = newArtists }
        let newAlbums = sortedAlbums(shelves.albums)
        if albums != newAlbums { albums = newAlbums }
        let newPlaylists = manager.downloadedPlaylists()
        if playlists != newPlaylists { playlists = newPlaylists }
        // The figure in the menu's heading, which is redrawn — and the menu
        // with it, if it is open — whenever it changes. Worked out again when
        // the set of songs on the phone changes, not as bytes arrive.
        if usageForCount != kept.count {
            usageForCount = kept.count
            Task { usage = await manager.usageOffMainActor() }
        }
        // Written once things have been still for a moment: this runs on
        // every transfer that moves, and encoding every song that often is
        // work for nobody.
        let snapshot = DownloadsSnapshot(artists: artists, albums: albums, songs: songs, playlists: playlists)
        let server = index.server
        snapshotTask?.cancel()
        snapshotTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            snapshot.save(for: server)
        }
    }

    /// Songs in whichever order was asked for.
    private func inOrder<T>(_ items: [T], _ order: DownloadOrder, by ascending: (T, T) -> Bool) -> [T] {
        let sorted = items.sorted(by: ascending)
        return order.ascending ? sorted : sorted.reversed()
    }

    private func sorted(_ tracks: [Track], asked: [MediaID: Date]) -> [Track] {
        let order = app.settings.downloadOrder(for: Shelf.songs.rawValue)
        switch order.field {
        case .recentlyDownloaded:
            return inOrder(tracks, order) {
                (asked[$0.id] ?? .distantPast, $0.title) < (asked[$1.id] ?? .distantPast, $1.title)
            }
        case .title:
            return inOrder(tracks, order) {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .artist:
            // Within an artist, back to the order the songs play in — a
            // record read out alphabetically is a record you cannot follow.
            return inOrder(tracks, order) {
                let left = ($0.artistName ?? "", $0.albumName ?? "")
                let right = ($1.artistName ?? "", $1.albumName ?? "")
                if left != right { return left < right }
                return ($0.discNumber ?? 1, $0.trackNumber ?? 0, $0.title)
                    < ($1.discNumber ?? 1, $1.trackNumber ?? 0, $1.title)
            }
        }
    }

    private func sortedAlbums(_ albums: [Album]) -> [Album] {
        let order = app.settings.downloadOrder(for: Shelf.albums.rawValue)
        switch order.field {
        case .recentlyDownloaded:
            // Records have no fetch date of their own — what was downloaded
            // is songs — so the newest record is the one holding the newest
            // song, which is the same thing said from the other end.
            let newest = newestSongDatePerAlbum(asked: manager?.requestedAt() ?? [:])
            return inOrder(albums, order) {
                (newest[$0.id] ?? .distantPast, $0.name) < (newest[$1.id] ?? .distantPast, $1.name)
            }
        case .title:
            return inOrder(albums, order) {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .artist:
            return inOrder(albums, order) {
                let left = ($0.artistName ?? "", $0.year ?? 0)
                let right = ($1.artistName ?? "", $1.year ?? 0)
                if left != right { return left < right }
                return $0.displayName < $1.displayName
            }
        }
    }

    private func sortedArtists(_ artists: [Artist]) -> [Artist] {
        let order = app.settings.downloadOrder(for: Shelf.artists.rawValue)
        // An artist has no date of their own and no artist of their own, so
        // whichever field is chosen there is only one thing to sort on —
        // their name. The direction still means something, and is kept.
        return inOrder(artists, order) {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func newestSongDatePerAlbum(asked: [MediaID: Date]) -> [MediaID: Date] {
        var newest: [MediaID: Date] = [:]
        for track in songs {
            guard let album = track.albumID, let when = asked[track.id] else { continue }
            if when > (newest[album] ?? .distantPast) { newest[album] = when }
        }
        return newest
    }

    private func refreshPlaylists() async {
        await manager?.refreshDownloadedPlaylists()
        reload()
    }
}

/// A downloaded playlist as a navigation value.
struct DownloadedPlaylistLink: Hashable {
    let id: MediaID
    let name: String
    let artwork: ArtworkID?
}


/// What the Downloads screen last showed for a library, kept on disk so the next launch can draw it
/// before the download manager has read its table.
struct DownloadsSnapshot: Codable {
    var artists: [Artist]
    var albums: [Album]
    var songs: [Track]
    var playlists: [DownloadedPlaylistRecord]

    private static func file(for server: ServerID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DownloadsSnapshot", directoryHint: .isDirectory)
            .appending(path: "\(server.rawValue.uuidString).json")
    }

    static func load(for server: ServerID) -> DownloadsSnapshot? {
        guard let data = try? Data(contentsOf: file(for: server)) else { return nil }
        return try? JSONDecoder().decode(DownloadsSnapshot.self, from: data)
    }

    func save(for server: ServerID) {
        let file = Self.file(for: server)
        let copy = self
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(copy) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
    }
}
