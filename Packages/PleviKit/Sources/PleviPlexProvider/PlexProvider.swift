import Foundation
import Synchronization
import PleviDomain
import PleviTransport

/// What the app needs to talk to one Plex music library.
public struct PlexServerConfig: Hashable, Sendable, Codable {
    /// The server's base URL, chosen at setup from its connection list.
    public var baseURL: URL
    /// The token for the chosen Home user — not the account's.
    public var token: String
    /// The music library's section key.
    public var sectionKey: String
    public var sectionTitle: String
    public var machineIdentifier: String

    public init(
        baseURL: URL,
        token: String,
        sectionKey: String,
        sectionTitle: String = "",
        machineIdentifier: String = ""
    ) {
        self.baseURL = baseURL
        self.token = token
        self.sectionKey = sectionKey
        self.sectionTitle = sectionTitle
        self.machineIdentifier = machineIdentifier
    }
}

/// Plex, behind the same protocol as Navidrome.
public final class PlexProvider: MusicServerProvider {
    public let serverID: ServerID

    private let config: PlexServerConfig
    private let identity: PlexIdentity
    private let transport: any HTTPTransport
    private let baseURLStorage: Mutex<URL>
    /// Lowercased artist name to that artist's own id, across the whole library — see
    /// `mapTracks(_:)`.
    private let artistIDByNameCache: Mutex<[String: MediaID]?> = Mutex(nil)

    /// Plex library item types, as the API numbers them.
    private enum ItemType: Int {
        case artist = 8
        case album = 9
        case track = 10
    }

    public init(
        serverID: ServerID,
        config: PlexServerConfig,
        identity: PlexIdentity,
        transport: any HTTPTransport
    ) {
        self.serverID = serverID
        self.config = config
        self.identity = identity
        self.transport = transport
        self.baseURLStorage = Mutex(config.baseURL)
    }

    /// Swapped by the endpoint selector when the reachable address changes.
    public func setBaseURL(_ url: URL) {
        baseURLStorage.withLock { $0 = url }
    }

    private var baseURL: URL {
        baseURLStorage.withLock { $0 }
    }

    /// Plex has no favourites for music and no "similar tracks" worth the name, so neither is
    /// advertised — the UI hides what the server cannot do rather than offering it and failing.
    func deliverable(_ codec: TranscodeCodec) -> TranscodeCodec {
        supportedTranscodeCodecs.contains(codec)
            ? codec
            : (supportedTranscodeCodecs.first ?? .mp3)
    }

    /// Opus first, MP3 as the one every server and every file can manage.
    public var supportedTranscodeCodecs: [TranscodeCodec] { [.opus, .mp3] }

    /// A track arrives as one stream, converted or not; the request says plain file.
    public func streamSource(for id: MediaID, options: StreamOptions) async throws -> StreamSource {
        // One stream, whatever the codec.
        return StreamSource(request: try await streamRequest(for: id, options: options))
    }

    /// Downloading asks once rather than twice.
    public func downloadSource(for id: MediaID, options: StreamOptions) async throws -> StreamSource {
        // One transfer, whatever the codec — see `streamSource`. A kept copy
        // that is one file is a kept copy the system can carry with the app
        // closed, which is what a segmented conversion never could.
        return StreamSource(request: try await downloadRequest(for: id, options: options))
    }

    /// The master playlist for an AAC conversion.

    /// What a Plex server can do, which is the same for all of them.
    public static let expectedCapabilities: ServerCapabilities = [
        .ratings, .halfStarRatings, .genreBrowsing, .playlists,
        .playlistReorder, .scrobbling, .randomBrowse, .albumInfo, .artistInfo,
        .criticRatings,
        .topTracks, .similarAlbums, .similarItems, .smartPlaylists,
        .collections, .collectionEditing, .syncedLyrics, .playHistory,
        // A conversion can be asked to begin part-way in, so a seek past
        // what has arrived is a fresh request rather than a wait.
        .transcodeOffset,
    ]

    public var capabilities: ServerCapabilities { Self.expectedCapabilities }

    // MARK: Connection

    public func testConnection() async throws -> ServerInfo {
        let container = try await get("/", query: [])
        return ServerInfo(
            productName: "Plex",
            productVersion: container.mediaContainer.version,
            apiVersion: nil,
            isOpenSubsonic: false,
            extensions: []
        )
    }

    // MARK: Browsing

