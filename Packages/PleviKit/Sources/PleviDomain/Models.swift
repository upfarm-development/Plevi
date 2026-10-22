import Foundation

public struct Artist: Hashable, Sendable, Codable, Identifiable {
    public let id: MediaID
    public var name: String
    public var sortName: String?
    public var albumCount: Int?
    public var artwork: ArtworkID?
    public var isFavorite: Bool
    public var rating: StarRating?
    /// MusicBrainz's own identifier for this artist, when the server knows it — Navidrome sends it
    /// on every artist row it has matched; Plex only when asked with `includeGuids=1`, and only for
    /// a matched artist.
    public var musicBrainzID: String?

    public init(
        id: MediaID,
        name: String,
        sortName: String? = nil,
        albumCount: Int? = nil,
        artwork: ArtworkID? = nil,
        isFavorite: Bool = false,
        rating: StarRating? = nil,
        musicBrainzID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.albumCount = albumCount
        self.artwork = artwork
        self.isFavorite = isFavorite
        self.rating = rating
        self.musicBrainzID = musicBrainzID
    }
}

public struct ArtistDetail: Hashable, Sendable, Codable {
    public var artist: Artist
    public var albums: [Album]

    public init(artist: Artist, albums: [Album]) {
        self.artist = artist
        self.albums = albums
    }
}

/// Extended artist information; gate on `ServerCapabilities.artistInfo`.
public struct ArtistInfo: Hashable, Sendable, Codable {
    public var biography: String?
    public var similarArtists: [Artist]

    public init(biography: String? = nil, similarArtists: [Artist] = []) {
        self.biography = biography
        self.similarArtists = similarArtists
    }
}

/// How a release is categorised.
public enum ReleaseType: String, Hashable, Sendable, Codable, CaseIterable {
    case album
    case single
    case ep
    case compilation
    case live
    case remix
    case soundtrack
    case demo

    public init(matching raw: String) {
        let value = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch value {
        case "single", "singles": self = .single
        case "ep", "eps": self = .ep
        case "compilation", "compilations": self = .compilation
        case "live": self = .live
        case "remix", "remixes": self = .remix
        case "soundtrack", "original soundtrack", "ost": self = .soundtrack
        case "demo", "demos": self = .demo
        default: self = .album
        }
    }

    /// Section heading for a group of these releases.
    /// "Album", "EP" — for naming one record rather than a shelf of them.
    public var singularName: String {
        switch self {
        case .album: "Album"
        case .single: "Single"
        case .ep: "EP"
        case .compilation: "Compilation"
        case .live: "Live"
        case .remix: "Remix"
        case .soundtrack: "Soundtrack"
        case .demo: "Demo"
        }
    }

    public var pluralName: String {
        switch self {
        case .album: "Albums"
        case .single: "Singles"
        case .ep: "EPs"
        case .compilation: "Compilations"
        case .live: "Live"
        case .remix: "Remixes"
        case .soundtrack: "Soundtracks"
        case .demo: "Demos"
        }
    }
}

/// Extended album information; gate on `ServerCapabilities.albumInfo`.
public struct AlbumInfo: Hashable, Sendable, Codable {
    /// Review or description text. Plain prose, may be empty.
    public var notes: String?
    public var musicBrainzID: String?

    public init(notes: String? = nil, musicBrainzID: String? = nil) {
        self.notes = notes
        self.musicBrainzID = musicBrainzID
    }
}

public struct Album: Hashable, Sendable, Codable, Identifiable {
    public let id: MediaID
    public var name: String
    public var artistName: String?
    public var artistID: MediaID?
    public var year: Int?
    public var genre: String?
    public var trackCount: Int?
    public var duration: TimeInterval?
    public var artwork: ArtworkID?
    /// When the album entered the library; drives "recently added".
    public var addedAt: Date?
    /// When the album was last played; drives "recently played".
    public var playedAt: Date?
    public var playCount: Int?
    public var isFavorite: Bool
    public var rating: StarRating?
    /// Normalised release categories; empty means the server said nothing,
    /// in which case the UI treats it as a plain album.
    public var releaseTypes: [ReleaseType]
    public var isCompilation: Bool
    /// The label that put the record out, where the server knows it.
    public var recordLabel: String?
    /// The full release date, when the server has more than a year.
    public var releaseDate: Date?
    /// What a reviewer made of the record, 0–10, where the server keeps such a thing.
    public var criticRating: Double?
    /// The review, where the server carries one on the record itself.
    public var review: String?

