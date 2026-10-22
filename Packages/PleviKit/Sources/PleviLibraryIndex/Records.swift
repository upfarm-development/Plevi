import Foundation
import GRDB
import PleviDomain

// Table rows. IDs are stored as the server-native raw strings; the owning
// `ServerID` is a property of the whole database file (one index per
// server), reattached when rows are mapped back to domain values.

struct ArtistRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "artist"

    var id: String
    var name: String
    var sortName: String?
    var albumCount: Int?
    var artworkId: String?
    var isFavorite: Bool
    var rating: Double?
    var musicBrainzId: String?
    var syncGen: Int

    init(_ artist: Artist, generation: Int) {
        id = artist.id.rawValue
        name = artist.name
        sortName = artist.sortName
        albumCount = artist.albumCount
        artworkId = artist.artwork?.rawValue
        isFavorite = artist.isFavorite
        rating = artist.rating?.value
        musicBrainzId = artist.musicBrainzID
        syncGen = generation
    }

    func domain(server: ServerID) -> Artist {
        Artist(
            id: MediaID(server: server, rawValue: id),
            name: name,
            sortName: sortName,
            albumCount: albumCount,
            artwork: artworkId.map { ArtworkID(server: server, rawValue: $0) },
            isFavorite: isFavorite,
            rating: rating.flatMap(StarRating.init),
            musicBrainzID: musicBrainzId
        )
    }
}

struct AlbumRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "album"

    var id: String
    var name: String
    var artistId: String?
    var artistName: String?
    var year: Int?
    var genre: String?
    var trackCount: Int?
    var duration: Double?
    var artworkId: String?
    var addedAt: Date?
    var playedAt: Date?
    var playCount: Int?
    var isFavorite: Bool
    var rating: Double?
    /// Comma-separated `ReleaseType` raw values; empty when unknown.
    var releaseTypes: String
    var isCompilation: Bool
    /// Whether this reads as a collection of other people's records, rather than whether the server
    /// said so.
    var isCollection: Bool
    var recordLabel: String?
    var releaseDate: Date?
    /// A reviewer's score out of ten, where the server keeps one — Plex
    /// only. See `Album.criticRating`.
    var criticRating: Double?
    /// The review itself, where it rides along with the record.
    var review: String?
    var syncGen: Int

    init(_ album: Album, generation: Int) {
        id = album.id.rawValue
        name = album.name
        artistId = album.artistID?.rawValue
        artistName = album.artistName
        year = album.year
        genre = album.genre
        trackCount = album.trackCount
        duration = album.duration
        artworkId = album.artwork?.rawValue
        addedAt = album.addedAt
        playedAt = album.playedAt
        playCount = album.playCount
        isFavorite = album.isFavorite
        rating = album.rating?.value
        releaseTypes = album.releaseTypes.map(\.rawValue).joined(separator: ",")
        isCompilation = album.isCompilation
        isCollection = CompilationHeuristics.isCompilation(
            serverFlag: album.isCompilation,
            releaseTypes: album.releaseTypes,
            albumTitle: album.name,
            albumArtist: album.artistName
        )
        recordLabel = album.recordLabel
        releaseDate = album.releaseDate
        criticRating = album.criticRating
        review = album.review
        syncGen = generation
    }

    func domain(server: ServerID) -> Album {
        Album(
            id: MediaID(server: server, rawValue: id),
            name: name,
            artistName: artistName,
            artistID: artistId.map { MediaID(server: server, rawValue: $0) },
            year: year,
            genre: genre,
            trackCount: trackCount,
            duration: duration,
            artwork: artworkId.map { ArtworkID(server: server, rawValue: $0) },
            addedAt: addedAt,
            playedAt: playedAt,
            playCount: playCount,
            isFavorite: isFavorite,
            rating: rating.flatMap(StarRating.init),
            releaseTypes: releaseTypes
                .split(separator: ",")
                .compactMap { ReleaseType(rawValue: String($0)) },
            isCompilation: isCompilation,
            recordLabel: recordLabel,
            releaseDate: releaseDate,
            criticRating: criticRating,
            review: review
        )
    }
}

