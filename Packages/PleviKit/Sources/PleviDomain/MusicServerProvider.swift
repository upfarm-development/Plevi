import Foundation

/// The single boundary between the app and any music server backend.
public protocol MusicServerProvider: Sendable, PlaylistPageSource {
    var serverID: ServerID { get }
    var capabilities: ServerCapabilities { get }

    // MARK: Connection

    /// Verifies connectivity and authentication, returning server details.
    /// Must produce typed `ProviderError`s that distinguish "unreachable",
    /// "wrong credentials", and "not a compatible server".
    func testConnection() async throws -> ServerInfo

    // MARK: Browsing

    /// The full artist list. Not paged: no supported backend pages this call,
    /// and the local index (Milestone 2) is the scaling mechanism.
    func artists() async throws -> [Artist]
    func artist(id: MediaID) async throws -> ArtistDetail
    /// Gate on `.artistInfo`.
    func artistInfo(id: MediaID) async throws -> ArtistInfo
    /// Gate on `.albumInfo`.
    func albumInfo(id: MediaID) async throws -> AlbumInfo
    func albums(filter: AlbumFilter, offset: Int, limit: Int) async throws -> [Album]
    func album(id: MediaID) async throws -> AlbumDetail
    func track(id: MediaID) async throws -> Track
    /// Gate on `.genreBrowsing`.
    func genres() async throws -> [Genre]
    /// An empty query must return the whole library (OpenSubsonic requires
    /// this; it is how clients sync for offline use). `offset` applies to
    /// each result collection independently.
    func search(_ query: String, limit: Int, offset: Int) async throws -> SearchResults

    /// One page of the library's songs, and nothing else.
    func tracks(offset: Int, limit: Int) async throws -> [Track]

    /// How many artists, albums and songs the server itself says it holds.
    func libraryCounts() async throws -> LibraryCounts

    /// An opaque token that changes when the server's library changes, or nil from a server that
    /// offers nothing of the kind.
    func libraryChangeToken() async throws -> String?
    /// Gate on `.randomBrowse`.
    func randomTracks(limit: Int) async throws -> [Track]
    /// Gate on `.similarItems`.
    func similarTracks(to id: MediaID, limit: Int) async throws -> [Track]

    /// Albums that sound like this one, most alike first.
    /// Gate on `.similarAlbums`.
    func similarAlbums(to id: MediaID, limit: Int) async throws -> [Album]
    /// Gate on `.topTracks`.
    func topTracks(forArtist id: MediaID, limit: Int) async throws -> [Track]

    // MARK: Playlists — gate on `.playlists`

    func playlists() async throws -> [Playlist]
    func playlist(id: MediaID) async throws -> PlaylistDetail
    // There is deliberately no `deletePlaylist`.
    func createPlaylist(name: String, trackIDs: [MediaID]) async throws -> Playlist
    func renamePlaylist(id: MediaID, name: String) async throws
    func addToPlaylist(id: MediaID, trackIDs: [MediaID]) async throws
    /// Removes specific rows. Providers must fail with `.conflict` rather than
    /// remove the wrong row when server state has drifted.
    func removeFromPlaylist(id: MediaID, entries: [PlaylistEntryID]) async throws
    /// Replaces the playlist's order with the given complete entry list.
    func artistGenres() async throws -> [Genre]

    /// The artists it files under one.
    /// Gate on `.genreBrowsing`.
    func artists(inGenre genre: Genre) async throws -> [Artist]

    /// The sets someone has gathered on the server, of records or of artists.
    /// Gate on `.collections`.
    func collections() async throws -> [MediaCollection]

    /// What is in one. Which to call follows from the collection's `kind`.
    /// Gate on `.collections`.
    func albums(inCollection id: MediaID) async throws -> [Album]
    func artists(inCollection id: MediaID) async throws -> [Artist]

    /// Gathers things into a new collection.
    /// Gate on `.collectionEditing`.
    func createCollection(name: String, kind: MediaCollection.Kind, itemIDs: [MediaID]) async throws -> MediaCollection

    /// Adds to one that already exists.
    /// Gate on `.collectionEditing`.
    func addToCollection(id: MediaID, itemIDs: [MediaID]) async throws

    /// A playlist the server keeps up to date from a saved search.
    /// Gate on `.smartPlaylists`.
    func createSmartPlaylist(name: String, query: SmartQuery) async throws -> Playlist

