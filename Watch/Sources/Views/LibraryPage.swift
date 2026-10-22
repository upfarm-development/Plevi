import SwiftUI
import PleviDomain

/// Library, and Downloads, which are the same screen.
struct LibraryPage: View {
    let downloadedOnly: Bool

    @Environment(WatchModel.self) private var model

    var body: some View {
        List {
            if downloadedOnly {
                // Above the shelves while there is one, because it is the thing happening now.
                if let downloads = model.downloads, downloads.queueCount > 0 {
                    NavigationLink(value: Destination.queue) {
                        DownloadProgressRow(downloads: downloads)
                    }
                    .listRowBackground(Color.clear)
                }
                // Playlists come first here, because a downloaded playlist is
                // the thing most people put on the watch in the first place.
                NavigationLink(value: Destination.playlists) {
                    WatchRow(title: "Playlists", systemImage: "music.note.list")
                }
                NavigationLink(value: Destination.artists) {
                    WatchRow(title: "Artists", systemImage: "music.mic")
                }
                NavigationLink(value: Destination.albums) {
                    WatchRow(title: "Albums", systemImage: "square.stack")
                }
            } else {
                NavigationLink(value: Destination.playlists) {
                    WatchRow(title: "Playlists", systemImage: "music.note.list")
                }
                NavigationLink(value: Destination.artists) {
                    WatchRow(title: "Artists", systemImage: "music.mic")
                }
                NavigationLink(value: Destination.albums) {
                    WatchRow(title: "Albums", systemImage: "square.stack")
                }
                NavigationLink(value: Destination.justAdded) {
                    WatchRow(title: "Just Added", systemImage: "plus.square")
                }
                NavigationLink(value: Destination.recentlyPlayed) {
                    WatchRow(title: "Recently Played", systemImage: "clock.arrow.circlepath")
                }
                // Here as well as on Downloads.
                failuresLink
            }

            if downloadedOnly {
                // Songs that did not arrive, said out loud.
                failuresLink
                // Gated on what is owed rather than on what is moving.
                DownloadedTally()
            }
        }
        .navigationTitle(downloadedOnly ? "Downloads" : "Library")
        // On Library as well as Downloads, because they are one screen and a
        // download is most often started from the Library side — holding a
        // record there and choosing Download, then wanting to know it took.
        .watchDownloadRing(model.downloads)
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .artists: LetterIndexList(kind: .artists, downloadedOnly: downloadedOnly)
            case .albums: LetterIndexList(kind: .albums, downloadedOnly: downloadedOnly)
            case .justAdded: AlbumsList(downloadedOnly: downloadedOnly, filter: .justAdded)
            case .playlists: PlaylistsList(downloadedOnly: downloadedOnly)
            case .recentlyPlayed: RecentlyPlayedList()
            case .failures: DownloadFailuresPage()
            case .queue: DownloadQueuePage()
            }
        }
        .navigationDestination(for: LetterScope.self) { scope in
            switch scope.kind {
            case .artists:
                ArtistsList(downloadedOnly: scope.downloadedOnly, initials: scope.initials)
                    .navigationTitle(scope.bucket)
            case .albums:
                AlbumsList(
                    downloadedOnly: scope.downloadedOnly, filter: .all, initials: scope.initials
                )
                .navigationTitle(scope.bucket)
            }
        }
        .navigationDestination(for: Album.self) { album in
            AlbumPage(album: album, downloadedOnly: downloadedOnly)
        }
        .navigationDestination(for: Artist.self) { artist in
            ArtistPage(artist: artist, downloadedOnly: downloadedOnly)
        }
        .navigationDestination(for: Playlist.self) { playlist in
            PlaylistTracksPage(playlist: playlist, downloadedOnly: downloadedOnly)
        }
    }

    /// Songs that did not arrive, said out loud.
    @ViewBuilder
    private var failuresLink: some View {
        if let downloads = model.downloads, downloads.failureCount > 0 {
            NavigationLink(value: Destination.failures) {
                DownloadFailureRow(downloads: downloads)
            }
        }
    }

    enum Destination: Hashable {
        case artists
        case albums
        case justAdded
        case playlists
        case recentlyPlayed
        case failures
        case queue
    }
}