struct TrackRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "track"

    var id: String
    var title: String
    var albumId: String?
    var albumName: String?
    var artistId: String?
    var artistName: String?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double?
    var year: Int?
    var originalYear: Int?
    var genre: String?
    var codec: String?
    var contentType: String?
    var bitRateKbps: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var channelCount: Int?
    var bpm: Int?
    var fileSize: Int64?
    var artworkId: String?
    var rgTrackGain: Double?
    var rgAlbumGain: Double?
    var rgTrackPeak: Double?
    var rgAlbumPeak: Double?
    var isFavorite: Bool
    var rating: Double?
    var playCount: Int?
    var playedAt: Date?
    var popularity: Int?
    var syncGen: Int

    init(_ track: Track, generation: Int) {
        id = track.id.rawValue
        title = track.title
        albumId = track.albumID?.rawValue
        albumName = track.albumName
        artistId = track.artistID?.rawValue
        artistName = track.artistName
        trackNumber = track.trackNumber
        discNumber = track.discNumber
        duration = track.duration
        year = track.year
        originalYear = track.originalYear
        genre = track.genre
        codec = track.codec
        contentType = track.contentType
        bitRateKbps = track.bitRateKbps
        sampleRate = track.sampleRate
        bitDepth = track.bitDepth
        channelCount = track.channelCount
        bpm = track.bpm
        fileSize = track.fileSize
        artworkId = track.artwork?.rawValue
        rgTrackGain = track.replayGain?.trackGain
        rgAlbumGain = track.replayGain?.albumGain
        rgTrackPeak = track.replayGain?.trackPeak
        rgAlbumPeak = track.replayGain?.albumPeak
        isFavorite = track.isFavorite
        rating = track.rating?.value
        playCount = track.playCount
        playedAt = track.playedAt
        popularity = track.popularity
        syncGen = generation
    }

    func domain(server: ServerID) -> Track {
        let replayGain: ReplayGain? = (rgTrackGain ?? rgAlbumGain ?? rgTrackPeak ?? rgAlbumPeak) == nil
            ? nil
            : ReplayGain(
                trackGain: rgTrackGain,
                albumGain: rgAlbumGain,
                trackPeak: rgTrackPeak,
                albumPeak: rgAlbumPeak
            )
        return Track(
            id: MediaID(server: server, rawValue: id),
            title: title,
            albumName: albumName,
            albumID: albumId.map { MediaID(server: server, rawValue: $0) },
            artistName: artistName,
            artistID: artistId.map { MediaID(server: server, rawValue: $0) },
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            year: year,
            originalYear: originalYear,
            genre: genre,
            codec: codec,
            contentType: contentType,
            bitRateKbps: bitRateKbps,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channelCount: channelCount,
            bpm: bpm,
            fileSize: fileSize,
            artwork: artworkId.map { ArtworkID(server: server, rawValue: $0) },
            replayGain: replayGain,
            isFavorite: isFavorite,
            rating: rating.flatMap(StarRating.init),
            playCount: playCount,
            playedAt: playedAt,
            popularity: popularity
        )
    }
}

