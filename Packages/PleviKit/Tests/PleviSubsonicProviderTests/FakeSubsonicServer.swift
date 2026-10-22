import Foundation
import CryptoKit
import PleviTransport

/// In-memory OpenSubsonic server implementing the endpoints the provider uses, with real auth
/// validation (salted token / API key), the formPost extension, and stateful
/// playlists/favorites/ratings.
actor FakeSubsonicServer: HTTPTransport {
    let username = "demo"
    let password = "sesame"
    let validAPIKey = "key-123"

    private(set) var requests: [URLRequest] = []

    /// Whether this server says it is part way through a scan of its own.
    /// Settable, because what a client does with a library that is still
    /// arriving is the whole reason the field is read.
    var scanning = false

    func setScanning(_ value: Bool) { scanning = value }

    /// Matches one seeded artist to a MusicBrainz id, the way a real Navidrome would after its own
    /// metadata scan finds one — most seeded artists have none, the same as a real library where
    /// only some artists get matched.
    func setMusicBrainzID(_ musicBrainzId: String?, forArtist artistID: String) {
        artists[artistID]?.musicBrainzId = musicBrainzId
    }

    struct SongRecord {
        let id: String
        let title: String
        let albumID: String
        let albumName: String
        let artistID: String
        let artistName: String
        let track: Int
        let disc: Int
        let year: Int
        let genre: String
        let suffix: String
        let duration: Int
        var starred: String?
        var userRating: Int?
        var playCount: Int
    }

    struct AlbumRecord {
        let id: String
        let name: String
        let artistID: String
        let artistName: String
        let year: Int
        let genre: String
        let created: String
        var starred: String?
        var userRating: Int?
        var songIDs: [String]
        var releaseTypes: [String] = ["Album"]
    }

    struct ArtistRecord {
        let id: String
        let name: String
        var starred: String?
        var userRating: Int?
        var albumIDs: [String]
        var musicBrainzId: String? = nil
    }

    struct PlaylistRecord {
        let id: String
        var name: String
        var comment: String?
        var songIDs: [String]
    }

    private var songs: [String: SongRecord] = [:]
    private var albums: [String: AlbumRecord] = [:]
    private var artists: [String: ArtistRecord] = [:]
    private var playlists: [PlaylistRecord] = []
    private var playlistCounter = 0

    init() {
        let seed = Self.makeSeed()
        songs = seed.songs
        albums = seed.albums
        artists = seed.artists
        playlists = seed.playlists
        playlistCounter = seed.counter
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    // MARK: HTTPTransport

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else {
            return respond(error: (0, "no URL"), to: request)
        }
        let verb = url.lastPathComponent
        let params = Self.parameters(of: request)

        if verb == "getOpenSubsonicExtensions" {
            return respond(payload: ["openSubsonicExtensions": [
                ["name": "formPost", "versions": [1]],
                ["name": "songLyrics", "versions": [1]],
                ["name": "transcodeOffset", "versions": [1]],
                ["name": "apiKeyAuthentication", "versions": [1]],
            ]], to: request)
        }

        if let authError = authFailure(params) {
            return respond(error: authError, to: request)
        }

        do {
            let payload = try route(verb: verb, params: params)
            return respond(payload: payload, to: request)
        } catch let failure as FakeFailure {
            return respond(error: (failure.code, failure.message), to: request)
        }
    }

    private struct FakeFailure: Error {
        let code: Int
        let message: String
    }

    // MARK: Auth

    private func authFailure(_ params: [String: [String]]) -> (Int, String)? {
        if params["p"] != nil {
            return (0, "plaintext password auth is forbidden in tests")
        }
        if let apiKey = params["apiKey"]?.first {
            if params["u"] != nil {
                return (43, "Multiple conflicting authentication mechanisms provided")
            }
            return apiKey == validAPIKey ? nil : (44, "Invalid API key")
        }
        guard let u = params["u"]?.first,
              let t = params["t"]?.first,
              let s = params["s"]?.first
        else {
            return (10, "Required parameter is missing")
        }
        let expected = Insecure.MD5.hash(data: Data((password + s).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard u == username, t == expected else {
            return (40, "Wrong username or password")
        }
        return nil
    }

    /// What this server says its last scan was. Fixed, because the whole
    /// point of the value is that it does not move unless the library does.
    static let lastScan = "2026-09-04T09:15:00.123456789Z"

    // MARK: Routing

    private func route(verb: String, params: [String: [String]]) throws -> [String: Any] {
        switch verb {
        case "ping":
            return [:]

        // Navidrome's shape: the spec promises `scanning` alone and this is
        // what the two useful fields look like when a server does offer them.
        case "getScanStatus":
            return ["scanStatus": [
                "scanning": scanning,
                "count": songs.count,
                "folderCount": albums.count,
                "lastScan": Self.lastScan,
            ] as [String: Any]]

        case "getArtists":
            let sorted = artists.values.sorted { $0.name < $1.name }
            let grouped = Dictionary(grouping: sorted) { String($0.name.prefix(1)).uppercased() }
            let index = grouped.keys.sorted().map { letter in
                [
                    "name": letter,
                    "artist": grouped[letter]!.map { artistJSON($0) },
                ] as [String: Any]
            }
            return ["artists": ["ignoredArticles": "The El La", "index": index]]

        case "getArtist":
            let artist = try artistRecord(params)
            var json = artistJSON(artist)
            json["album"] = artist.albumIDs.compactMap { albums[$0] }.map { albumJSON($0) }
            return ["artist": json]

        case "getAlbumInfo2":
            guard let id = params["id"]?.first, let album = albums[id] else {
                throw FakeFailure(code: 70, message: "Album not found")
            }
            return ["albumInfo": [
                "notes": "\(album.name) was recorded entirely inside a unit test.",
                "musicBrainzId": "mbid-\(album.id)",
            ]]

        case "getArtistInfo2":
            let artist = try artistRecord(params)
            let similar = artists.values.filter { $0.id != artist.id }.sorted { $0.name < $1.name }
            return ["artistInfo2": [
                "biography": "\(artist.name) exists only inside a fixture.",
                "similarArtist": similar.map { artistJSON($0) },
            ]]

        case "getAlbum":
            guard let id = params["id"]?.first, let album = albums[id] else {
                throw FakeFailure(code: 70, message: "Album not found")
            }
            var json = albumJSON(album)
            json["song"] = album.songIDs.compactMap { songs[$0] }.map { songJSON($0) }
            return ["album": json]

        case "getAlbumList2":
            var list = albums.values.sorted { $0.name < $1.name }
            switch params["type"]?.first {
            case "newest":
                list.sort { $0.created > $1.created }
            case "starred":
                list = list.filter { $0.starred != nil }
            case "byGenre":
                let genre = params["genre"]?.first ?? ""
                list = list.filter { $0.genre.caseInsensitiveCompare(genre) == .orderedSame }
            default:
                break
            }
            let offset = params["offset"]?.first.flatMap(Int.init) ?? 0
            let size = params["size"]?.first.flatMap(Int.init) ?? 10
            let page = offset < list.count
                ? Array(list[offset..<min(offset + size, list.count)])
                : []
            return ["albumList2": ["album": page.map { albumJSON($0) }]]

        case "getSong":
            let song = try songRecord(params)
            return ["song": songJSON(song)]

        case "getGenres":
            let byGenre = Dictionary(grouping: songs.values) { $0.genre }
            return ["genres": ["genre": byGenre.keys.sorted().map { name in
                [
                    "value": name,
                    "songCount": byGenre[name]!.count,
                    "albumCount": Set(byGenre[name]!.map(\.albumID)).count,
                ] as [String: Any]
            }]]

        case "search3":
            let query = (params["query"]?.first ?? "").lowercased()
            func matches(_ text: String) -> Bool {
                query.isEmpty || text.lowercased().contains(query)
            }
            let artistHits = artists.values.filter { matches($0.name) }.sorted { $0.name < $1.name }
            let albumHits = albums.values.filter { matches($0.name) }.sorted { $0.name < $1.name }
            let songHits = songs.values.filter { matches($0.title) }.sorted { $0.title < $1.title }
            func slice<T>(_ items: [T], _ offset: Int, _ count: Int) -> [T] {
                guard offset < items.count else { return [] }
                return Array(items[offset..<min(offset + count, items.count)])
            }
            let artistCount = params["artistCount"]?.first.flatMap(Int.init) ?? 20
            let albumCount = params["albumCount"]?.first.flatMap(Int.init) ?? 20
            let songCount = params["songCount"]?.first.flatMap(Int.init) ?? 20
            let artistOffset = params["artistOffset"]?.first.flatMap(Int.init) ?? 0
            let albumOffset = params["albumOffset"]?.first.flatMap(Int.init) ?? 0
            let songOffset = params["songOffset"]?.first.flatMap(Int.init) ?? 0
            return ["searchResult3": [
                "artist": slice(artistHits, artistOffset, artistCount).map { artistJSON($0) },
                "album": slice(albumHits, albumOffset, albumCount).map { albumJSON($0) },
                "song": slice(songHits, songOffset, songCount).map { songJSON($0) },
            ]]

        case "getRandomSongs":
            let size = params["size"]?.first.flatMap(Int.init) ?? 10
            return ["randomSongs": ["song": songs.values.shuffled().prefix(size).map { songJSON($0) }]]

        case "getSimilarSongs2":
            let song = try songRecord(params)
            let similar = songs.values
                .filter { $0.id != song.id && $0.genre == song.genre }
                .sorted { $0.title < $1.title }
            return ["similarSongs2": ["song": similar.map { songJSON($0) }]]

        case "getTopSongs":
            let name = params["artist"]?.first ?? ""
            let count = params["count"]?.first.flatMap(Int.init) ?? 50
            let top = songs.values
                .filter { $0.artistName == name }
                .sorted { $0.playCount > $1.playCount }
            return ["topSongs": ["song": top.prefix(count).map { songJSON($0) }]]

        case "getPlaylists":
            return ["playlists": ["playlist": playlists.map { playlistJSON($0, includeEntries: false) }]]

        case "getPlaylist":
            let playlist = try playlistRecord(params, key: "id")
            return ["playlist": playlistJSON(playlist, includeEntries: true)]

        case "createPlaylist":
            let songIDs = params["songId"] ?? []
            for songID in songIDs where songs[songID] == nil {
                throw FakeFailure(code: 70, message: "Song not found")
            }
            if let existingID = params["playlistId"]?.first {
                guard let index = playlists.firstIndex(where: { $0.id == existingID }) else {
                    throw FakeFailure(code: 70, message: "Playlist not found")
                }
                playlists[index].songIDs = songIDs
                return ["playlist": playlistJSON(playlists[index], includeEntries: true)]
            }
            guard let name = params["name"]?.first else {
                throw FakeFailure(code: 10, message: "Required parameter name is missing")
            }
            playlistCounter += 1
            let record = PlaylistRecord(id: "pl\(playlistCounter)", name: name, comment: nil, songIDs: songIDs)
            playlists.append(record)
            return ["playlist": playlistJSON(record, includeEntries: true)]

        case "updatePlaylist":
            let playlist = try playlistRecord(params, key: "playlistId")
            let index = playlists.firstIndex { $0.id == playlist.id }!
            if let name = params["name"]?.first {
                playlists[index].name = name
            }
            if let comment = params["comment"]?.first {
                playlists[index].comment = comment
            }
            for songID in params["songIdToAdd"] ?? [] {
                guard songs[songID] != nil else {
                    throw FakeFailure(code: 70, message: "Song not found")
                }
                playlists[index].songIDs.append(songID)
            }
            let removals = (params["songIndexToRemove"] ?? []).compactMap(Int.init).sorted(by: >)
            for position in removals {
                guard position < playlists[index].songIDs.count else {
                    throw FakeFailure(code: 0, message: "Index out of bounds")
                }
                playlists[index].songIDs.remove(at: position)
            }
            return [:]

        case "deletePlaylist":
            guard let id = params["id"]?.first,
                  let index = playlists.firstIndex(where: { $0.id == id })
            else {
                throw FakeFailure(code: 70, message: "Playlist not found")
            }
            playlists.remove(at: index)
            return [:]

        case "star", "unstar":
            let date: String? = verb == "star" ? "2026-08-16T12:00:00Z" : nil
            for id in params["id"] ?? [] {
                guard songs[id] != nil else { throw FakeFailure(code: 70, message: "Not found") }
                songs[id]!.starred = date
            }
            for id in params["albumId"] ?? [] {
                guard albums[id] != nil else { throw FakeFailure(code: 70, message: "Not found") }
                albums[id]!.starred = date
            }
            for id in params["artistId"] ?? [] {
                guard artists[id] != nil else { throw FakeFailure(code: 70, message: "Not found") }
                artists[id]!.starred = date
            }
            return [:]

        case "setRating":
            guard let id = params["id"]?.first,
                  let rating = params["rating"]?.first.flatMap(Int.init)
            else {
                throw FakeFailure(code: 10, message: "Required parameter is missing")
            }
            let value: Int? = rating == 0 ? nil : rating
            if songs[id] != nil {
                songs[id]!.userRating = value
            } else if albums[id] != nil {
                albums[id]!.userRating = value
            } else if artists[id] != nil {
                artists[id]!.userRating = value
            } else {
                throw FakeFailure(code: 70, message: "Not found")
            }
            return [:]

        case "scrobble":
            let song = try songRecord(params)
            if params["submission"]?.first != "false" {
                songs[song.id]!.playCount += 1
            }
            return [:]

        case "getLyricsBySongId":
            let song = try songRecord(params)
            guard song.id == "t1" else {
                return ["lyricsList": [String: Any]()]
            }
            return ["lyricsList": ["structuredLyrics": [[
                "lang": "eng",
                "synced": true,
                "offset": 100.0,
                "line": [
                    ["start": 500.0, "value": "Placeholder dawn"],
                    ["start": 4200.0, "value": "Fixture skies in monochrome"],
                    ["start": 9800.0, "value": "Every sample sings alone"],
                ],
            ]]]]

        default:
            throw FakeFailure(code: 0, message: "Unhandled verb \(verb)")
        }
    }

    // MARK: Record lookup

    private func artistRecord(_ params: [String: [String]]) throws -> ArtistRecord {
        guard let id = params["id"]?.first, let artist = artists[id] else {
            throw FakeFailure(code: 70, message: "Artist not found")
        }
        return artist
    }

    private func songRecord(_ params: [String: [String]]) throws -> SongRecord {
        guard let id = params["id"]?.first, let song = songs[id] else {
            throw FakeFailure(code: 70, message: "Song not found")
        }
        return song
    }

    private func playlistRecord(_ params: [String: [String]], key: String) throws -> PlaylistRecord {
        guard let id = params[key]?.first,
              let playlist = playlists.first(where: { $0.id == id })
        else {
            throw FakeFailure(code: 70, message: "Playlist not found")
        }
        return playlist
    }

    // MARK: JSON building

    private func artistJSON(_ artist: ArtistRecord) -> [String: Any] {
        var json: [String: Any] = [
            "id": artist.id,
            "name": artist.name,
            "coverArt": "ar-\(artist.id)",
            "albumCount": artist.albumIDs.count,
        ]
        if let starred = artist.starred { json["starred"] = starred }
        if let rating = artist.userRating { json["userRating"] = rating }
        if let mbid = artist.musicBrainzId { json["musicBrainzId"] = mbid }
        return json
    }

    private func albumJSON(_ album: AlbumRecord) -> [String: Any] {
        var json: [String: Any] = [
            "id": album.id,
            "name": album.name,
            "artist": album.artistName,
            "artistId": album.artistID,
            "coverArt": "al-\(album.id)",
            "songCount": album.songIDs.count,
            "duration": album.songIDs.compactMap { songs[$0]?.duration }.reduce(0, +),
            "created": album.created,
            "year": album.year,
            "genre": album.genre,
            "releaseTypes": album.releaseTypes,
            "isCompilation": album.releaseTypes.contains("Compilation"),
        ]
        if let starred = album.starred { json["starred"] = starred }
        if let rating = album.userRating { json["userRating"] = rating }
        return json
    }

    private func songJSON(_ song: SongRecord) -> [String: Any] {
        var json: [String: Any] = [
            "id": song.id,
            "title": song.title,
            "album": song.albumName,
            "albumId": song.albumID,
            "artist": song.artistName,
            "artistId": song.artistID,
            "track": song.track,
            "discNumber": song.disc,
            "year": song.year,
            "genre": song.genre,
            "coverArt": "al-\(song.albumID)",
            "suffix": song.suffix,
            "contentType": song.suffix == "opus" ? "audio/ogg" : "audio/flac",
            "duration": song.duration,
            "bitRate": 900,
            "samplingRate": 44100,
            "playCount": song.playCount,
            "size": 1_234_567,
            "replayGain": ["trackGain": -6.5, "albumGain": -6.1, "trackPeak": 0.98],
        ]
        if let starred = song.starred { json["starred"] = starred }
        if let rating = song.userRating { json["userRating"] = rating }
        return json
    }

    private func playlistJSON(_ playlist: PlaylistRecord, includeEntries: Bool) -> [String: Any] {
        var json: [String: Any] = [
            "id": playlist.id,
            "name": playlist.name,
            "owner": username,
            "public": false,
            "songCount": playlist.songIDs.count,
            "duration": playlist.songIDs.compactMap { songs[$0]?.duration }.reduce(0, +),
            "created": "2026-08-01T10:00:00Z",
            "changed": "2026-08-16T10:00:00.123Z",
        ]
        if let comment = playlist.comment { json["comment"] = comment }
        if includeEntries {
            json["entry"] = playlist.songIDs.compactMap { songs[$0] }.map { songJSON($0) }
        }
        return json
    }

    // MARK: Response envelope

    private func respond(payload: [String: Any], to request: URLRequest) -> (Data, HTTPURLResponse) {
        var body: [String: Any] = [
            "status": "ok",
            "version": "1.16.1",
            "type": "PleviFake",
            "serverVersion": "0.0.1",
            "openSubsonic": true,
        ]
        for (key, value) in payload {
            body[key] = value
        }
        return encode(["subsonic-response": body], to: request)
    }

    private func respond(error: (Int, String), to request: URLRequest) -> (Data, HTTPURLResponse) {
        encode(["subsonic-response": [
            "status": "failed",
            "version": "1.16.1",
            "type": "PleviFake",
            "serverVersion": "0.0.1",
            "openSubsonic": true,
            "error": ["code": error.0, "message": error.1],
        ]], to: request)
    }

    private func encode(_ object: [String: Any], to request: URLRequest) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://fake.example")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    // MARK: Request parsing

    static func parameters(of request: URLRequest) -> [String: [String]] {
        var merged: [String: [String]] = [:]
        if let url = request.url,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                merged[item.name, default: []].append(item.value ?? "")
            }
        }
        if request.httpMethod == "POST",
           let body = request.httpBody,
           let text = String(data: body, encoding: .utf8) {
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = parts.first.flatMap({ String($0).removingPercentEncoding }) else { continue }
                let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
                merged[name, default: []].append(value)
            }
        }
        return merged
    }

    // MARK: Seed

    private static func makeSeed() -> (
        songs: [String: SongRecord],
        albums: [String: AlbumRecord],
        artists: [String: ArtistRecord],
        playlists: [PlaylistRecord],
        counter: Int
    ) {
        var songs: [String: SongRecord] = [:]
        var albums: [String: AlbumRecord] = [:]
        var artists: [String: ArtistRecord] = [:]
        var playlists: [PlaylistRecord] = []
        var playlistCounter = 0

        struct SeedAlbum {
            let id: String
            let name: String
            let year: Int
            let genre: String
            let created: String
            let titles: [String]
        }

        let catalog: [(id: String, artist: String, albums: [SeedAlbum])] = [
            ("ar1", "Aurora Skies", [
                SeedAlbum(id: "al1", name: "Daybreak", year: 2019, genre: "Ambient",
                          created: "2026-08-03T10:00:00Z",
                          titles: ["First Light", "Slow Horizon", "Cloud Atlas", "Golden Hour"]),
                SeedAlbum(id: "al2", name: "Nightfall", year: 2022, genre: "Ambient",
                          created: "2026-08-09T10:00:00Z",
                          titles: ["Dusk", "Afterglow", "Polar Low"]),
            ]),
            ("ar2", "The Basement Tapes", [
                SeedAlbum(id: "al3", name: "Reel One", year: 1998, genre: "Rock",
                          created: "2026-08-01T10:00:00Z",
                          titles: ["Tape Hiss", "Four Track Mind", "Analog Heart"]),
            ]),
            ("ar3", "Cobalt Waves", [
                SeedAlbum(id: "al4", name: "Undertow", year: 2021, genre: "Electronic",
                          created: "2026-08-06T10:00:00Z",
                          titles: ["Riptide", "Salt & Signal", "Breakwater", "Deep Channel"]),
            ]),
        ]

        var trackIndex = 0
        for (artistID, artistName, seedAlbums) in catalog {
            var albumIDs: [String] = []
            for seedAlbum in seedAlbums {
                var songIDs: [String] = []
                for (position, title) in seedAlbum.titles.enumerated() {
                    trackIndex += 1
                    let songID = "t\(trackIndex)"
                    songs[songID] = SongRecord(
                        id: songID,
                        title: title,
                        albumID: seedAlbum.id,
                        albumName: seedAlbum.name,
                        artistID: artistID,
                        artistName: artistName,
                        track: position + 1,
                        disc: 1,
                        year: seedAlbum.year,
                        genre: seedAlbum.genre,
                        suffix: position.isMultiple(of: 2) ? "flac" : "opus",
                        duration: 180 + position * 30,
                        starred: nil,
                        userRating: nil,
                        playCount: (trackIndex * 7) % 23
                    )
                    songIDs.append(songID)
                }
                albums[seedAlbum.id] = AlbumRecord(
                    id: seedAlbum.id,
                    name: seedAlbum.name,
                    artistID: artistID,
                    artistName: artistName,
                    year: seedAlbum.year,
                    genre: seedAlbum.genre,
                    created: seedAlbum.created,
                    starred: nil,
                    userRating: nil,
                    songIDs: songIDs
                )
                albumIDs.append(seedAlbum.id)
            }
            artists[artistID] = ArtistRecord(
                id: artistID,
                name: artistName,
                starred: nil,
                userRating: nil,
                albumIDs: albumIDs
            )
        }

        playlistCounter += 1
        playlists.append(PlaylistRecord(
            id: "pl\(playlistCounter)",
            name: "Morning Mix",
            comment: nil,
            songIDs: ["t1", "t2", "t3", "t4"]
        ))

        return (songs, albums, artists, playlists, playlistCounter)
    }
}