    /// Gate on `.playlistReorder`.
    func reorderPlaylist(id: MediaID, orderedEntries: [PlaylistEntryID]) async throws

    // MARK: State — gate on `.favorites` / `.ratings` / `.scrobbling`

    func setFavorite(_ favorite: Bool, for id: MediaID, kind: MediaKind) async throws
    /// `nil` clears the rating. Providers convert `StarRating` to their native
    /// scale internally; the UI never sees backend rating scales.
    func setRating(_ rating: StarRating?, for id: MediaID) async throws
    /// `submission: false` reports "now playing"; `true` submits a play.
    func scrobble(id: MediaID, at date: Date, submission: Bool) async throws

    /// Where a song has got to, for a server that keeps its own account of what its clients are
    /// doing.
    func report(_ playback: PlaybackReport) async throws

    // MARK: Media requests
    // Fully-formed authenticated requests for the player, downloader, and
    // image cache. Async because auth material may require actor or Keychain
    // access. Requests must never contain plaintext passwords.

    func streamRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest

    /// The same, saying how the audio will arrive. Providers that always send
    /// a single file need not implement it.
    func streamSource(for id: MediaID, options: StreamOptions) async throws -> StreamSource
    func downloadRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest
    /// How to fetch a song to keep, and whether it arrives as one file or as a playlist of segments
    /// — answered together.
    func downloadSource(for id: MediaID, options: StreamOptions) async throws -> StreamSource

    /// Tells the server the conversion it was doing for us is no longer wanted.
    func endConversion(for id: MediaID) async

    /// The same, for the conversion a song was *played* through rather than downloaded through.
    func endPlayback(for id: MediaID) async
    /// `size` is the desired square pixel edge; servers scale where supported.
    /// Callers request only the size they will display.
    func artworkRequest(for id: ArtworkID, size: Int?) async throws -> URLRequest

    // MARK: Extras

    /// Gate on `.syncedLyrics` for synced content; may return unsynced lyrics
    /// otherwise. `nil` means the server has no lyrics for the track.
    func lyrics(for id: MediaID) async throws -> Lyrics?


    /// Every individual play in `[from, to)`, not the single "last played" date every provider
    /// already offers but each time it actually happened.
    func playHistory(from: Date, to: Date, limit: Int) async throws -> [PlayHistoryEntry]

    /// A loudness envelope the server has already worked out, as `bars` levels from 0 to 1, or nil
    /// when it has none.
    func loudnessEnvelope(for id: MediaID, bars: Int) async throws -> [Float]?

    /// The formats this server will convert to, best first.
    var supportedTranscodeCodecs: [TranscodeCodec] { get }
}

public extension MusicServerProvider {
    func search(_ query: String, limit: Int) async throws -> SearchResults {
        try await search(query, limit: limit, offset: 0)
    }
}

// MARK: - Defaults for capability-gated methods

public extension MusicServerProvider {
    /// The track's own reference loudness, where the server has measured it.
    func referenceLoudnessDb(for track: MediaID) async throws -> Double? { nil }

    /// Most servers keep no account of what is playing right now, and for
    /// those this is simply nothing to do.
    func report(_ playback: PlaybackReport) async throws {}

    func artistInfo(id: MediaID) async throws -> ArtistInfo {
        throw ProviderError.unsupportedOperation(needs: .artistInfo)
    }

    func albumInfo(id: MediaID) async throws -> AlbumInfo {
        throw ProviderError.unsupportedOperation(needs: .albumInfo)
    }

    func genres() async throws -> [Genre] {
        throw ProviderError.unsupportedOperation(needs: .genreBrowsing)
    }

    func randomTracks(limit: Int) async throws -> [Track] {
        throw ProviderError.unsupportedOperation(needs: .randomBrowse)
    }

    func createSmartPlaylist(name: String, query: SmartQuery) async throws -> Playlist {
        throw ProviderError.unsupportedOperation(needs: .smartPlaylists)
    }

    func artistGenres() async throws -> [Genre] {
        throw ProviderError.unsupportedOperation(needs: .genreBrowsing)
    }

    func artists(inGenre genre: Genre) async throws -> [Artist] {
        throw ProviderError.unsupportedOperation(needs: .genreBrowsing)
    }

    func collections() async throws -> [MediaCollection] {
        throw ProviderError.unsupportedOperation(needs: .collections)
    }

