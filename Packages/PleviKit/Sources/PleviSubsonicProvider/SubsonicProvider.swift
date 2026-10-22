import Foundation
import Synchronization
import PleviDomain
import PleviTransport

/// `MusicServerProvider` for Navidrome and other OpenSubsonic servers.
public final class SubsonicProvider: MusicServerProvider, Sendable {
    public let serverID: ServerID
    private let client: SubsonicClient
    private let capabilitiesStorage: Mutex<ServerCapabilities>

    /// What every Subsonic server supports without probing.
    public static let baseCapabilities: ServerCapabilities = [
        .favorites, .ratings, .playlists, .playlistReorder, .similarItems,
        .topTracks, .artistInfo, .albumInfo, .randomBrowse, .scrobbling,
        .genreBrowsing, .transcodeSelection,
    ]

    /// Extension-dependent flags are added after `testConnection` probes the
    /// server; call it before trusting the exact set.
    public var capabilities: ServerCapabilities {
        capabilitiesStorage.withLock { $0 }
    }

    public init(serverID: ServerID, client: SubsonicClient) {
        self.serverID = serverID
        self.client = client
        self.capabilitiesStorage = Mutex(Self.baseCapabilities)
    }

    /// Composition helper: build the full stack for one configured server.
    /// `customHeaders` values come from the Keychain at call time — they are
    /// applied to every API and media request.
    public convenience init(
        config: ServerConfig,
        credentials: SubsonicCredentials,
        customHeaders: [String: String] = [:],
        transport: (any HTTPTransport)? = nil,
        onAuthOutcome: (@Sendable (SubsonicClient.AuthOutcome) -> Void)? = nil
    ) {
        let client = SubsonicClient(
            // Provisional; `EndpointSelector` supplies the reachable address
            // via `setBaseURL` as soon as it has probed.
            baseURL: config.addresses.preferred,
            credentials: credentials,
            transport: transport ?? ServerHTTPTransport(config: config),
            customHeaders: customHeaders,
            onAuthOutcome: onAuthOutcome
        )
        self.init(serverID: config.id, client: client)
    }

    /// Point requests at the currently reachable base URL.
    public func setBaseURL(_ url: URL) async {
        await client.setBaseURL(url)
    }

    // MARK: Connection

    public func testConnection() async throws -> ServerInfo {
        let extensions = await client.serverExtensions(retryingInconclusive: true)
        let payload = try await client.call("ping")

        var caps = Self.baseCapabilities
        if extensions.contains("songLyrics") { caps.insert(.syncedLyrics) }
        if extensions.contains("transcodeOffset") { caps.insert(.transcodeOffset) }
        capabilitiesStorage.withLock { $0 = caps }

        return ServerInfo(
            productName: payload.type,
            productVersion: payload.serverVersion,
            apiVersion: payload.version,
            isOpenSubsonic: payload.openSubsonic ?? false,
            extensions: extensions
        )
    }

    // MARK: Browsing

    public func artists() async throws -> [Artist] {
        let payload = try await client.call("getArtists")
        let indexes = payload.artists?.index ?? []
        return indexes.flatMap { $0.artist ?? [] }.map { $0.domain(server: serverID) }
    }

    public func artist(id: MediaID) async throws -> ArtistDetail {
        let payload = try await client.call("getArtist", [item("id", raw(id))])
        guard let dto = payload.artist else {
            throw ProviderError.malformedResponse(details: "getArtist returned no artist")
        }
        return ArtistDetail(
            artist: dto.domainArtist(server: serverID),
            albums: (dto.album ?? []).map { $0.domain(server: serverID) }
        )
    }

    public func artistInfo(id: MediaID) async throws -> ArtistInfo {
        let payload = try await client.call("getArtistInfo2", [item("id", raw(id))])
        guard let dto = payload.artistInfo2 else {
            throw ProviderError.malformedResponse(details: "getArtistInfo2 returned no info")
        }
        let biography = dto.biography.flatMap { $0.isEmpty ? nil : $0 }
        return ArtistInfo(
            biography: biography,
            similarArtists: (dto.similarArtist ?? []).map { $0.domain(server: serverID) }
        )
    }

    public func albumInfo(id: MediaID) async throws -> AlbumInfo {
        let payload = try await client.call("getAlbumInfo2", [item("id", raw(id))])
        guard let dto = payload.albumInfo else {
            throw ProviderError.malformedResponse(details: "getAlbumInfo2 returned no info")
        }
        let notes = dto.notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return AlbumInfo(notes: notes, musicBrainzID: dto.musicBrainzId)
    }