/// The way into the queue, on the Downloads page.
struct DownloadProgressRow: View {
    let downloads: WatchDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Image(systemName: downloads.isPaused ? "pause.circle" : "arrow.down.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                Text(heading)
                    .font(.system(size: 17))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(downloads.queueTally)
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Hidden while nothing is moving. A determinate bar sitting
            // perfectly still under the word Paused is the thing a stationary
            // bar always reads as, which is stuck.
            if !downloads.isPaused, !downloads.isStalled {
                ProgressView(value: downloads.progress ?? 0)
                    .tint(.accentColor)
            }
        }
        .frame(minHeight: WatchMetrics.row)
        .contentShape(Rectangle())
    }

    private var heading: String {
        if downloads.isPaused { return "Paused" }
        if downloads.isStalled { return "Stopped" }
        return "Downloading"
    }
}

/// What did not download, in one line, with the rest a tap away.
struct DownloadFailureRow: View {
    let downloads: WatchDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            if let first = downloads.firstFailureMessage {
                Text(first)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var headline: String {
        let count = downloads.failureCount
        return count == 1 ? "1 song did not download" : "\(count) songs did not download"
    }
}

/// Which songs did not arrive, and what stopped each one.
struct DownloadFailuresPage: View {
    @Environment(WatchModel.self) private var model

    /// Read into state rather than from the body: `failures` goes to the
    /// database once per failed song, and a `List` asks its rows for their
    /// content far more often than that is worth paying for.
    @State private var failures: [WatchDownloads.Failure] = []