    public func artists() async throws -> [Artist] {
        // `includeGuids=1` is what makes Plex send the `Guid` array a matched artist's MusicBrainz
        // id lives in — without it every artist looks unmatched, `Guid` and all, whether or not
        // Plex actually matched one.
        let artists = try await sectionItems(
            query: [
                URLQueryItem(name: "type", value: String(ItemType.artist.rawValue)),
                URLQueryItem(name: "includeGuids", value: "1"),
            ],
            offset: 0,
            limit: 0
        )
        .compactMap { PlexMapper.artist($0, server: serverID) }
        // The name-to-id lookup a compilation track needs is exactly this list, so remember it here
        // rather than fetching all 1 473 artists a second time the first time a page has a guest
        // credit on it.
        artistIDByNameCache.withLock { cache in
            cache = Dictionary(
                artists.map { ($0.name.lowercased(), $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return artists
    }

    /// One page of songs, without the artists and albums the empty-query search would fetch
    /// alongside them.
    public func tracks(offset: Int, limit: Int) async throws -> [Track] {
        try await mapTracks(sectionItems(type: .track, offset: offset, limit: limit))
    }

    /// What the server says the library holds, three tiny requests.
    public func libraryCounts() async throws -> LibraryCounts {
        async let artists = sectionTotal(type: .artist)
        async let albums = sectionTotal(type: .album)
        async let tracks = sectionTotal(type: .track)
        return LibraryCounts(
            artists: await artists,
            albums: await albums,
            tracks: await tracks
        )
    }

    /// `contentChangedAt` on this library's own section.
    public func libraryChangeToken() async throws -> String? {
        let request = URLRequest(url: url(path: "/library/sections", query: []))
        // A probe that cannot be made is a probe with no answer, not a failure: a timeout here must
        // read as "walk the library", exactly like a server that has no such field, rather than as
        // a sync that could not run.
        guard let (data, response) = try? await transport.perform(authenticated(request)),
              (try? PlexClient.check(response, data: data)) != nil,
              !data.isEmpty,
              let decoded = try? PlexClient.decoder.decode(PlexSectionStampResponse.self, from: data),
              let section = decoded.mediaContainer.directory?
                  .first(where: { $0.key == config.sectionKey }),
              let stamp = section.contentChangedAt
        else { return nil }
        // Prefixed by what produced it. The token is stored beside a library
        // that keeps its identity when its address is edited, and a bare
        // counter from one server is a plausible counter from another.
        return "plex:\(config.sectionKey):\(stamp)"
    }

    /// The count of one kind of thing in this section, or nil if the server did not say.
    private func sectionTotal(type: ItemType) async -> Int? {
        var request = URLRequest(url: url(
            path: "/library/sections/\(config.sectionKey)/all",
            query: [URLQueryItem(name: "type", value: String(type.rawValue))]
        ))
        request.setValue("0", forHTTPHeaderField: "X-Plex-Container-Start")
        request.setValue("1", forHTTPHeaderField: "X-Plex-Container-Size")
        guard let (data, response) = try? await transport.perform(authenticated(request)),
              (try? PlexClient.check(response, data: data)) != nil,
              !data.isEmpty,
              let decoded = try? PlexClient.decoder.decode(PlexLibraryResponse.self, from: data)
        else { return nil }
        return decoded.mediaContainer.totalSize
    }

    /// Maps a page of track rows, resolving each one's own artist — see
    /// `PlexMapper.track(_:server:resolvingArtistIDByName:)`.
    private func mapTracks(_ rows: [PlexMetadata]) async throws -> [Track] {
        let resolver = try await resolverIfNeeded(for: rows)
        return rows.compactMap { PlexMapper.track($0, server: serverID, resolvingArtistIDByName: resolver) }
    }

    /// The lookup `PlexMapper.track` needs to get a compilation track's own artist right, fetched
    /// only when this particular page could actually have a row that needs it — an ordinary album's
    /// tracks never do, and cost nothing extra to map.
    private func resolverIfNeeded(for rows: [PlexMetadata]) async throws -> [String: MediaID] {
        let mayNeedResolving = rows.contains {
            guard let credit = $0.originalTitle, !credit.isEmpty else { return false }
            return credit != $0.grandparentTitle
        }
        return try await mayNeedResolving ? artistIDByName() : [:]
    }

    private func artistIDByName() async throws -> [String: MediaID] {
        if let cached = artistIDByNameCache.withLock({ $0 }) { return cached }
        // Fills the cache on the way through; the return here is only for
        // the caller that arrived before anything else had asked.
        _ = try await artists()
        return artistIDByNameCache.withLock { $0 } ?? [:]
    }

    public func artist(id: MediaID) async throws -> ArtistDetail {
        async let artistRow = metadata(id)
        async let albumRows = children(of: id)
        let row = try await artistRow
        guard let artist = PlexMapper.artist(row, server: serverID) else {
            throw ProviderError.notFound
        }
        let rows = try await completingReleaseTypes(albumRows)
        let albums = rows.compactMap { PlexMapper.album($0, server: serverID) }
        return ArtistDetail(artist: artist, albums: albums)
    }

    /// Fills in Format/Subformat when a listing left them out.
    private func completingReleaseTypes(_ rows: [PlexMetadata]) async throws -> [PlexMetadata] {
        guard !rows.isEmpty else { return rows }
        let missingEverywhere = rows.allSatisfy {
            ($0.format?.isEmpty ?? true) && ($0.subformat?.isEmpty ?? true)
        }
        guard missingEverywhere else { return rows }

        let keys = rows.compactMap(\.ratingKey)
        guard !keys.isEmpty else { return rows }

        // Chunked: a sync page is up to 500 albums, and every key in one URL
        // would build a request line long enough for a server or a proxy in
        // front of it to refuse.
        var byKey: [String: PlexMetadata] = [:]
        for chunk in stride(from: 0, to: keys.count, by: Self.metadataBatchSize) {
            let slice = keys[chunk..<min(chunk + Self.metadataBatchSize, keys.count)]
            guard let container = try? await get(
                "/library/metadata/\(slice.joined(separator: ","))",
                query: []
            ) else { continue }
            for row in container.mediaContainer.metadata ?? [] {
                if let key = row.ratingKey { byKey[key] = row }
            }
        }
        guard !byKey.isEmpty else { return rows }

        // Merged by key rather than by position: a batched fetch may drop an
        // item, and pairing them up by index would then mislabel the rest.
        return rows.map { row in
            guard let key = row.ratingKey, let detailed = byKey[key] else { return row }
            return detailed
        }
    }

    private static let metadataBatchSize = 80

    public func artistInfo(id: MediaID) async throws -> ArtistInfo {
        // Two different questions, asked at once. The biography is what the
        // server was told about this artist; the neighbours are what it
        // worked out for itself by listening.
        async let row = metadata(id)
        async let neighbours = nearestArtists(to: id, limit: Self.similarArtistCount)
        return ArtistInfo(
            biography: try await row.summary?.nonEmpty,
            similarArtists: await neighbours
        )
    }

    /// How many neighbours to ask for. A shelf, not a directory: past a
    /// dozen or so nobody is reading names, and every one of them is a row
    /// the artist page has to draw.
    private static let similarArtistCount = 12

    /// Artists the server judges to sound like this one.
    private func nearestArtists(to id: MediaID, limit: Int) async -> [Artist] {
        let rows = (try? await nearest(to: id, ofType: "artist", limit: limit)) ?? []
        return rows
            .compactMap { PlexMapper.artist($0, server: serverID) }
            .filter { $0.id != id }
    }

    /// Plex's own sonic-analysis neighbours for a piece of media, nearest first — the same
    /// `/nearest` endpoint behind `similarTracks`, `similarAlbums`, and `nearestArtists`, each
    /// asking for and filtering to its own kind.
    private func nearest(to id: MediaID, ofType type: String, limit: Int) async throws -> [PlexMetadata] {
        let container = try await get(
            "/library/metadata/\(id.rawValue)/nearest",
            query: [
                URLQueryItem(name: "limit", value: String(max(1, limit))),
                // The server's own default is strict enough to answer with
                // one match or none. Nearest still comes first, so a wider
                // net only lengthens the tail.
                URLQueryItem(name: "maxDistance", value: "0.5"),
            ]
        )
        return (container.mediaContainer.metadata ?? [])
            // The endpoint answers with the seed's own type, but it costs
            // nothing to be sure: a row of the wrong kind mapped through
            // would be a link to a page that does not exist.
            .filter { $0.type == type }
    }

    public func albumInfo(id: MediaID) async throws -> AlbumInfo {
        let row = try await metadata(id)
        return AlbumInfo(notes: row.summary?.nonEmpty, musicBrainzID: nil)
    }

    /// Plex's own sonic analysis: `/library/metadata/<key>/nearest`, which answers with records of
    /// the same kind as the one asked about, nearest first.
    public func similarTracks(to id: MediaID, limit: Int) async throws -> [Track] {
        let rows = try await nearest(to: id, ofType: "track", limit: limit)
        return try await mapTracks(rows).filter { $0.id != id }
    }

    public func similarAlbums(to id: MediaID, limit: Int) async throws -> [Album] {
        let rows = try await nearest(to: id, ofType: "album", limit: limit)
        return rows
            .compactMap { PlexMapper.album($0, server: serverID) }
            .filter { $0.id != id }
    }

    public func albums(filter: AlbumFilter, offset: Int, limit: Int) async throws -> [Album] {
        var query = [URLQueryItem(name: "type", value: String(ItemType.album.rawValue))]
        query += Self.sortAndFilter(for: filter)
        let rows = try await sectionItems(query: query, offset: offset, limit: limit)
        // The library sync builds the local index from this call, and the
        // artist page's sections are grouped from that index — so the release
        // types have to be complete *here*, not only on the artist fetch.
        let complete = try await completingReleaseTypes(rows)
        return complete.compactMap { PlexMapper.album($0, server: serverID) }
    }

    public func album(id: MediaID) async throws -> AlbumDetail {
        async let albumRow = metadata(id)
        async let trackRows = children(of: id)
        guard let album = PlexMapper.album(try await albumRow, server: serverID) else {
            throw ProviderError.notFound
        }
        // Put in order here, exactly as `SubsonicProvider.album` orders its own, rather than
        // trusting the sequence `/children` happens to answer in: Plex is asked for no order and
        // promises none.
        let tracks = try await mapTracks(trackRows)
            .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
        return AlbumDetail(album: album, tracks: tracks)
    }

    /// The artist's popular tracks — how the audience ranks them, per Plex's own `ratingCount`, not
    /// what this listener has played or rated.
    public func topTracks(forArtist id: MediaID, limit: Int) async throws -> [Track] {
        let rows = try await sectionItems(
            query: [
                URLQueryItem(name: "type", value: String(ItemType.track.rawValue)),
                URLQueryItem(name: "artist.id", value: id.rawValue),
                URLQueryItem(name: "album.subformat!", value: "Compilation,Live"),
                URLQueryItem(name: "group", value: "title"),
                URLQueryItem(name: "sort", value: "ratingCount:desc"),
            ],
            offset: 0,
            limit: limit
        )
        return try await mapTracks(rows)
    }

    public func track(id: MediaID) async throws -> Track {
        let row = try await metadata(id)
        guard let track = try await mapTracks([row]).first else {
            throw ProviderError.notFound
        }
        return track
    }

    public func genres() async throws -> [Genre] {
        let container = try await get(
            "/library/sections/\(config.sectionKey)/genre",
            query: [URLQueryItem(name: "type", value: String(ItemType.album.rawValue))]
        )
        return (container.mediaContainer.directory ?? []).compactMap { directory in
            guard let title = directory.title else { return nil }
            return Genre(name: title)
        }
    }

    /// The genres Plex files artists under — its own tagging rather than
    /// anything worked out from their music.
    public func artistGenres() async throws -> [Genre] {
        let container = try await get(
            "/library/sections/\(config.sectionKey)/genre",
            query: [URLQueryItem(name: "type", value: String(ItemType.artist.rawValue))]
        )
        return (container.mediaContainer.directory ?? []).compactMap { directory in
            guard let title = directory.title else { return nil }
            // The key is the tag's own id, which is what the section filter
            // takes; the name is only its label.
            return Genre(name: title, serverKey: directory.key)
        }
    }

    public func artists(inGenre genre: Genre) async throws -> [Artist] {
        let container = try await get(
            "/library/sections/\(config.sectionKey)/all",
            query: [
                URLQueryItem(name: "type", value: String(ItemType.artist.rawValue)),
                URLQueryItem(name: "genre", value: genre.serverKey ?? genre.name),
            ]
        )
        return (container.mediaContainer.metadata ?? [])
            .compactMap { PlexMapper.artist($0, server: serverID) }
    }

    public func search(_ query: String, limit: Int, offset: Int) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The sync path asks for everything with an empty query, which Plex's
        // search endpoint will not do — so it falls back to listing.
        guard !trimmed.isEmpty else {
            async let artistRows = sectionItems(type: .artist, offset: offset, limit: limit)
            async let albumRows = sectionItems(type: .album, offset: offset, limit: limit)
            async let trackRows = sectionItems(type: .track, offset: offset, limit: limit)
            return SearchResults(
                artists: try await artistRows.compactMap { PlexMapper.artist($0, server: serverID) },
                albums: try await albumRows.compactMap { PlexMapper.album($0, server: serverID) },
                tracks: try await mapTracks(trackRows)
            )
        }

        func find(_ type: ItemType) async throws -> [PlexMetadata] {
            try await sectionItems(
                query: [
                    URLQueryItem(name: "type", value: String(type.rawValue)),
                    URLQueryItem(name: "title", value: trimmed),
                ],
                offset: offset,
                limit: limit
            )
        }

        async let artistRows = find(.artist)
        async let albumRows = find(.album)
        async let trackRows = find(.track)
        return SearchResults(
            artists: try await artistRows.compactMap { PlexMapper.artist($0, server: serverID) },
            albums: try await albumRows.compactMap { PlexMapper.album($0, server: serverID) },
            tracks: try await mapTracks(trackRows)
        )
    }

    public func randomTracks(limit: Int) async throws -> [Track] {
        let rows = try await sectionItems(
            query: [
                URLQueryItem(name: "type", value: String(ItemType.track.rawValue)),
                URLQueryItem(name: "sort", value: "random"),
            ],
            offset: 0,
            limit: limit
        )
        return try await mapTracks(rows)
    }

    // MARK: Playlists

    public func playlists() async throws -> [Playlist] {
        let container = try await get(
            "/playlists",
            query: [
                URLQueryItem(name: "playlistType", value: "audio"),
                // Scoped to the library in use. Plex keeps playlists at the
                // account level, so without this a library of five hundred
                // songs lists the playlists of one with sixty thousand.
                URLQueryItem(name: "sectionID", value: config.sectionKey),
            ]
        )
        return (container.mediaContainer.metadata ?? []).compactMap(playlist(from:))
    }

    public func playlist(id: MediaID) async throws -> PlaylistDetail {
        async let header = metadata(id)
        async let rows = playlistItems(id)
        guard let playlist = playlist(from: try await header) else { throw ProviderError.notFound }
        return PlaylistDetail(
            playlist: playlist,
            entries: try await entries(from: try await rows, startingAt: 0)
        )
    }

    public func playlistPage(id: MediaID, offset: Int, limit: Int) async throws -> PlaylistPage {
        async let header = metadata(id)
        async let page = playlistItems(id, offset: offset, limit: limit)
        guard let playlist = playlist(from: try await header) else { throw ProviderError.notFound }
        let (rows, total) = try await page
        return PlaylistPage(
            playlist: playlist,
            entries: try await entries(from: rows, startingAt: offset),
            total: total,
            returnedRows: rows.count
        )
    }

    private func entries(from rows: [PlexMetadata], startingAt offset: Int) async throws -> [PlaylistEntry] {
        let resolver = try await resolverIfNeeded(for: rows)
        return rows.enumerated().compactMap { index, row -> PlaylistEntry? in
            guard let track = PlexMapper.track(row, server: serverID, resolvingArtistIDByName: resolver) else {
                return nil
            }
            // Plex gives every row its own `playlistItemId`, so entries are stable identities
            // rather than positions — duplicates and reorders are unambiguous, unlike Subsonic.
            let raw = row.playlistItemID.map(String.init) ?? "index:\(offset + index)"
            return PlaylistEntry(
                entryID: PlaylistEntryID(server: serverID, rawValue: raw),
                track: track
            )
        }
    }

    public func createPlaylist(name: String, trackIDs: [MediaID]) async throws -> Playlist {
        let container = try await request(
            method: "POST",
            path: "/playlists",
            query: [
                URLQueryItem(name: "type", value: "audio"),
                URLQueryItem(name: "title", value: name),
                URLQueryItem(name: "smart", value: "0"),
                URLQueryItem(name: "uri", value: libraryURI(for: trackIDs)),
            ]
        )
        guard let created = (container.mediaContainer.metadata ?? []).compactMap(playlist(from:)).first else {
            throw ProviderError.malformedResponse(details: "Plex created no playlist")
        }
        return created
    }

    /// Creates a playlist the *server* keeps up to date.
    public func createSmartPlaylist(name: String, query: SmartQuery) async throws -> Playlist {
        guard let items = PlexSmartQuery.queryItems(for: query) else {
            throw ProviderError.malformedResponse(
                details: "This filter cannot be written as a Plex smart playlist"
            )
        }
        var section = URLComponents()
        section.queryItems = items
        let filter = section.percentEncodedQuery ?? ""
        let uri = """
            server://\(config.machineIdentifier)/com.plexapp.plugins.library\
            /library/sections/\(config.sectionKey)/all?\(filter)
            """

        let container = try await request(
            method: "POST",
            path: "/playlists",
            query: [
                URLQueryItem(name: "type", value: "audio"),
                URLQueryItem(name: "title", value: name),
                URLQueryItem(name: "smart", value: "1"),
                URLQueryItem(name: "uri", value: uri),
            ]
        )
        guard let created = (container.mediaContainer.metadata ?? []).compactMap(playlist(from:)).first else {
            throw ProviderError.malformedResponse(details: "Plex created no playlist")
        }
        return created
    }

    // MARK: Collections

    public func collections() async throws -> [MediaCollection] {
        let container = try await get(
            "/library/sections/\(config.sectionKey)/collections",
            query: []
        )
        return (container.mediaContainer.metadata ?? []).compactMap(collection(from:))
    }

    public func albums(inCollection id: MediaID) async throws -> [Album] {
        // The collections path, not the metadata one: a metadata child
        // lookup answers for a real hierarchy — an artist's records — and
        // comes back empty for a collection of records.
        let container = try await get("/library/collections/\(id.rawValue)/children", query: [])
        return (container.mediaContainer.metadata ?? [])
            .filter { $0.type == "album" }
            .compactMap { PlexMapper.album($0, server: serverID) }
    }

    public func artists(inCollection id: MediaID) async throws -> [Artist] {
        let container = try await get("/library/collections/\(id.rawValue)/children", query: [])
        return (container.mediaContainer.metadata ?? [])
            .filter { $0.type == "artist" }
            .compactMap { PlexMapper.artist($0, server: serverID) }
    }

    public func createCollection(
        name: String,
        kind: MediaCollection.Kind,
        itemIDs: [MediaID]
    ) async throws -> MediaCollection {
        guard !itemIDs.isEmpty else {
            throw ProviderError.malformedResponse(details: "A collection needs something in it")
        }
        let container = try await request(
            method: "POST",
            path: "/library/collections",
            query: [
                URLQueryItem(name: "type", value: String(Self.plexType(for: kind))),
                URLQueryItem(name: "title", value: name),
                URLQueryItem(name: "smart", value: "0"),
                URLQueryItem(name: "sectionId", value: config.sectionKey),
                URLQueryItem(name: "uri", value: libraryURI(for: itemIDs)),
            ]
        )
        guard let created = (container.mediaContainer.metadata ?? []).compactMap(collection(from:)).first else {
            throw ProviderError.malformedResponse(details: "Plex created no collection")
        }
        return created
    }

    public func addToCollection(id: MediaID, itemIDs: [MediaID]) async throws {
        guard !itemIDs.isEmpty else { return }
        _ = try await request(
            method: "PUT",
            path: "/library/collections/\(id.rawValue)/items",
            query: [URLQueryItem(name: "uri", value: libraryURI(for: itemIDs))]
        )
    }

    /// Plex's numbering, the same one its filters use.
    private static func plexType(for kind: MediaCollection.Kind) -> Int {
        switch kind {
        case .albums: 9
        case .artists: 8
        }
    }

    /// A collection row. Without a subtype there is no telling records from
    /// artists, and showing a shelf of the wrong thing is worse than leaving
    /// it out.
    private func collection(from row: PlexMetadata) -> MediaCollection? {
        guard let id = PlexMapper.mediaID(row.ratingKey, server: serverID),
              let name = row.title,
              let kind = MediaCollection.Kind(plexSubtype: row.subtype)
        else { return nil }
        return MediaCollection(
            id: id,
            name: name,
            kind: kind,
            itemCount: row.childCount ?? row.leafCount,
            // A collection's own picture is a composite of what is in it
            // until someone sets one.
            artwork: PlexMapper.artwork(row.thumb ?? row.composite, server: serverID)
        )
    }

    public func renamePlaylist(id: MediaID, name: String) async throws {
        _ = try await request(
            method: "PUT",
            path: "/playlists/\(id.rawValue)",
            query: [URLQueryItem(name: "title", value: name)]
        )
    }

    public func addToPlaylist(id: MediaID, trackIDs: [MediaID]) async throws {
        _ = try await request(
            method: "PUT",
            path: "/playlists/\(id.rawValue)/items",
            query: [URLQueryItem(name: "uri", value: libraryURI(for: trackIDs))]
        )
    }

    public func removeFromPlaylist(id: MediaID, entries: [PlaylistEntryID]) async throws {
        for entry in entries {
            guard !entry.rawValue.hasPrefix("index:") else {
                throw ProviderError.conflict(details: "playlist entry no longer exists")
            }
            _ = try await request(
                method: "DELETE",
                path: "/playlists/\(id.rawValue)/items/\(entry.rawValue)",
                query: []
            )
        }
    }

    public func reorderPlaylist(id: MediaID, orderedEntries: [PlaylistEntryID]) async throws {
        // Plex moves one row at a time, each after a named predecessor, so
        // the list is walked in order and each row placed behind the last.
        var previous: PlaylistEntryID?
        for entry in orderedEntries {
            var query: [URLQueryItem] = []
            if let previous {
                query.append(URLQueryItem(name: "after", value: previous.rawValue))
            }
            _ = try await request(
                method: "PUT",
                path: "/playlists/\(id.rawValue)/items/\(entry.rawValue)/move",
                query: query
            )
            previous = entry
        }
    }

    // MARK: State

    public func setFavorite(_ favorite: Bool, for id: MediaID, kind: MediaKind) async throws {
        throw ProviderError.unsupportedOperation(needs: .favorites)
    }

    public func setRating(_ rating: StarRating?, for id: MediaID) async throws {
        _ = try await request(
            method: "PUT",
            path: "/:/rate",
            query: [
                URLQueryItem(name: "key", value: id.rawValue),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "rating", value: String(format: "%.1f", PlexMapper.plexRating(from: rating))),
            ]
        )
    }

    /// Tells Plex what is playing, for its own dashboard.
    public func report(_ playback: PlaybackReport) async throws {
        let key = "/library/metadata/\(playback.id.rawValue)"
        var query = [
            URLQueryItem(name: "ratingKey", value: playback.id.rawValue),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "state", value: playback.state.rawValue),
            URLQueryItem(name: "time", value: String(Self.milliseconds(playback.position))),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: playSession),
        ]
        if let duration = playback.duration {
            query.append(
                URLQueryItem(name: "duration", value: String(Self.milliseconds(duration)))
            )
        }
        _ = try await request(method: "GET", path: "/:/timeline", query: query)
    }