    public func albums(filter: AlbumFilter, offset: Int, limit: Int) async throws -> [Album] {
        var params = [
            item("size", String(max(1, min(limit, 500)))),
            item("offset", String(max(0, offset))),
        ]
        switch filter {
        case .recentlyAdded, .recentlyReleased:
            // Subsonic has no "by release date" list type — "newest" means newest to the server,
            // the same thing `recentlyAdded` already asks for.
            params.append(item("type", "newest"))
        case .recentlyPlayed:
            params.append(item("type", "recent"))
        case .mostPlayed:
            params.append(item("type", "frequent"))
        case .highestRated:
            params.append(item("type", "highest"))
        case .random, .rediscover:
            // Subsonic has no notion of "left alone for a while", so it
            // offers the nearest thing it has. The shelf that wants the
            // other reads it from the index instead.
            params.append(item("type", "random"))
        case .favorites:
            params.append(item("type", "starred"))
        case .alphabeticalByName:
            params.append(item("type", "alphabeticalByName"))
        case .alphabeticalByArtist:
            params.append(item("type", "alphabeticalByArtist"))
        case .genre(let genre):
            params.append(item("type", "byGenre"))
            params.append(item("genre", genre))
        case .yearRange(let from, let to):
            params.append(item("type", "byYear"))
            params.append(item("fromYear", String(from)))
            params.append(item("toYear", String(to)))
        }
        let payload = try await client.call("getAlbumList2", params)
        return (payload.albumList2?.album ?? []).map { $0.domain(server: serverID) }
    }

    public func album(id: MediaID) async throws -> AlbumDetail {
        let payload = try await client.call("getAlbum", [item("id", raw(id))])
        guard let dto = payload.album else {
            throw ProviderError.malformedResponse(details: "getAlbum returned no album")
        }
        let tracks = (dto.song ?? [])
            .map { $0.domain(server: serverID) }
            .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
        return AlbumDetail(album: dto.domainAlbum(server: serverID), tracks: tracks)
    }

    public func track(id: MediaID) async throws -> Track {
        let payload = try await client.call("getSong", [item("id", raw(id))])
        guard let dto = payload.song else {
            throw ProviderError.malformedResponse(details: "getSong returned no song")
        }
        return dto.domain(server: serverID)
    }

    public func genres() async throws -> [Genre] {
        let payload = try await client.call("getGenres")
        return (payload.genres?.genre ?? [])
            .map { Genre(name: $0.value, trackCount: $0.songCount, albumCount: $0.albumCount) }
            .sorted { $0.name < $1.name }
    }

    public func search(_ query: String, limit: Int, offset: Int) async throws -> SearchResults {
        let count = String(max(1, min(limit, 500)))
        let offsetValue = String(max(0, offset))
        let payload = try await client.call("search3", [
            item("query", query),
            item("artistCount", count),
            item("artistOffset", offsetValue),
            item("albumCount", count),
            item("albumOffset", offsetValue),
            item("songCount", count),
            item("songOffset", offsetValue),
        ])
        let result = payload.searchResult3
        return SearchResults(
            artists: (result?.artist ?? []).map { $0.domain(server: serverID) },
            albums: (result?.album ?? []).map { $0.domain(server: serverID) },
            tracks: (result?.song ?? []).map { $0.domain(server: serverID) }
        )
    }

    /// One page of songs, asking for nothing else.
    public func tracks(offset: Int, limit: Int) async throws -> [Track] {
        let payload = try await client.call("search3", [
            item("query", ""),
            item("artistCount", "0"),
            item("albumCount", "0"),
            item("songCount", String(max(1, min(limit, 500)))),
            item("songOffset", String(max(0, offset))),
        ])
        return (payload.searchResult3?.song ?? []).map { $0.domain(server: serverID) }
    }

    /// How many songs the server says it has, from `getScanStatus`.
    public func libraryCounts() async throws -> LibraryCounts {
        guard let status = await scanStatus() else { return LibraryCounts() }
        // `scanning` is the one field the Subsonic spec actually promises, and the one worth acting
        // on: a Navidrome rebuilding its database answers `count` with what it has so far, climbing
        // towards the truth.
        return LibraryCounts(tracks: status.count, isRescanning: status.scanning == true)
    }

    /// The last scan's own timestamp, as the server wrote it.
    public func libraryChangeToken() async throws -> String? {
        guard let status = await scanStatus(), status.scanning != true else { return nil }
        guard let scan = status.lastScan, !scan.isEmpty else { return nil }
        return "subsonic:\(scan)"
    }