    func createCollection(
        name: String,
        kind: MediaCollection.Kind,
        itemIDs: [MediaID]
    ) async throws -> MediaCollection {
        throw ProviderError.unsupportedOperation(needs: .collectionEditing)
    }

    func addToCollection(id: MediaID, itemIDs: [MediaID]) async throws {
        throw ProviderError.unsupportedOperation(needs: .collectionEditing)
    }

    func albums(inCollection id: MediaID) async throws -> [Album] {
        throw ProviderError.unsupportedOperation(needs: .collections)
    }

    func artists(inCollection id: MediaID) async throws -> [Artist] {
        throw ProviderError.unsupportedOperation(needs: .collections)
    }

    func similarTracks(to id: MediaID, limit: Int) async throws -> [Track] {
        throw ProviderError.unsupportedOperation(needs: .similarItems)
    }

    func similarAlbums(to id: MediaID, limit: Int) async throws -> [Album] {
        throw ProviderError.unsupportedOperation(needs: .similarAlbums)
    }

    func topTracks(forArtist id: MediaID, limit: Int) async throws -> [Track] {
        throw ProviderError.unsupportedOperation(needs: .topTracks)
    }

    func reorderPlaylist(id: MediaID, orderedEntries: [PlaylistEntryID]) async throws {
        throw ProviderError.unsupportedOperation(needs: .playlistReorder)
    }

    func setRating(_ rating: StarRating?, for id: MediaID) async throws {
        throw ProviderError.unsupportedOperation(needs: .ratings)
    }

    func endConversion(for id: MediaID) async {}

    func endPlayback(for id: MediaID) async {}

    func playHistory(from: Date, to: Date, limit: Int) async throws -> [PlayHistoryEntry] {
        throw ProviderError.unsupportedOperation(needs: .playHistory)
    }

    func loudnessEnvelope(for id: MediaID, bars: Int) async throws -> [Float]? {
        nil
    }

    /// AAC first, MP3 where a server insists.
    var supportedTranscodeCodecs: [TranscodeCodec] { [.aac, .mp3] }

    func streamSource(for id: MediaID, options: StreamOptions) async throws -> StreamSource {
        StreamSource(request: try await streamRequest(for: id, options: options))
    }

    /// A plain file, which is what every server but Plex offers however the
    /// song is asked for.
    func downloadSource(for id: MediaID, options: StreamOptions) async throws -> StreamSource {
        StreamSource(request: try await downloadRequest(for: id, options: options))
    }

    func lyrics(for id: MediaID) async throws -> Lyrics? {
        throw ProviderError.unsupportedOperation(needs: .syncedLyrics)
    }

    /// Correct on every backend, and wasteful on most of them — see the
    /// declaration. A page of the library, with everything but the songs
    /// discarded on this side of the wire rather than the far one.
    func tracks(offset: Int, limit: Int) async throws -> [Track] {
        try await search("", limit: limit, offset: offset).tracks
    }

    /// Nothing counted. The sync treats this as "no cross-check available"
    /// and falls back on the walk's own terminator, which is what every
    /// sync did before counts existed.
    func libraryCounts() async throws -> LibraryCounts { LibraryCounts() }

    /// No token, so nothing is ever skipped. A server that cannot say
    /// whether its library changed gets walked, every time.
    func libraryChangeToken() async throws -> String? { nil }

    /// The whole playlist, with the asked-for slice cut out of it — correct,
    /// but no faster than asking for all of it, which is what it does. A
    /// server that can page should say so by implementing this itself.
    func playlistPage(id: MediaID, offset: Int, limit: Int) async throws -> PlaylistPage {
        let detail = try await playlist(id: id)
        let slice = detail.entries.dropFirst(offset).prefix(limit)
        return PlaylistPage(
            playlist: detail.playlist,
            entries: Array(slice),
            total: detail.entries.count,
            returnedRows: slice.count
        )
    }
}

/// What a server says its library holds, for a sync to check its own work against.
public struct LibraryCounts: Hashable, Sendable {
    public let artists: Int?
    public let albums: Int?
    public let tracks: Int?

    /// The server says it is part way through a scan of its own.
    public let isRescanning: Bool

    public init(
        artists: Int? = nil,
        albums: Int? = nil,
        tracks: Int? = nil,
        isRescanning: Bool = false
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.isRescanning = isRescanning
    }
}
