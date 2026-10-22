import Foundation
import PleviDomain

/// In-memory provider used by previews, UI development, and the contract suite's self-test.
public actor MockProvider: MusicServerProvider {
    public nonisolated let serverID: ServerID
    public nonisolated let capabilities: ServerCapabilities = [
        .favorites, .ratings, .playlists, .playlistReorder, .syncedLyrics,
        .similarItems, .topTracks, .artistInfo, .albumInfo, .randomBrowse,
        .scrobbling, .genreBrowsing, .transcodeSelection,
    ]

    private var artistStore: [MediaID: Artist]
    private var albumStore: [MediaID: Album]
    private var trackStore: [MediaID: Track]
    private var albumTrackIDs: [MediaID: [MediaID]]
    private var playlistStore: [MediaID: (playlist: Playlist, entries: [(PlaylistEntryID, MediaID)])]
    private var entryCounter: Int
    private var playlistCounter: Int
    private var downloadError: (any Error)?
    private var downloadDelay: Duration?

    public init(serverID: ServerID = ServerID()) {
        self.serverID = serverID
        let seed = Self.makeSeedLibrary(serverID: serverID)
        self.artistStore = seed.artists
        self.albumStore = seed.albums
        self.trackStore = seed.tracks
        self.albumTrackIDs = seed.albumTrackIDs
        self.playlistStore = seed.playlists
        self.entryCounter = seed.entryCounter
        self.playlistCounter = seed.playlistCounter
    }

    // MARK: Connection

    public func testConnection() async throws -> ServerInfo {
        ServerInfo(
            productName: "PleviMock",
            productVersion: "1.0",
            apiVersion: "1.16.1",
            isOpenSubsonic: false,
            extensions: []
        )
    }

    // MARK: Browsing

    public func artists() async throws -> [Artist] {
        artistStore.values.sorted { $0.name < $1.name }
    }

    public func artist(id: MediaID) async throws -> ArtistDetail {
        guard let artist = artistStore[id] else { throw ProviderError.notFound }
        let albums = albumStore.values
            .filter { $0.artistID == id }
            .sorted { ($0.year ?? 0, $0.name) < ($1.year ?? 0, $1.name) }
        return ArtistDetail(artist: artist, albums: albums)
    }

    public func artistInfo(id: MediaID) async throws -> ArtistInfo {
        guard let artist = artistStore[id] else { throw ProviderError.notFound }
        let similar = artistStore.values.filter { $0.id != id }.sorted { $0.name < $1.name }
        return ArtistInfo(
            biography: "\(artist.name) is a fictional act that exists to make previews look alive.",
            similarArtists: similar
        )
    }

    public func albumInfo(id: MediaID) async throws -> AlbumInfo {
        guard let album = albumStore[id] else { throw ProviderError.notFound }
        return AlbumInfo(
            notes: "\(album.name) is a fixture record, written about at length by nobody.",
            musicBrainzID: nil
        )
    }

    public func albums(filter: AlbumFilter, offset: Int, limit: Int) async throws -> [Album] {
        var albums = albumStore.values.sorted { $0.name < $1.name }
        switch filter {
        case .alphabeticalByName:
            break
        case .alphabeticalByArtist:
            albums.sort { ($0.artistName ?? "", $0.name) < ($1.artistName ?? "", $1.name) }
        case .recentlyAdded:
            albums.sort { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        case .recentlyReleased:
            albums = albums.filter { $0.releaseDate != nil }
            albums.sort { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        case .mostPlayed:
            albums.sort { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case .favorites:
            albums = albums.filter(\.isFavorite)
        case .genre(let genre):
            albums = albums.filter { $0.genre?.caseInsensitiveCompare(genre) == .orderedSame }
        case .yearRange(let from, let to):
            albums = albums.filter { album in
                guard let year = album.year else { return false }
                return (from...to).contains(year)
            }
        case .recentlyPlayed, .highestRated, .random, .rediscover:
            break
        }
        guard offset < albums.count else { return [] }
        return Array(albums[offset..<min(offset + limit, albums.count)])
    }

    public func album(id: MediaID) async throws -> AlbumDetail {
        guard let album = albumStore[id] else { throw ProviderError.notFound }
        return AlbumDetail(album: album, tracks: orderedTracks(inAlbum: id))
    }

    public func track(id: MediaID) async throws -> Track {
        guard let track = trackStore[id] else { throw ProviderError.notFound }
        return track
    }

    public func genres() async throws -> [Genre] {
        let byGenre = Dictionary(grouping: trackStore.values.compactMap(\.genre)) { $0 }
        return byGenre
            .map { Genre(name: $0.key, trackCount: $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    public func search(_ query: String, limit: Int, offset: Int) async throws -> SearchResults {
        // An empty query returns the whole library, matching the
        // OpenSubsonic behaviour clients use for offline sync.
        let needle = query.lowercased()
        func page<T>(_ items: [T]) -> [T] {
            guard offset < items.count else { return [] }
            return Array(items[offset..<min(offset + limit, items.count)])
        }
        let artists = artistStore.values
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { $0.name < $1.name }
        let albums = albumStore.values
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { $0.name < $1.name }
        let tracks = trackStore.values
            .filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
            .sorted { ($0.title, $0.id.rawValue) < ($1.title, $1.id.rawValue) }
        return SearchResults(artists: page(artists), albums: page(albums), tracks: page(tracks))
    }

    public func randomTracks(limit: Int) async throws -> [Track] {
        Array(trackStore.values.shuffled().prefix(limit))
    }

    public func similarTracks(to id: MediaID, limit: Int) async throws -> [Track] {
        guard let seed = trackStore[id] else { throw ProviderError.notFound }
        return Array(trackStore.values
            .filter { $0.id != id && $0.genre == seed.genre }
            .sorted { $0.title < $1.title }
            .prefix(limit))
    }

    public func topTracks(forArtist id: MediaID, limit: Int) async throws -> [Track] {
        guard artistStore[id] != nil else { throw ProviderError.notFound }
        return Array(trackStore.values
            .filter { $0.artistID == id }
            .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            .prefix(limit))
    }

    // MARK: Playlists

    public func playlists() async throws -> [Playlist] {
        playlistStore.values.map(\.playlist).sorted { $0.name < $1.name }
    }

    public func playlist(id: MediaID) async throws -> PlaylistDetail {
        guard let stored = playlistStore[id] else { throw ProviderError.notFound }
        let entries = stored.entries.compactMap { entryID, trackID in
            trackStore[trackID].map { PlaylistEntry(entryID: entryID, track: $0) }
        }
        return PlaylistDetail(playlist: stored.playlist, entries: entries)
    }

    public func createPlaylist(name: String, trackIDs: [MediaID]) async throws -> Playlist {
        for trackID in trackIDs where trackStore[trackID] == nil {
            throw ProviderError.notFound
        }
        playlistCounter += 1
        let id = MediaID(server: serverID, rawValue: "pl\(playlistCounter)")
        let playlist = Playlist(
            id: id,
            name: name,
            trackCount: trackIDs.count,
            changedAt: Date()
        )
        playlistStore[id] = (playlist, trackIDs.map { (nextEntryID(), $0) })
        return playlist
    }

    public func renamePlaylist(id: MediaID, name: String) async throws {
        guard var stored = playlistStore[id] else { throw ProviderError.notFound }
        stored.playlist.name = name
        stored.playlist.changedAt = Date()
        playlistStore[id] = stored
    }

    public func addToPlaylist(id: MediaID, trackIDs: [MediaID]) async throws {
        guard var stored = playlistStore[id] else { throw ProviderError.notFound }
        for trackID in trackIDs where trackStore[trackID] == nil {
            throw ProviderError.notFound
        }
        stored.entries.append(contentsOf: trackIDs.map { (nextEntryID(), $0) })
        stored.playlist.trackCount = stored.entries.count
        stored.playlist.changedAt = Date()
        playlistStore[id] = stored
    }

    public func removeFromPlaylist(id: MediaID, entries: [PlaylistEntryID]) async throws {
        guard var stored = playlistStore[id] else { throw ProviderError.notFound }
        let current = Set(stored.entries.map(\.0))
        for entry in entries where !current.contains(entry) {
            throw ProviderError.conflict(details: "playlist entry no longer exists")
        }
        let removing = Set(entries)
        stored.entries.removeAll { removing.contains($0.0) }
        stored.playlist.trackCount = stored.entries.count
        stored.playlist.changedAt = Date()
        playlistStore[id] = stored
    }

    public func reorderPlaylist(id: MediaID, orderedEntries: [PlaylistEntryID]) async throws {
        guard var stored = playlistStore[id] else { throw ProviderError.notFound }
        let currentByID = Dictionary(uniqueKeysWithValues: stored.entries.map { ($0.0, $0) })
        guard orderedEntries.count == stored.entries.count,
              Set(orderedEntries).count == orderedEntries.count,
              orderedEntries.allSatisfy({ currentByID[$0] != nil })
        else {
            throw ProviderError.conflict(details: "reorder does not match current playlist entries")
        }
        stored.entries = orderedEntries.compactMap { currentByID[$0] }
        stored.playlist.changedAt = Date()
        playlistStore[id] = stored
    }

    // MARK: State

    public func setFavorite(_ favorite: Bool, for id: MediaID, kind: MediaKind) async throws {
        switch kind {
        case .track:
            guard var track = trackStore[id] else { throw ProviderError.notFound }
            track.isFavorite = favorite
            trackStore[id] = track
        case .album:
            guard var album = albumStore[id] else { throw ProviderError.notFound }
            album.isFavorite = favorite
            albumStore[id] = album
        case .artist:
            guard var artist = artistStore[id] else { throw ProviderError.notFound }
            artist.isFavorite = favorite
            artistStore[id] = artist
        case .playlist, .genre:
            throw ProviderError.unsupportedOperation(needs: .favorites)
        }
    }

    public func setRating(_ rating: StarRating?, for id: MediaID) async throws {
        if var track = trackStore[id] {
            track.rating = rating
            trackStore[id] = track
        } else if var album = albumStore[id] {
            album.rating = rating
            albumStore[id] = album
        } else if var artist = artistStore[id] {
            artist.rating = rating
            artistStore[id] = artist
        } else {
            throw ProviderError.notFound
        }
    }

    public func scrobble(id: MediaID, at date: Date, submission: Bool) async throws {
        guard var track = trackStore[id] else { throw ProviderError.notFound }
        if submission {
            track.playCount = (track.playCount ?? 0) + 1
            trackStore[id] = track
        }
    }

    // MARK: Media requests

    public func streamRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
        guard trackStore[id] != nil else { throw ProviderError.notFound }
        return URLRequest(url: URL(string: "https://mock.example/stream/\(id.rawValue)")!)
    }

    /// Makes the next download preparations wait, then fail — the shapes a
    /// real server gives when it is slow or unreachable. For tests of the
    /// queue above the provider; nil puts it back to answering at once.
    public func setDownloadBehaviour(error: (any Error)?, delay: Duration? = nil) {
        downloadError = error
        downloadDelay = delay
    }

    public func downloadRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
        if let downloadDelay { try? await Task.sleep(for: downloadDelay) }
        if let downloadError { throw downloadError }
        guard trackStore[id] != nil else { throw ProviderError.notFound }
        return URLRequest(url: URL(string: "https://mock.example/download/\(id.rawValue)")!)
    }

    public func artworkRequest(for id: ArtworkID, size: Int?) async throws -> URLRequest {
        var components = URLComponents(string: "https://mock.example/art/\(id.rawValue)")!
        if let size {
            components.queryItems = [URLQueryItem(name: "size", value: String(size))]
        }
        return URLRequest(url: components.url!)
    }

    // MARK: Extras

    public func lyrics(for id: MediaID) async throws -> Lyrics? {
        guard let track = trackStore[id] else { throw ProviderError.notFound }
        guard track.title == "First Light" else { return nil }
        return Lyrics(synced: true, language: "eng", lines: [
            Lyrics.Line(start: 0.5, text: "Placeholder dawn"),
            Lyrics.Line(start: 4.2, text: "Fixture skies in monochrome"),
            Lyrics.Line(start: 9.8, text: "Every sample sings alone"),
        ])
    }

    // MARK: Helpers

    private func nextEntryID() -> PlaylistEntryID {
        entryCounter += 1
        return PlaylistEntryID(server: serverID, rawValue: "e\(entryCounter)")
    }

    private func orderedTracks(inAlbum id: MediaID) -> [Track] {
        (albumTrackIDs[id] ?? [])
            .compactMap { trackStore[$0] }
            .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
    }

    // MARK: Seeding

    private struct SeedLibrary {
        var artists: [MediaID: Artist] = [:]
        var albums: [MediaID: Album] = [:]
        var tracks: [MediaID: Track] = [:]
        var albumTrackIDs: [MediaID: [MediaID]] = [:]
        var playlists: [MediaID: (playlist: Playlist, entries: [(PlaylistEntryID, MediaID)])] = [:]
        var entryCounter = 0
        var playlistCounter = 0
    }

    private static func makeSeedLibrary(serverID: ServerID) -> SeedLibrary {
        var lib = SeedLibrary()

        func day(_ offset: Int) -> Date {
            Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(offset) * 86_400)
        }

        func nextEntryID() -> PlaylistEntryID {
            lib.entryCounter += 1
            return PlaylistEntryID(server: serverID, rawValue: "e\(lib.entryCounter)")
        }

        struct SeedAlbum {
            let name: String
            let year: Int
            let genre: String
            let addedDay: Int
            let titles: [String]
            var releaseTypes: [ReleaseType] = [.album]
        }

        let catalog: [(artist: String, albums: [SeedAlbum])] = [
            ("Aurora Skies", [
                SeedAlbum(name: "Daybreak", year: 2019, genre: "Ambient", addedDay: 3, titles: [
                    "First Light", "Slow Horizon", "Cloud Atlas", "Golden Hour",
                ]),
                SeedAlbum(name: "Nightfall", year: 2022, genre: "Ambient", addedDay: 9, titles: [
                    "Dusk", "Afterglow", "Polar Low",
                ], releaseTypes: [.ep]),
            ]),
            ("The Basement Tapes", [
                SeedAlbum(name: "Reel One", year: 1998, genre: "Rock", addedDay: 1, titles: [
                    "Tape Hiss", "Four Track Mind", "Analog Heart",
                ]),
            ]),
            ("Cobalt Waves", [
                SeedAlbum(name: "Undertow", year: 2021, genre: "Electronic", addedDay: 6, titles: [
                    "Riptide", "Salt & Signal", "Breakwater", "Deep Channel",
                ]),
            ]),
        ]

        var artistIndex = 0
        var albumIndex = 0
        var trackIndex = 0

        for (artistName, seedAlbums) in catalog {
            artistIndex += 1
            let artistID = MediaID(server: serverID, rawValue: "ar\(artistIndex)")
            lib.artists[artistID] = Artist(
                id: artistID,
                name: artistName,
                albumCount: seedAlbums.count,
                artwork: ArtworkID(server: serverID, rawValue: "art-ar\(artistIndex)")
            )

            for seedAlbum in seedAlbums {
                albumIndex += 1
                let albumID = MediaID(server: serverID, rawValue: "al\(albumIndex)")
                lib.albums[albumID] = Album(
                    id: albumID,
                    name: seedAlbum.name,
                    artistName: artistName,
                    artistID: artistID,
                    year: seedAlbum.year,
                    genre: seedAlbum.genre,
                    trackCount: seedAlbum.titles.count,
                    duration: TimeInterval(seedAlbum.titles.count * 210),
                    artwork: ArtworkID(server: serverID, rawValue: "art-al\(albumIndex)"),
                    addedAt: day(seedAlbum.addedDay),
                    playCount: albumIndex * 3,
                    releaseTypes: seedAlbum.releaseTypes
                )

                var ids = [MediaID]()
                for (position, title) in seedAlbum.titles.enumerated() {
                    trackIndex += 1
                    let trackID = MediaID(server: serverID, rawValue: "t\(trackIndex)")
                    lib.tracks[trackID] = Track(
                        id: trackID,
                        title: title,
                        albumName: seedAlbum.name,
                        albumID: albumID,
                        artistName: artistName,
                        artistID: artistID,
                        trackNumber: position + 1,
                        discNumber: 1,
                        duration: 180 + TimeInterval(position * 30),
                        year: seedAlbum.year,
                        genre: seedAlbum.genre,
                        codec: position.isMultiple(of: 2) ? "flac" : "opus",
                        bitRateKbps: 900,
                        sampleRate: 44_100,
                        artwork: ArtworkID(server: serverID, rawValue: "art-al\(albumIndex)"),
                        replayGain: ReplayGain(trackGain: -6.5, albumGain: -6.1, trackPeak: 0.98),
                        playCount: (trackIndex * 7) % 23
                    )
                    ids.append(trackID)
                }
                lib.albumTrackIDs[albumID] = ids
            }
        }

        let firstAlbumTracks = lib.albumTrackIDs[MediaID(server: serverID, rawValue: "al1")] ?? []
        lib.playlistCounter += 1
        let playlistID = MediaID(server: serverID, rawValue: "pl\(lib.playlistCounter)")
        lib.playlists[playlistID] = (
            Playlist(
                id: playlistID,
                name: "Morning Mix",
                trackCount: firstAlbumTracks.count,
                changedAt: day(10)
            ),
            firstAlbumTracks.map { (nextEntryID(), $0) }
        )

        return lib
    }
}