    /// Best effort: this endpoint is optional in the spec, extended by Navidrome, ignored by gonic
    /// and administrator-only on some servers.
    private func scanStatus() async -> ScanStatusDTO? {
        try? await client.call("getScanStatus").scanStatus
    }

    public func randomTracks(limit: Int) async throws -> [Track] {
        let payload = try await client.call("getRandomSongs", [item("size", String(max(1, min(limit, 500))))])
        return (payload.randomSongs?.song ?? []).map { $0.domain(server: serverID) }
    }

    public func similarTracks(to id: MediaID, limit: Int) async throws -> [Track] {
        let payload = try await client.call("getSimilarSongs2", [
            item("id", raw(id)),
            item("count", String(max(1, limit))),
        ])
        return (payload.similarSongs2?.song ?? []).map { $0.domain(server: serverID) }
    }

    public func topTracks(forArtist id: MediaID, limit: Int) async throws -> [Track] {
        // getTopSongs is name-keyed; resolve the name first so this works
        // without the topSongsByArtistId extension.
        let detail = try await artist(id: id)
        let payload = try await client.call("getTopSongs", [
            item("artist", detail.artist.name),
            item("count", String(max(1, limit))),
        ])
        return (payload.topSongs?.song ?? []).map { $0.domain(server: serverID) }
    }

    // MARK: Playlists

    public func playlists() async throws -> [Playlist] {
        let payload = try await client.call("getPlaylists")
        return (payload.playlists?.playlist ?? []).map { $0.domain(server: serverID) }
    }

    public func playlist(id: MediaID) async throws -> PlaylistDetail {
        let dto = try await fetchPlaylistDTO(id: id)
        return PlaylistDetail(
            playlist: dto.domain(server: serverID),
            entries: entries(from: dto)
        )
    }

    public func createPlaylist(name: String, trackIDs: [MediaID]) async throws -> Playlist {
        var params = [item("name", name)]
        params.append(contentsOf: try trackIDs.map { item("songId", try raw($0)) })
        let payload = try await client.call("createPlaylist", params)
        guard let dto = payload.playlist else {
            throw ProviderError.malformedResponse(details: "createPlaylist returned no playlist")
        }
        return dto.domain(server: serverID)
    }

    public func renamePlaylist(id: MediaID, name: String) async throws {
        _ = try await client.call("updatePlaylist", [
            item("playlistId", raw(id)),
            item("name", name),
        ])
    }

    public func addToPlaylist(id: MediaID, trackIDs: [MediaID]) async throws {
        var params = [item("playlistId", try raw(id))]
        params.append(contentsOf: try trackIDs.map { item("songIdToAdd", try raw($0)) })
        _ = try await client.call("updatePlaylist", params)
    }

    public func removeFromPlaylist(id: MediaID, entries entryIDs: [PlaylistEntryID]) async throws {
        let current = try await fetchPlaylistDTO(id: id).entry ?? []
        var indices: [Int] = []
        for entryID in entryIDs {
            guard let (index, songID) = Self.decodeEntry(entryID.rawValue),
                  index < current.count,
                  current[index].id == songID
            else {
                throw ProviderError.conflict(details: "playlist changed on the server; refresh and retry")
            }
            indices.append(index)
        }
        var params = [item("playlistId", try raw(id))]
        params.append(contentsOf: indices.map { item("songIndexToRemove", String($0)) })
        _ = try await client.call("updatePlaylist", params)
    }

    public func reorderPlaylist(id: MediaID, orderedEntries: [PlaylistEntryID]) async throws {
        let current = try await fetchPlaylistDTO(id: id).entry ?? []
        let currentEncoded = Set(current.enumerated().map { Self.encodeEntry(index: $0.offset, songID: $0.element.id) })
        let requested = orderedEntries.map(\.rawValue)
        guard requested.count == current.count, Set(requested) == currentEncoded else {
            throw ProviderError.conflict(details: "playlist changed on the server; refresh and retry")
        }
        // Subsonic has no move operation; createPlaylist with playlistId
        // replaces the playlist's contents with the given order.
        var params = [item("playlistId", try raw(id))]
        for encoded in requested {
            guard let (_, songID) = Self.decodeEntry(encoded) else {
                throw ProviderError.conflict(details: "unrecognized playlist entry")
            }
            params.append(item("songId", songID))
        }
        _ = try await client.call("createPlaylist", params)
    }

    // MARK: State