    /// The category this album is filed under on an artist page.
    public var primaryReleaseType: ReleaseType {
        if isCompilation { return .compilation }
        if let specific = releaseTypes.first(where: { $0 != .album }) { return specific }
        return releaseTypes.first ?? .album
    }

    /// What to show where a title is required.
    public var displayName: String {
        guard name.trimmingCharacters(in: .whitespaces).isEmpty else { return name }
        return artistName ?? name
    }

    public init(
        id: MediaID,
        name: String,
        artistName: String? = nil,
        artistID: MediaID? = nil,
        year: Int? = nil,
        genre: String? = nil,
        trackCount: Int? = nil,
        duration: TimeInterval? = nil,
        artwork: ArtworkID? = nil,
        addedAt: Date? = nil,
        playedAt: Date? = nil,
        playCount: Int? = nil,
        isFavorite: Bool = false,
        rating: StarRating? = nil,
        releaseTypes: [ReleaseType] = [],
        isCompilation: Bool = false,
        recordLabel: String? = nil,
        releaseDate: Date? = nil,
        criticRating: Double? = nil,
        review: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.artistID = artistID
        self.year = year
        self.genre = genre
        self.trackCount = trackCount
        self.duration = duration
        self.artwork = artwork
        self.addedAt = addedAt
        self.playedAt = playedAt
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.rating = rating
        self.releaseTypes = releaseTypes
        self.isCompilation = isCompilation
        self.recordLabel = recordLabel
        self.releaseDate = releaseDate
        self.criticRating = criticRating
        self.review = review
    }
}

public struct AlbumDetail: Hashable, Sendable, Codable {
    public var album: Album
    /// Ordered by disc number, then track number.
    public var tracks: [Track]

    public init(album: Album, tracks: [Track]) {
        self.album = album
        self.tracks = tracks
    }
}

/// ReplayGain values as read from server metadata or file tags.
/// Gains are in decibels; peaks are linear sample peaks (1.0 = full scale).
public struct ReplayGain: Hashable, Sendable, Codable {
    public var trackGain: Double?
    public var albumGain: Double?
    public var trackPeak: Double?
    public var albumPeak: Double?

    public init(
        trackGain: Double? = nil,
        albumGain: Double? = nil,
        trackPeak: Double? = nil,
        albumPeak: Double? = nil
    ) {
        self.trackGain = trackGain
        self.albumGain = albumGain
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }
}

public struct Track: Hashable, Sendable, Codable, Identifiable {
    /// Settable only inside this module, for `rekeyed(to:)`.
    public internal(set) var id: MediaID
    public var title: String
    public var albumName: String?
    public var albumID: MediaID?
    public var artistName: String?
    public var artistID: MediaID?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval?
    public var year: Int?
    /// When the song was originally made, where the server tags songs individually — Navidrome can
    /// surface `ORIGINALDATE`/`ORIGINALYEAR`, and Plex sends `originallyAvailableAt` on some track
    /// rows.
    public var originalYear: Int?
    public var genre: String?
    /// Source codec as reported by the server (e.g. "flac", "mp3", "opus").
    /// The audio engine uses this to decide between native decode and
    /// requesting a server-side transcode.
    public var codec: String?
    public var contentType: String?
    public var bitRateKbps: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channelCount: Int?
    /// Beats per minute, where the server knows it.
    public var bpm: Int?
    public var fileSize: Int64?
    public var artwork: ArtworkID?
    public var replayGain: ReplayGain?
    public var isFavorite: Bool
    public var rating: StarRating?
    public var playCount: Int?
    /// When this song was last played. Servers know it and it is the thing a
    /// shuffle most wants: the strongest sign a song is due a hearing is how
    /// long since the last one. `nil` means never played.
    public var playedAt: Date?
    /// The audience's own popularity figure for this song — Plex's `ratingCount`, how many of its
    /// users have played or rated it, not what this listener has.
    public var popularity: Int?