    var body: some View {
        List {
            // A way back.
            if !failures.isEmpty, let downloads = model.downloads {
                Button {
                    Task { await downloads.retryFailures() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: WatchMetrics.pill)
                }
                .buttonStyle(.plain)
                .background(.tint, in: Capsule())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
            }
            if failures.isEmpty {
                WatchEmptyView(
                    title: "Nothing failed",
                    detail: "Every song asked for is on this watch.",
                    systemImage: "checkmark.circle"
                )
            }
            ForEach(failures) { failure in
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title)
                        .font(.system(size: 14, weight: .semibold))
                    if let artist = failure.artist {
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text(failure.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Did Not Download")
        .task(id: model.downloads?.queueKey ?? "none") {
            failures = model.downloads?.failures ?? []
        }
    }
}

/// What is actually on this watch, counted rather than weighed.
struct DownloadedTally: View {
    @Environment(WatchModel.self) private var model
    @State private var songs = 0
    @State private var bytes: Int64 = 0

    var body: some View {
        Group {
            if songs == 0 {
                WatchEmptyView(
                    title: "Nothing downloaded",
                    detail: "Hold a record, an artist or a playlist and choose Download to keep it here.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        // The song count is a cheap query and follows every arrival.
        .task(id: model.downloadsKey) { songs = model.library?.downloadedTrackIDs().count ?? 0 }
        // Keyed on the arrivals now, like the count beside it, but made to wait first.
        .task(id: model.downloadsKey) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            bytes = await model.downloads?.usageOffMainActor() ?? 0
        }
    }

    private var line: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(songs.counted("song")) on this watch · \(size)"
    }
}

/// Every artist in the library, or every artist with something on this watch.
struct ArtistsList: View {
    let downloadedOnly: Bool
    /// The first characters this list is narrowed to, or nil for all of them.
    var initials: Set<String>?

    @Environment(WatchModel.self) private var model
    @State private var artists: [Artist] = []
    @State private var hold: HoldActions?
    @State private var hasLoaded = false

    var body: some View {
        List {
            if artists.isEmpty {
                WatchEmptyView(title: emptyTitle, systemImage: "music.mic")
            }
            ForEach(artists) { artist in
                NavigationLink(value: artist) {
                    WatchMediaRow(
                        title: artist.name,
                        subtitle: artist.albumCount.map { $0.counted("record") },
                        artwork: artist.artwork,
                        isRound: true
                    )
                }
                .onHold {
                    hold = HoldActions(subject: .artist(artist), tracks: {
                        guard let library = model.library else { return [] }
                        return library.albums(forArtist: artist.id, downloadedOnly: downloadedOnly)
                            .flatMap { library.tracks(inAlbum: $0.id) }
                    }, downloadedOnly: downloadedOnly)
                }
            }
        }
        .navigationTitle(initials == nil ? "Artists" : "")
        .watchDownloadRing(model.downloads)
        .sheet(item: $hold) { HoldSheet(actions: $0) }
        .task(id: model.libraryVersion + model.downloadsRefreshKey(downloadedOnly)) {
            // A batch changes the answer once per song; coalesced, so the list
            // is read once the burst has settled rather than after each one.
            if downloadedOnly, hasLoaded {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            guard let library = model.library else { return }
            artists = if let initials {
                library.artists(initials: initials, downloadedOnly: downloadedOnly)
            } else {
                library.artists(downloadedOnly: downloadedOnly)
            }
            hasLoaded = true
        }
    }

    private var emptyTitle: String {
        downloadedOnly ? "No artists downloaded" : "No artists"
    }
}

/// Records, either all of them or the newest.
struct AlbumsList: View {
    enum Filter { case all, justAdded }

    let downloadedOnly: Bool
    let filter: Filter
    /// The first characters this list is narrowed to, or nil for all of them.
    var initials: Set<String>?

    @Environment(WatchModel.self) private var model
    @State private var albums: [Album] = []
    @State private var hold: HoldActions?
    @State private var hasLoaded = false

    var body: some View {
        List {
            if albums.isEmpty {
                WatchEmptyView(title: emptyTitle, systemImage: "square.stack")
            }
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    WatchMediaRow(
                        title: album.displayName,
                        subtitle: album.artistName,
                        artwork: album.artwork
                    )
                }
                .onHold {
                    hold = HoldActions(subject: .album(album), tracks: {
                        model.library?.tracks(inAlbum: album.id) ?? []
                    }, downloadedOnly: downloadedOnly)
                }
            }
        }
        .navigationTitle(initials == nil ? (filter == .justAdded ? "Just Added" : "Albums") : "")
        .watchDownloadRing(model.downloads)
        .sheet(item: $hold) { HoldSheet(actions: $0) }
        .task(id: model.libraryVersion + model.downloadsRefreshKey(downloadedOnly)) {
            if downloadedOnly, hasLoaded {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            defer { hasLoaded = true }
            guard let library = model.library else { return }
            albums = switch filter {
            case .all:
                if let initials {
                    library.albums(initials: initials, downloadedOnly: downloadedOnly)
                } else {
                    library.albums(downloadedOnly: downloadedOnly)
                }
            case .justAdded: library.justAdded(downloadedOnly: downloadedOnly)
            }
        }
    }

    private var emptyTitle: String {
        downloadedOnly ? "Nothing downloaded" : "No records"
    }
}

/// What has been put on lately, as the phone knows it.
struct RecentlyPlayedList: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        List {
            if model.recentlyPlayed.isEmpty {
                WatchEmptyView(
                    title: "Nothing yet",
                    detail: "Records and playlists you put on show up here.",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            ForEach(model.recentlyPlayed) { entry in
                row(entry)
            }
        }
        .navigationTitle("Recently Played")
    }

    @ViewBuilder
    private func row(_ entry: PlayedEntry) -> some View {
        let source = entry.source
        switch source.kind {
        case .album:
            // Resolved against this watch's own library, so the record opens
            // with everything on it. An entry the library no longer has is
            // left out rather than opening onto nothing.
            if let album = model.library?.album(id: source.mediaID) {
                NavigationLink(value: album) {
                    WatchMediaRow(
                        title: source.title, subtitle: source.subtitle, artwork: source.artwork
                    )
                }
            }
        case .playlist:
            NavigationLink(value: source.asPlaylist) {
                WatchMediaRow(
                    title: source.title, subtitle: source.subtitle, artwork: source.artwork
                )
            }
        }
    }
}