    public func setFavorite(_ favorite: Bool, for id: MediaID, kind: MediaKind) async throws {
        let paramName: String
        switch kind {
        case .track:
            paramName = "id"
        case .album:
            paramName = "albumId"
        case .artist:
            paramName = "artistId"
        case .playlist, .genre:
            throw ProviderError.unsupportedOperation(needs: .favorites)
        }
        _ = try await client.call(favorite ? "star" : "unstar", [item(paramName, raw(id))])
    }

    public func setRating(_ rating: StarRating?, for id: MediaID) async throws {
        _ = try await client.call("setRating", [
            item("id", raw(id)),
            item("rating", String(rating?.wholeStars ?? 0)),
        ])
    }

    public func scrobble(id: MediaID, at date: Date, submission: Bool) async throws {
        _ = try await client.call("scrobble", [
            item("id", raw(id)),
            item("time", String(Int64(date.timeIntervalSince1970 * 1000))),
            item("submission", submission ? "true" : "false"),
        ])
    }

    // MARK: Media requests

    public func streamRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
        var params = [item("id", try raw(id))]
        if let codec = options.transcodeTo {
            params.append(item("format", codec.rawValue))
        } else if options.maxBitRateKbps == nil {
            // No transcode requested and no cap: ask for the untouched file
            // even if the server has a default transcoding profile.
            params.append(item("format", "raw"))
        }
        if let cap = options.maxBitRateKbps {
            params.append(item("maxBitRate", String(cap)))
        }
        if let offset = options.startOffset, capabilities.contains(.transcodeOffset) {
            params.append(item("timeOffset", String(Int(offset))))
        }
        if options.estimateContentLength {
            params.append(item("estimateContentLength", "true"))
        }
        return try await client.makeMediaRequest(verb: "stream", params: params)
    }

    public func downloadRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
        if options.transcodeTo == nil, options.maxBitRateKbps == nil {
            // Original file, byte-exact.
            return try await client.makeMediaRequest(verb: "download", params: [item("id", try raw(id))])
        }
        // Transcoded downloads go through stream.
        var params = [item("id", try raw(id))]
        if let codec = options.transcodeTo {
            params.append(item("format", codec.rawValue))
        }
        if let cap = options.maxBitRateKbps {
            params.append(item("maxBitRate", String(cap)))
        }
        return try await client.makeMediaRequest(verb: "stream", params: params)
    }

    public func artworkRequest(for id: ArtworkID, size: Int?) async throws -> URLRequest {
        guard id.server == serverID else { throw ProviderError.notFound }
        var params = [item("id", id.rawValue)]
        if let size {
            params.append(item("size", String(size)))
        }
        return try await client.makeMediaRequest(verb: "getCoverArt", params: params)
    }

    // MARK: Extras

    public func lyrics(for id: MediaID) async throws -> Lyrics? {
        guard capabilities.contains(.syncedLyrics) else { return nil }
        let payload = try await client.call("getLyricsBySongId", [item("id", raw(id))])
        guard let all = payload.lyricsList?.structuredLyrics, !all.isEmpty else { return nil }
        let best = all.first(where: { $0.synced == true }) ?? all[0]
        return Lyrics(
            synced: best.synced ?? false,
            language: best.lang,
            offset: (best.offset ?? 0) / 1000,
            lines: (best.line ?? []).map {
                Lyrics.Line(start: $0.start.map { $0 / 1000 }, text: $0.value)
            }
        )
    }

    // MARK: Helpers

    private func item(_ name: String, _ value: String) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }

    private func raw(_ id: MediaID) throws -> String {
        guard id.server == serverID else { throw ProviderError.notFound }
        return id.rawValue
    }

    private func fetchPlaylistDTO(id: MediaID) async throws -> PlaylistDTO {
        let payload = try await client.call("getPlaylist", [item("id", raw(id))])
        guard let dto = payload.playlist else {
            throw ProviderError.malformedResponse(details: "getPlaylist returned no playlist")
        }
        return dto
    }

    private func entries(from dto: PlaylistDTO) -> [PlaylistEntry] {
        (dto.entry ?? []).enumerated().map { index, child in
            PlaylistEntry(
                entryID: PlaylistEntryID(
                    server: serverID,
                    rawValue: Self.encodeEntry(index: index, songID: child.id)
                ),
                track: child.domain(server: serverID)
            )
        }
    }

    static func encodeEntry(index: Int, songID: String) -> String {
        "\(index)#\(songID)"
    }

    static func decodeEntry(_ rawValue: String) -> (index: Int, songID: String)? {
        guard let separator = rawValue.firstIndex(of: "#"),
              let index = Int(rawValue[..<separator])
        else { return nil }
        return (index, String(rawValue[rawValue.index(after: separator)...]))
    }
}