    /// Plex counts in milliseconds, and will not have a negative one.
    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds * 1000)
    }

    public func scrobble(id: MediaID, at date: Date, submission: Bool) async throws {
        // Counting the play only. What is playing *now* goes to the timeline
        // instead — see `report(_:)`.
        guard submission else { return }
        _ = try await request(
            method: "GET",
            path: "/:/scrobble",
            query: [
                URLQueryItem(name: "key", value: id.rawValue),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            ]
        )
    }

    /// Every individual play in `[from, to)` — the server's own session history, not the single
    /// `lastViewedAt` a plain track row already carries.
    public func playHistory(from: Date, to: Date, limit: Int) async throws -> [PlayHistoryEntry] {
        guard limit > 0, from < to else { return [] }
        var entries: [PlayHistoryEntry] = []
        var start = 0
        let pageSize = 200
        paging: while entries.count < limit {
            var request = URLRequest(url: url(
                path: "/status/sessions/history/all",
                query: [
                    URLQueryItem(name: "sort", value: "viewedAt:asc"),
                    URLQueryItem(name: "librarySectionID", value: config.sectionKey),
                    // Strictly greater-than on the server, like every other Plex inequality filter
                    // (see `.yearRange`'s own `- 1` for the identical reason) — a play at exactly
                    // `from` would otherwise be excluded before the client-side `playedAt >= from`
                    // below…
                    URLQueryItem(name: "viewedAt>", value: String(Int64(from.timeIntervalSince1970) - 1)),
                ]
            ))
            request.setValue(String(start), forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue(String(pageSize), forHTTPHeaderField: "X-Plex-Container-Size")
            let (data, response) = try await transport.perform(authenticated(request))
            try PlexClient.check(response, data: data)
            guard !data.isEmpty else { break }
            let page: [PlexMetadata]
            do {
                page = try PlexClient.decoder.decode(PlexLibraryResponse.self, from: data)
                    .mediaContainer.metadata ?? []
            } catch {
                throw ProviderError.malformedResponse(details: "/status/sessions/history/all: \(error)")
            }
            guard !page.isEmpty else { break }
            for row in page {
                // The `type` filter above is an ask, not a guarantee — every other read in this
                // file treats it the same way, checking the row's own answer rather than trusting
                // the query was honoured.
                guard row.type == "track",
                      let trackID = PlexMapper.mediaID(ratingKey: row.ratingKey, orPath: row.key, server: serverID),
                      let viewedAt = row.viewedAt
                else { continue }
                let playedAt = Date(timeIntervalSince1970: TimeInterval(viewedAt))
                // The real guarantee that nothing outside the window comes back, whatever the
                // server itself did or did not honour above.
                guard playedAt < to else { break paging }
                guard playedAt >= from else { continue }
                entries.append(PlayHistoryEntry(
                    trackID: trackID,
                    albumID: PlexMapper.mediaID(ratingKey: row.parentRatingKey, orPath: row.parentKey, server: serverID),
                    playedAt: playedAt
                ))
                if entries.count == limit { break paging }
            }
            // A page shorter than what was asked for is the last one there
            // is, whatever end of the window it stopped short of.
            guard page.count == pageSize else { break }
            start += pageSize
        }
        return entries
    }

    // MARK: Media requests

    public func streamRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
        try await mediaRequest(
            for: id,
            options: options,
            session: playSession(for: id),
            reportingAs: playSession
        )
    }

    private func mediaRequest(
        for id: MediaID,
        options: StreamOptions,
        session: String?,
        reportingAs identifier: String? = nil
    ) async throws -> URLRequest {
        // Direct play unless the caller asked for a conversion — which it only does for codecs the
        // device cannot decode.
        guard let codec = options.transcodeTo else {
            // Only this branch needs the metadata, and only for the part's own key.
            let row = try await metadata(id)
            guard let key = row.media?.first?.part?.first?.key else {
                // The item exists but has no file behind it: still being scanned, moved out from
                // under Plex, or on a drive that is not mounted.
                throw ProviderError.serverError(
                    code: nil,
                    message: "No playable file for item \(id.rawValue) in \(config.sectionTitle). The library may still be scanning, or the file has moved.",
                    helpURL: nil
                )
            }
            return authenticatedMedia(URLRequest(url: url(path: key, query: [])))
        }
        return authenticatedMedia(URLRequest(url: transcodeURL(
            metadataKey: "/library/metadata/\(id.rawValue)",
            // What was actually chosen — or the nearest thing this server will actually send.
            codec: deliverable(codec),
            maxBitRateKbps: options.maxBitRateKbps,
            startOffset: options.startOffset,
            session: session,
            reportingAs: identifier
        )))
    }

    /// Names this installation's own now-playing transcode.
    private var playSession: String {
        let device = identity.device.replacingOccurrences(of: " ", with: "")
        return "\(identity.clientIdentifier)-\(device)"
    }

    /// The name *this song's* conversion runs under while it is playing.
    private func playSession(for id: MediaID) -> String {
        "\(playSession)-\(id.rawValue)"
    }

    /// Plex's universal transcoder.
    private func transcodeURL(
        metadataKey: String,
        codec: TranscodeCodec,
        maxBitRateKbps: Int?,
        startOffset: TimeInterval? = nil,
        session: String? = nil,
        reportingAs identifier: String? = nil
    ) -> URL {
        var query = [
            URLQueryItem(name: "path", value: metadataKey),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "http"),
            // Neither of these is a conversion, and leaving them open lets the server answer a
            // request to convert with the file as it stands — which is right for a player that
            // wanted the original and wrong for one that asked for a smaller copy.
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "copyts", value: "1"),
            // Where in the song the conversion should begin. A seek past
            // what has arrived is a new conversion from there rather than a
            // wait — see `StreamOptions.startOffset`.
            URLQueryItem(
                name: "offset",
                value: String(Int((startOffset ?? 0).rounded()))
            ),
            URLQueryItem(name: "session", value: session ?? playSession),
            URLQueryItem(
                name: "X-Plex-Session-Identifier",
                value: identifier ?? session ?? playSession
            ),
        ]
        if let maxBitRateKbps, maxBitRateKbps > 0 {
            // Both, and `musicBitrate` is the one that decides anything.
            query.append(URLQueryItem(name: "musicBitrate", value: String(maxBitRateKbps)))
            query.append(URLQueryItem(name: "maxAudioBitrate", value: String(maxBitRateKbps)))
        }
        // The extension alone does not decide the output: ask for AAC by filename and Plex sends
        // MP3 anyway.
        query.append(URLQueryItem(
            name: "X-Plex-Client-Profile-Extra",
            value: Self.clientProfile(for: codec, maxBitRateKbps: maxBitRateKbps)
        ))
        return url(path: "/music/:/transcode/universal/start.\(Self.transcodeExtension(for: codec))", query: query)
    }

    /// Tells Plex which single format this request will accept.
    static func clientProfile(for codec: TranscodeCodec, maxBitRateKbps: Int?) -> String {
        var directive = "add-transcode-target(type=musicProfile&context=streaming"
            + "&protocol=http&container=\(Self.container(for: codec))"
            + "&audioCodec=\(codec.rawValue)"
            // The word that makes any of this take effect.
            + "&replace=true)"
        if let maxBitRateKbps, maxBitRateKbps > 0 {
            // Said a third way, because `musicBitrate` alone is advice and `maxAudioBitrate` alone
            // is a ceiling.
            directive += "+add-limitation(scope=musicCodec&scopeName=\(codec.rawValue)"
                + "&type=upperBound&name=audio.bitrate&value=\(maxBitRateKbps)"
                + "&replace=true)"
        }
        return directive
    }

    /// What the conversion arrives wrapped in.
    static func container(for codec: TranscodeCodec) -> String {
        switch codec {
        case .mp3: "mp3"
        case .aac: "mp4"
        case .opus: "ogg"
        }
    }

    /// The name the conversion is asked for by, which is the container and
    /// not the codec: `start.ogg` for Opus, because Ogg is what it comes in
    /// and what every reader decides by.
    private static func transcodeExtension(for codec: TranscodeCodec) -> String {
        switch codec {
        case .mp3: "mp3"
        // Plex delivers AAC in an MPEG-4 container.
        case .aac: "m4a"
        case .opus: "ogg"
        }
    }

    /// The name this song's download converts under.
    private func downloadSession(for id: MediaID) -> String {
        "\(playSession)-download-\(id.rawValue)"
    }

    /// Stops the conversion opened for a download.
    public func endConversion(for id: MediaID) async {
        _ = try? await get(
            "/video/:/transcode/universal/stop",
            query: [URLQueryItem(name: "session", value: downloadSession(for: id))]
        )
    }

    /// Stops the conversion a song was played through.
    public func endPlayback(for id: MediaID) async {
        _ = try? await get(
            "/video/:/transcode/universal/stop",
            query: [URLQueryItem(name: "session", value: playSession(for: id))]
        )
    }

    public func downloadRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
        // Its own transcode session, named after the song.
        var request = try await mediaRequest(
            for: id,
            options: options,
            session: downloadSession(for: id)
        )
        request.url = request.url?.appending(queryItems: [URLQueryItem(name: "download", value: "1")])
        return request
    }

    public func artworkRequest(for id: ArtworkID, size: Int?) async throws -> URLRequest {
        // Plex's photo transcoder resizes server-side, which is the whole
        // reason the app asks for a size rather than a full-resolution cover.
        guard let size else {
            return authenticated(URLRequest(url: url(path: id.rawValue, query: [])))
        }
        // The path stays relative.
        let transcoded = url(
            path: "/photo/:/transcode",
            query: [
                URLQueryItem(name: "width", value: String(size)),
                URLQueryItem(name: "height", value: String(size)),
                URLQueryItem(name: "minSize", value: "1"),
                URLQueryItem(name: "upscale", value: "0"),
                URLQueryItem(name: "url", value: id.rawValue),
            ]
        )
        return authenticated(URLRequest(url: transcoded))
    }

    /// Plex's own loudness analysis, drawn as the seek bar's waveform.
    public func loudnessEnvelope(for id: MediaID, bars: Int) async throws -> [Float]? {
        guard bars > 0 else { return nil }
        let item = try await metadata(id)
        guard let streamID = item.media?
            .compactMap({ $0.part?.first })
            .compactMap({ $0.stream?.first { $0.streamType == 2 } })
            .first?
            .id
        else { return nil }

        var request = URLRequest(url: url(path: "/library/streams/\(streamID)/loudness", query: []))
        request.httpMethod = "GET"
        let (data, response) = try await transport.perform(authenticated(request))
        guard response.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let decibels = text
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard decibels.count > 1 else { return nil }

        // Decibels to amplitude, on an absolute scale — not stretched to the track's own loudest
        // point.
        let amplitudes = decibels.map { min(1, pow(10, $0 / 20)) }
        let perBar = Double(amplitudes.count) / Double(bars)
        var levels: [Double] = []
        levels.reserveCapacity(bars)
        for bar in 0..<bars {
            let start = Int(Double(bar) * perBar)
            let end = max(start + 1, Int(Double(bar + 1) * perBar))
            let slice = amplitudes[start..<min(end, amplitudes.count)]
            // The loudest moment in the bucket, not the average: a mean of a
            // hundred windows is a flat line by construction.
            levels.append(slice.max() ?? 0)
        }

        guard levels.contains(where: { $0 > 0 }) else { return nil }
        // One fixed gain for every track, so the strip uses its height
        // without any song being stretched to fit it. See `WaveformLevels`.
        return levels.map { WaveformLevels.forDisplay(Float($0)) }
    }

    /// Plex keeps lyrics as a *stream* of the file, beside the audio, and hands over the path to
    /// the file rather than its contents.
    public func lyrics(for id: MediaID) async throws -> Lyrics? {
        guard let key = PlexMapper.lyricStreamKey(in: try await metadata(id)) else { return nil }
        guard let text = try await lyricFile(at: key) else { return nil }
        return LyricsFile.parse(text)
    }

    /// Fetches a lyric file, or nothing when the server has none behind the stream it advertised.
    private func lyricFile(at key: String) async throws -> String? {
        var request = URLRequest(url: url(path: key, query: []))
        request.httpMethod = "GET"
        let (data, response) = try await transport.perform(authenticatedMedia(request))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try PlexClient.check(response, data: data)
        guard !data.isEmpty else { return nil }
        // Lyric files are text of unstated encoding. UTF-8 is what modern
        // taggers write; Latin-1 is what older ones did, and it cannot fail,
        // so between them there is no file this refuses to read.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: Requests

    private func url(path: String, query: [URLQueryItem]) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appending(path: trimmed)
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.appending(queryItems: query)
        }
        components.queryItems = query
        // A plus is a legal character in a query string, so Foundation hands it over untouched —
        // and a server that reads the query as form data reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? url.appending(queryItems: query)
    }

    /// The token travels as a header, not a query parameter, so it stays out of proxy access logs.
    private func authenticatedMedia(_ request: URLRequest) -> URLRequest {
        var request = authenticated(request)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    private func authenticated(_ request: URLRequest) -> URLRequest {
        var authenticated = request
        for (name, value) in identity.headers(token: config.token) {
            authenticated.setValue(value, forHTTPHeaderField: name)
        }
        return authenticated
    }

    @discardableResult
    private func request(
        method: String,
        path: String,
        query: [URLQueryItem]
    ) async throws -> PlexLibraryResponse {
        var request = URLRequest(url: url(path: path, query: query))
        request.httpMethod = method
        let (data, response) = try await transport.perform(authenticated(request))
        try PlexClient.check(response, data: data)
        guard !data.isEmpty else { return .empty }
        do {
            return try PlexClient.decoder.decode(PlexLibraryResponse.self, from: data)
        } catch {
            // Loudly.
            throw ProviderError.malformedResponse(
                details: "\(path): \(error)"
            )
        }
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> PlexLibraryResponse {
        try await request(method: "GET", path: path, query: query)
    }

    private func sectionItems(
        type: ItemType,
        offset: Int = 0,
        limit: Int = 0
    ) async throws -> [PlexMetadata] {
        try await sectionItems(
            query: [URLQueryItem(name: "type", value: String(type.rawValue))],
            offset: offset,
            limit: limit
        )
    }

    private func sectionItems(
        query: [URLQueryItem],
        offset: Int,
        limit: Int
    ) async throws -> [PlexMetadata] {
        var request = URLRequest(url: url(path: "/library/sections/\(config.sectionKey)/all", query: query))
        if limit > 0 {
            // Plex pages with headers rather than query parameters.
            request.setValue(String(offset), forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue(String(limit), forHTTPHeaderField: "X-Plex-Container-Size")
        }
        let (data, response) = try await transport.perform(authenticated(request))
        try PlexClient.check(response, data: data)
        do {
            return try PlexClient.decoder.decode(PlexLibraryResponse.self, from: data)
                .mediaContainer.metadata ?? []
        } catch {
            // The worst place of all to swallow this: a sync reads through here, and a silent
            // decoding failure would look like a library with nothing in it — which `finishSync`
            // would then take as permission to delete every row it had.
            throw ProviderError.malformedResponse(
                details: "/library/sections/\(config.sectionKey)/all: \(error)"
            )
        }
    }

    private func metadata(_ id: MediaID) async throws -> PlexMetadata {
        let container = try await get("/library/metadata/\(id.rawValue)", query: [])
        guard let row = container.mediaContainer.metadata?.first else {
            throw ProviderError.serverError(
                code: 404,
                message: "Plex has no item \(id.rawValue) in \(config.sectionTitle) (key \(config.sectionKey)). The id may be stale — from before a rescan.",
                helpURL: nil
            )
        }
        return row
    }

    private func children(of id: MediaID) async throws -> [PlexMetadata] {
        let container = try await get("/library/metadata/\(id.rawValue)/children", query: [])
        return container.mediaContainer.metadata ?? []
    }

    private func playlistItems(_ id: MediaID) async throws -> [PlexMetadata] {
        let container = try await get("/playlists/\(id.rawValue)/items", query: [])
        return container.mediaContainer.metadata ?? []
    }

    /// One page of a playlist's songs, with the playlist's true length.
    private func playlistItems(
        _ id: MediaID,
        offset: Int,
        limit: Int
    ) async throws -> (rows: [PlexMetadata], total: Int?) {
        var request = URLRequest(url: url(path: "/playlists/\(id.rawValue)/items", query: []))
        // Plex pages with headers rather than query parameters.
        request.setValue(String(offset), forHTTPHeaderField: "X-Plex-Container-Start")
        request.setValue(String(limit), forHTTPHeaderField: "X-Plex-Container-Size")
        let (data, response) = try await transport.perform(authenticated(request))
        try PlexClient.check(response, data: data)
        do {
            let container = try PlexClient.decoder
                .decode(PlexLibraryResponse.self, from: data).mediaContainer
            return (container.metadata ?? [], container.totalSize)
        } catch {
            throw ProviderError.malformedResponse(
                details: "/playlists/\(id.rawValue)/items: \(error)"
            )
        }
    }

    private func playlist(from row: PlexMetadata) -> Playlist? {
        guard let id = PlexMapper.mediaID(row.ratingKey, server: serverID) else { return nil }
        return Playlist(
            id: id,
            name: row.title ?? "Playlist",
            trackCount: row.leafCount,
            duration: PlexMapper.duration(fromMilliseconds: row.duration),
            artwork: PlexMapper.artwork(row.composite ?? row.thumb, server: serverID),
            isSmart: row.smart?.wrappedValue ?? false
        )
    }

    /// Plex identifies items to add by a `library://` URI naming the server
    /// and the metadata keys.
    private func libraryURI(for ids: [MediaID]) -> String {
        let keys = ids.map(\.rawValue).joined(separator: ",")
        return "server://\(config.machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(keys)"
    }

    /// Maps the app's album orderings onto Plex's sort keys.
    private static func sortAndFilter(for filter: AlbumFilter) -> [URLQueryItem] {
        switch filter {
        case .alphabeticalByName:
            return [URLQueryItem(name: "sort", value: "titleSort")]
        case .alphabeticalByArtist:
            return [URLQueryItem(name: "sort", value: "artist.titleSort,titleSort")]
        case .recentlyAdded:
            return [URLQueryItem(name: "sort", value: "addedAt:desc")]
        case .recentlyReleased:
            // Plex's own field for this, distinct from addedAt: when the
            // record came out rather than when the library first saw it.
            return [URLQueryItem(name: "sort", value: "originallyAvailableAt:desc")]
        case .recentlyPlayed:
            return [URLQueryItem(name: "sort", value: "lastViewedAt:desc")]
        case .mostPlayed:
            return [URLQueryItem(name: "sort", value: "viewCount:desc")]
        case .highestRated:
            return [URLQueryItem(name: "sort", value: "userRating:desc")]
        case .random, .rediscover:
            // Plex has no "left alone for a while" sort either; the shelf
            // that wants one reads it from the index.
            return [URLQueryItem(name: "sort", value: "random")]
        case .favorites:
            // No favourites in Plex; the best equivalent is a top rating.
            return [
                URLQueryItem(name: "sort", value: "userRating:desc"),
                URLQueryItem(name: "userRating>", value: "8"),
            ]
        case .genre(let name):
            return [
                URLQueryItem(name: "sort", value: "titleSort"),
                URLQueryItem(name: "genre", value: name),
            ]
        case .yearRange(let from, let to):
            return [
                URLQueryItem(name: "sort", value: "year"),
                URLQueryItem(name: "year>>", value: String(from - 1)),
                URLQueryItem(name: "year<<", value: String(to + 1)),
            ]
        }
    }
}

/// The library response, which carries more than the section listing does.
struct PlexLibraryResponse: Decodable {
    let mediaContainer: Container

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let version: String?
        let metadata: [PlexMetadata]?
        let directory: [Directory]?

        enum CodingKeys: String, CodingKey {
            case size, totalSize, version
            case metadata = "Metadata"
            case directory = "Directory"
        }

        init(
            size: Int?,
            totalSize: Int?,
            version: String?,
            metadata: [PlexMetadata]?,
            directory: [Directory]?
        ) {
            self.size = size
            self.totalSize = totalSize
            self.version = version
            self.metadata = metadata
            self.directory = directory
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            size = try container.decodeIfPresent(Int.self, forKey: .size)
            totalSize = try container.decodeIfPresent(Int.self, forKey: .totalSize)
            version = try container.decodeIfPresent(String.self, forKey: .version)
            directory = try container.decodeIfPresent([Directory].self, forKey: .directory)
            // Row by row, keeping what reads: one album with a field in an unexpected shape costs
            // that album, not the page it arrived in.
            let rows = try container.decodeIfPresent([FailableRow].self, forKey: .metadata)
            metadata = rows?.compactMap(\.value)
        }
    }

    /// One row that is allowed to fail on its own.
    private struct FailableRow: Decodable {
        let value: PlexMetadata?

        init(from decoder: any Decoder) throws {
            value = try? PlexMetadata(from: decoder)
        }
    }

    struct Directory: Decodable {
        let title: String?
        let key: String?
    }

    static let empty = PlexLibraryResponse(
        mediaContainer: Container(size: 0, totalSize: 0, version: nil, metadata: nil, directory: nil)
    )
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// `/library/sections`, read for one thing only: how this library says it last changed.
struct PlexSectionStampResponse: Decodable {
    let mediaContainer: Container

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }

    struct Container: Decodable {
        let directory: [Section]?

        enum CodingKeys: String, CodingKey {
            case directory = "Directory"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rows = try container.decodeIfPresent([FailableSection].self, forKey: .directory)
            directory = rows?.compactMap(\.value)
        }
    }

    private struct FailableSection: Decodable {
        let value: Section?

        init(from decoder: any Decoder) throws {
            value = try? Section(from: decoder)
        }
    }

    struct Section: Decodable {
        let key: String?
        /// Read as text whatever it arrives as. Plex sends a number today;
        /// what matters is that two reads of an unchanged library produce
        /// the same characters, not what the characters mean.
        let contentChangedAt: String?

        enum CodingKeys: String, CodingKey {
            case key, contentChangedAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try? container.decodeIfPresent(String.self, forKey: .key)
            if let number = try? container.decodeIfPresent(Int.self, forKey: .contentChangedAt) {
                contentChangedAt = String(number)
            } else {
                contentChangedAt = try? container.decodeIfPresent(String.self, forKey: .contentChangedAt)
            }
        }
    }
}