    public init(
        id: MediaID,
        title: String,
        albumName: String? = nil,
        albumID: MediaID? = nil,
        artistName: String? = nil,
        artistID: MediaID? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval? = nil,
        year: Int? = nil,
        originalYear: Int? = nil,
        genre: String? = nil,
        codec: String? = nil,
        contentType: String? = nil,
        bitRateKbps: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil,
        bpm: Int? = nil,
        fileSize: Int64? = nil,
        artwork: ArtworkID? = nil,
        replayGain: ReplayGain? = nil,
        isFavorite: Bool = false,
        rating: StarRating? = nil,
        playCount: Int? = nil,
        playedAt: Date? = nil,
        popularity: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.albumName = albumName
        self.albumID = albumID
        self.artistName = artistName
        self.artistID = artistID
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.year = year
        self.originalYear = originalYear
        self.genre = genre
        self.codec = codec
        self.contentType = contentType
        self.bitRateKbps = bitRateKbps
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.bpm = bpm
        self.fileSize = fileSize
        self.artwork = artwork
        self.replayGain = replayGain
        self.isFavorite = isFavorite
        self.rating = rating
        self.playCount = playCount
        self.playedAt = playedAt
        self.popularity = popularity
    }
    /// What to show when a song has no title.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

}

public struct Genre: Hashable, Sendable, Codable, Identifiable {
    /// The server's own id for the tag, where it keeps one. Plex does, and
    /// filtering by it is more reliable than filtering by the name — the
    /// name is still the identity as far as the app is concerned.
    public var serverKey: String?

    /// Genres have no server-side ID; the name is the identity.
    public var id: String { name }
    public var name: String
    public var trackCount: Int?
    public var albumCount: Int?
    /// How many artists have music filed under it. Only counted when a
    /// genre is being listed for browsing artists.
    public var artistCount: Int?

    public init(
        name: String,
        trackCount: Int? = nil,
        albumCount: Int? = nil,
        artistCount: Int? = nil,
        serverKey: String? = nil
    ) {
        self.name = name
        self.serverKey = serverKey
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.artistCount = artistCount
    }
}

public struct SearchResults: Hashable, Sendable, Codable {
    public var artists: [Artist]
    public var albums: [Album]
    public var tracks: [Track]
    /// Filled in by the app from its own playlist list rather than by either search path — Plex and
    /// Subsonic have no playlist search endpoint, and the local index does not sync playlists into
    /// its full-text table.
    public var playlists: [Playlist]

    public init(
        artists: [Artist] = [],
        albums: [Album] = [],
        tracks: [Track] = [],
        playlists: [Playlist] = []
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
    }

    public var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && tracks.isEmpty && playlists.isEmpty
    }
}

public struct Lyrics: Hashable, Sendable, Codable {
    public struct Line: Hashable, Sendable, Codable {
        /// Offset from the start of the track; nil for unsynced lyrics.
        public var start: TimeInterval?
        public var text: String

        public init(start: TimeInterval? = nil, text: String) {
            self.start = start
            self.text = text
        }
    }

    public var synced: Bool
    public var language: String?
    /// Global timing offset to apply to all line start times.
    public var offset: TimeInterval
    public var lines: [Line]

    public init(synced: Bool, language: String? = nil, offset: TimeInterval = 0, lines: [Line]) {
        self.synced = synced
        self.language = language
        self.offset = offset
        self.lines = lines
    }
}

/// Result of a successful connection test.
public struct ServerInfo: Hashable, Sendable, Codable {
    public var productName: String?
    public var productVersion: String?
    public var apiVersion: String?
    public var isOpenSubsonic: Bool
    /// Extension names as advertised by the server (provider-specific strings).
    public var extensions: Set<String>

    public init(
        productName: String? = nil,
        productVersion: String? = nil,
        apiVersion: String? = nil,
        isOpenSubsonic: Bool = false,
        extensions: Set<String> = []
    ) {
        self.productName = productName
        self.productVersion = productVersion
        self.apiVersion = apiVersion
        self.isOpenSubsonic = isOpenSubsonic
        self.extensions = extensions
    }
}

public extension Track {
    /// The same song under another library's key.
    func rekeyed(to server: ServerID) -> Track {
        guard id.server != server else { return self }
        var copy = self
        copy.id = MediaID(server: server, rawValue: id.rawValue)
        return copy
    }
}