/// One track the user asked to keep.
public struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "download"

    public enum State: String, Codable, Sendable {
        case queued
        case running
        case done
        case failed

        /// A state this build does not know — written by a newer one — reads as `failed` rather
        /// than as an error.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .failed
        }
    }

    public var trackId: String
    public var state: State
    public var fileName: String?
    public var bytes: Int64?
    public var expectedBytes: Int64?
    public var variant: String
    public var addedAt: Date
    public var failure: String?
    public var requestedBy: String
    /// A copy of what the song is, so a download can be listed and played
    /// without the library index knowing about it.
    public var title: String?
    public var artistName: String?
    public var albumName: String?
    public var artworkId: String?
    public var duration: Double?
    /// Where this song sits in the queue, or nil when it is not owed —
    /// already here, already failed, or asked for before there was a queue.
    /// See `LibraryIndex.queuedDownloads`.
    public var queueOrder: Int?
    /// The copy this song had before a replacement was asked for, while the replacement is on its
    /// way.
    public var previousFileName: String?
    public var previousVariant: String?

    public init(
        trackId: String,
        state: State,
        fileName: String? = nil,
        bytes: Int64? = nil,
        expectedBytes: Int64? = nil,
        variant: String = "orig",
        addedAt: Date = Date(),
        failure: String? = nil,
        requestedBy: Set<String> = [],
        title: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        artworkId: String? = nil,
        duration: Double? = nil,
        queueOrder: Int? = nil,
        previousFileName: String? = nil,
        previousVariant: String? = nil
    ) {
        self.trackId = trackId
        self.state = state
        self.fileName = fileName
        self.bytes = bytes
        self.expectedBytes = expectedBytes
        self.variant = variant
        self.addedAt = addedAt
        self.failure = failure
        self.requestedBy = requestedBy.sorted().joined(separator: "\n")
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.artworkId = artworkId
        self.duration = duration
        self.queueOrder = queueOrder
        self.previousFileName = previousFileName
        self.previousVariant = previousVariant
    }

    /// What was written down at download time, as a track. Enough for a row
    /// and enough to play: the file is on disk and the id is the id.
    public func rememberedTrack(server: ServerID) -> Track? {
        guard let title else { return nil }
        return Track(
            id: MediaID(server: server, rawValue: trackId),
            title: title,
            albumName: albumName,
            artistName: artistName,
            duration: duration,
            artwork: artworkId.map { ArtworkID(server: server, rawValue: $0) }
        )
    }

    /// Everything that wants this track kept.
    public var reasons: Set<String> {
        Set(requestedBy.components(separatedBy: "\n").filter { !$0.isEmpty })
    }

    public mutating func setReasons(_ reasons: Set<String>) {
        requestedBy = reasons.sorted().joined(separator: "\n")
    }
}

/// One change waiting for a server.
public struct OutboxRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "outbox"

    public enum Kind: String, Codable, Sendable {
        case rating
        case favorite
        case play
    }

    public var id: Int64?
    public var kind: Kind
    public var itemId: String
    /// Which kind of thing was hearted; nil for the others.
    public var mediaKind: String?
    /// The star value, or nil for "no rating" — which is itself a change, so
    /// the column being null does not mean the row says nothing.
    public var rating: Double?
    public var flag: Bool?
    public var at: Date
    public var attempts: Int
    public var lastError: String?

    public init(
        id: Int64? = nil,
        kind: Kind,
        itemId: String,
        mediaKind: String? = nil,
        rating: Double? = nil,
        flag: Bool? = nil,
        at: Date = Date(),
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.mediaKind = mediaKind
        self.rating = rating
        self.flag = flag
        self.at = at
        self.attempts = attempts
        self.lastError = lastError
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A playlist the server has, kept by name so a filter can ask about it.
public struct IndexedPlaylistRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "indexedPlaylist"

    public var id: String
    public var name: String
    /// Nil until the songs in it have been fetched.
    public var membersFetchedAt: Date?

    public init(id: String, name: String, membersFetchedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.membersFetchedAt = membersFetchedAt
    }
}

/// A playlist that was downloaded: its name, its picture and the order its
/// songs go in, kept locally because the server is not there to ask.
public struct DownloadedPlaylistRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "downloadedPlaylist"

    public var id: String
    public var name: String
    public var artworkId: String?
    public var trackIds: String
    public var addedAt: Date
    /// When this was last compared with the server. Nil means never.
    public var checkedAt: Date?
    /// The server no longer has this playlist. The copy on the phone stays —
    /// it may be the only one left — but it has stopped tracking anything.
    public var missingFromServer: Bool

    public init(
        id: String,
        name: String,
        artworkId: String? = nil,
        trackIds: [String] = [],
        addedAt: Date = Date(),
        checkedAt: Date? = nil,
        missingFromServer: Bool = false
    ) {
        self.id = id
        self.name = name
        self.artworkId = artworkId
        self.trackIds = trackIds.joined(separator: "\n")
        self.addedAt = addedAt
        self.checkedAt = checkedAt
        self.missingFromServer = missingFromServer
    }

    /// In playing order.
    public var tracks: [String] {
        trackIds.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}
