import SwiftUI
import PleviDomain

/// A record: Play and Shuffle, then its songs in order.
struct AlbumPage: View {
    let album: Album
    let downloadedOnly: Bool

    @Environment(WatchModel.self) private var model
    @State private var tracks: [Track] = []
    @State private var downloaded: Set<String> = []
    @State private var hold: HoldActions?

    var body: some View {
        List {
            if !playable.isEmpty {
                PlayShuffleRow(
                    onPlay: { model.player.play(playable, from: .album(album)) },
                    onShuffle: { model.player.shuffle(playable, from: .album(album)) }
                )
            } else if tracks.isEmpty {
                WatchEmptyView(title: "No songs", systemImage: "music.note")
            } else {
                // The record is here but none of it is. Drawing Play over a
                // queue that would be empty gives a button that answers a tap
                // with nothing at all.
                WatchEmptyView(
                    title: "Not on this watch",
                    detail: "Hold the record and choose Download to keep it here.",
                    systemImage: "arrow.down.circle"
                )
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    // From here to the end of the record, as every music app
                    // does: tapping the fourth song plays the fourth song and
                    // then the fifth, not the fourth alone.
                    guard let start = playableIndex(of: track) else { return }
                    model.player.play(playable, startingAt: start, from: .album(album))
                } label: {
                    WatchTrackRow(
                        track: track,
                        number: track.trackNumber ?? index + 1,
                        isUnavailable: isUnavailable(track)
                    )
                }
                // A song the watch does not have does not answer a tap. It
                // used to, and played somebody else's song.
                .disabled(isUnavailable(track))
                .buttonStyle(.plain)
                .onHold {
                    // A song the watch does not have offers nothing: its only
                    // actions would queue something that cannot play.
                    guard !isUnavailable(track) else { return }
                    hold = HoldActions(subject: .track(track), tracks: { [track] })
                }
            }
        }
        .navigationTitle(album.displayName)
        .watchDownloadRing(model.downloads)
        .sheet(item: $hold) { HoldSheet(actions: $0) }
        // Also on what has been downloaded: this set drives the dimming and
        // what Play queues, and a download finishing while the page is open
        // moves neither the library version nor the album id.
        .task(id: album.id.rawValue + model.libraryVersion + model.downloadsKey) {
            guard let library = model.library else { return }
            tracks = library.tracks(inAlbum: album.id)
            downloaded = library.downloadedTrackIDs()
        }
    }

    /// Offline, a song with no file on this watch will not play — so it is
    /// dimmed in the list and left out of what Play starts, rather than
    /// stopping the record halfway through.
    private var playable: [Track] {
        tracks.filter { !isUnavailable($0) }
    }

    /// Where a song sits in what will actually play, or nil when it will not.
    private func playableIndex(of track: Track) -> Int? {
        playable.firstIndex(where: { $0.id == track.id })
    }

    private func isUnavailable(_ track: Track) -> Bool {
        // The Downloads tab, and only that.
        guard downloadedOnly else { return false }
        return !downloaded.contains(track.id.rawValue)
    }
}

/// An artist: Play and Shuffle across everything of theirs, then their records.
struct ArtistPage: View {
    let artist: Artist
    let downloadedOnly: Bool

    @Environment(WatchModel.self) private var model
    @State private var albums: [Album] = []
    @State private var hold: HoldActions?

    var body: some View {
        List {
            if !albums.isEmpty {
                PlayShuffleRow(
                    onPlay: { Task { model.player.play(await songs(), from: .artist) } },
                    onShuffle: { Task { model.player.shuffle(await songs(), from: .artist) } }
                )
            } else {
                WatchEmptyView(title: "No records", systemImage: "square.stack")
            }
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    WatchMediaRow(
                        title: album.displayName,
                        subtitle: album.year.map(String.init),
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
        .navigationTitle(artist.name)
        .watchDownloadRing(model.downloads)
        .sheet(item: $hold) { HoldSheet(actions: $0) }
        .task(id: artist.id.rawValue + model.libraryVersion) {
            albums = model.library?.albums(forArtist: artist.id, downloadedOnly: downloadedOnly) ?? []
        }
    }

    /// Their records in order, each one whole — rather than a flat list of
    /// songs, which would shuffle a discography into a mess even when Play
    /// was what was asked for.
    private func songs() async -> [Track] {
        guard let library = model.library else { return [] }
        let all = albums.flatMap { library.tracks(inAlbum: $0.id) }
        guard downloadedOnly else { return all }
        // A record counts as downloaded when *any* of it is, so the albums above are whole ones the
        // watch may only partly hold.
        let here = library.downloadedTrackIDs()
        return all.filter { here.contains($0.id.rawValue) }
    }
}

/// Playlists, from the server.
struct PlaylistsList: View {
    let downloadedOnly: Bool

    @Environment(WatchModel.self) private var model
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var problem: String?
    @State private var hold: HoldActions?
    /// True lengths, once the server has been asked. See `countSmartPlaylists`.
    @State private var counts: [MediaID: Int] = [:]

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let problem {
                WatchEmptyView(title: "Can't reach your server", detail: problem)
            } else if playlists.isEmpty {
                WatchEmptyView(title: emptyTitle, systemImage: "music.note.list")
            }
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist) {
                    WatchMediaRow(
                        title: playlist.name,
                        subtitle: songCount(playlist),
                        artwork: playlist.artwork
                    )
                }
                .onHold {
                    hold = HoldActions(subject: .playlist(playlist), tracks: {
                        // In Downloads the answer is on this watch, and has to be: the songs are
                        // asked of the server otherwise, so removing a downloaded playlist out of
                        // Wi-Fi got an empty list back and freed nothing at all — the record and
                        // the request key went, the…
                        if downloadedOnly {
                            return model.tracks(inDownloadedPlaylist: playlist.id)
                        }
                        // Otherwise as the server has it now, not as the watch
                        // last saw it.
                        guard let provider = model.provider else { return [] }
                        let page = try? await provider.playlistPage(
                            id: playlist.id, offset: 0, limit: 1000
                        )
                        return page?.entries.map(\.track) ?? []
                    })
                }
            }
        }
        .navigationTitle("Playlists")
        .watchDownloadRing(model.downloads)
        .sheet(item: $hold) { HoldSheet(actions: $0) }
        // Also on the connection: this asks the server, and it is reachable from the first frame
        // while `connect` is still waiting on the endpoint probe — ten seconds at worst.
        .task(id: "\(downloadedOnly)-\(model.libraryVersion)-\(model.connectionKey)-\(model.downloadsRefreshKey(downloadedOnly))") {
            await load()
            await countSmartPlaylists()
        }
    }

    private var emptyTitle: String {
        downloadedOnly ? "No playlists downloaded" : "No playlists"
    }

    /// How many songs a playlist has, where that can be said honestly.
    private func songCount(_ playlist: Playlist) -> String? {
        if let known = counts[playlist.id] { return known.counted("song") }
        if playlist.isSmart, !downloadedOnly { return nil }
        return playlist.trackCount.map { $0.counted("song") }
    }

    /// Asks the server how long each smart playlist really is.
    private func countSmartPlaylists() async {
        guard !downloadedOnly, let provider = model.provider else { return }
        let wanted = playlists.filter { $0.isSmart && counts[$0.id] == nil }
        guard !wanted.isEmpty else { return }
        for batch in stride(from: 0, to: wanted.count, by: 4).map({
            Array(wanted[$0..<min($0 + 4, wanted.count)])
        }) {
            await withTaskGroup(of: (MediaID, Int?).self) { group in
                for playlist in batch {
                    group.addTask {
                        let page = try? await provider.playlistPage(
                            id: playlist.id, offset: 0, limit: 1
                        )
                        return (playlist.id, page?.total)
                    }
                }
                for await (id, total) in group {
                    if let total { counts[id] = total }
                }
            }
            if Task.isCancelled { return }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard !downloadedOnly else {
            playlists = model.downloadedPlaylists()
            problem = nil
            return
        }
        guard let provider = model.provider else {
            problem = "Your iPhone or your server is out of reach."
            return
        }
        do {
            playlists = try await provider.playlists()
            problem = nil
        } catch {
            problem = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// One playlist's songs, with Play and Shuffle over them.
struct PlaylistTracksPage: View {
    let playlist: Playlist
    var downloadedOnly = false

    @Environment(WatchModel.self) private var model
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var problem: String?
    @State private var hold: HoldActions?

    /// A playlist can run to tens of thousands of songs. This is a watch: the
    /// first few hundred is more than anybody scrolls, and asking for the
    /// rest would spend the radio on rows nobody reads.
    private static let limit = 300

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let problem {
                WatchEmptyView(title: "Can't reach your server", detail: problem)
            } else if tracks.isEmpty {
                WatchEmptyView(title: "No songs", systemImage: "music.note")
            } else {
                PlayShuffleRow(
                    onPlay: { model.player.play(tracks, from: .playlist(playlist)) },
                    onShuffle: { model.player.shuffle(tracks, from: .playlist(playlist)) }
                )
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    model.player.play(tracks, startingAt: index, from: .playlist(playlist))
                } label: {
                    WatchTrackRow(track: track, number: index + 1)
                }
                .buttonStyle(.plain)
                .onHold { hold = HoldActions(subject: .track(track), tracks: { [track] }) }
            }
        }
        .navigationTitle(playlist.name)
        .watchDownloadRing(model.downloads)
        .sheet(item: $hold) { HoldSheet(actions: $0) }
        .task(id: playlist.id.rawValue + model.libraryVersion + model.connectionKey
                + model.downloadsRefreshKey(downloadedOnly)) { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if downloadedOnly {
            tracks = model.tracks(inDownloadedPlaylist: playlist.id)
            problem = nil
            return
        }
        guard let provider = model.provider else {
            problem = "Your iPhone or your server is out of reach."
            return
        }
        do {
            let page = try await provider.playlistPage(id: playlist.id, offset: 0, limit: Self.limit)
            tracks = page.entries.map(\.track)
            problem = nil
        } catch {
            problem = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
        }
    }
}
