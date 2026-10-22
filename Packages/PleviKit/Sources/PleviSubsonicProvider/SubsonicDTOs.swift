import Foundation
import PleviDomain

// Response DTOs matching the OpenSubsonic JSON contract (verified against
// https://opensubsonic.netlify.app).

struct SubsonicEnvelope: Decodable {
    let subsonicResponse: SubsonicPayload

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SubsonicPayload: Decodable {
    let status: String
    let version: String?
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: SubsonicErrorDTO?

    let artists: ArtistsDTO?
    let artist: ArtistWithAlbumsDTO?
    let album: AlbumWithSongsDTO?
    let albumList2: AlbumList2DTO?
    let song: ChildDTO?
    let randomSongs: SongListDTO?
    let similarSongs2: SongListDTO?
    let topSongs: SongListDTO?
    let artistInfo2: ArtistInfo2DTO?
    let albumInfo: AlbumInfoDTO?
    let genres: GenresDTO?
    let playlists: PlaylistsDTO?
    let playlist: PlaylistDTO?
    let searchResult3: SearchResult3DTO?
    let lyricsList: LyricsListDTO?
    let openSubsonicExtensions: [ExtensionDTO]?
    let scanStatus: ScanStatusDTO?
}

struct SubsonicErrorDTO: Decodable {
    let code: Int
    let message: String?
    let helpUrl: String?
}

struct ExtensionDTO: Decodable {
    let name: String
    let versions: [Int]?
}

/// `getScanStatus`. `scanning` is all the Subsonic spec promises; `count`
/// and `lastScan` are Navidrome's additions, which is why every field here
/// is optional.
struct ScanStatusDTO: Decodable {
    let scanning: Bool?
    /// Songs the server holds — Navidrome counts the ones that are still
    /// there, not the tombstones it keeps.
    let count: Int?
    let folderCount: Int?
    /// Kept as the server wrote it. This is a token to compare, not a date
    /// to show, and parsing it into a `Date` and back could only lose
    /// precision that equality depends on.
    let lastScan: String?
}

struct ArtistsDTO: Decodable {
    let index: [ArtistIndexDTO]?
}

struct ArtistIndexDTO: Decodable {
    let name: String?
    let artist: [ArtistID3DTO]?
}

struct ArtistID3DTO: Decodable {
    let id: String
    let name: String
    let sortName: String?
    let coverArt: String?
    let albumCount: Int?
    let starred: String?
    let userRating: Int?
    /// OpenSubsonic addition — the MusicBrainz artist this row was matched
    /// to, when the server matched one.
    let musicBrainzId: String?
}

struct ArtistWithAlbumsDTO: Decodable {
    let id: String
    let name: String
    let sortName: String?
    let coverArt: String?
    let albumCount: Int?
    let starred: String?
    let userRating: Int?
    let musicBrainzId: String?
    let album: [AlbumID3DTO]?
}

/// OpenSubsonic's `{year, month, day}` item date — any part of which may be missing, since a
/// release known only by its year is entirely normal.
struct ItemDateDTO: Decodable {
    let year: Int?
    let month: Int?
    let day: Int?

    init(year: Int?, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    private enum CodingKeys: String, CodingKey {
        case year, month, day
    }

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: CodingKeys.self) {
            self.init(
                year: (try? object.decodeIfPresent(Int.self, forKey: .year)) ?? nil,
                month: (try? object.decodeIfPresent(Int.self, forKey: .month)) ?? nil,
                day: (try? object.decodeIfPresent(Int.self, forKey: .day)) ?? nil
            )
            return
        }
        let single = try? decoder.singleValueContainer()
        if let number = try? single?.decode(Int.self) {
            self.init(year: number)
            return
        }
        guard let text = try? single?.decode(String.self) else {
            self.init(year: nil)
            return
        }
        // "1973", "1973-05", "1973-05-16" — and anything else is nobody's
        // date and is treated as none.
        let parts = text.split(separator: "-").map(String.init)
        self.init(
            year: parts.first.flatMap(Int.init),
            month: parts.count > 1 ? Int(parts[1]) : nil,
            day: parts.count > 2 ? Int(parts[2]) : nil
        )
    }

    /// The year, if it looks like one.
    var plausibleYear: Int? {
        guard let year, (1000...2999).contains(year) else { return nil }
        return year
    }

    var date: Date? {
        guard let year = plausibleYear else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month ?? 1
        components.day = day ?? 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)
    }
}

struct RecordLabelDTO: Decodable {
    let name: String?
}

struct AlbumID3DTO: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let playCount: Int?
    let created: String?
    let starred: String?
    let year: Int?
    let genre: String?
    let userRating: Int?
    let played: String?
    let releaseTypes: [String]?
    let isCompilation: Bool?
    let recordLabels: [RecordLabelDTO]?
    let originalReleaseDate: ItemDateDTO?
    let releaseDate: ItemDateDTO?
}

struct AlbumWithSongsDTO: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let playCount: Int?
    let created: String?
    let starred: String?
    let year: Int?
    let genre: String?
    let userRating: Int?
    let played: String?
    let releaseTypes: [String]?
    let isCompilation: Bool?
    let recordLabels: [RecordLabelDTO]?
    let originalReleaseDate: ItemDateDTO?
    let releaseDate: ItemDateDTO?
    let song: [ChildDTO]?
}

struct AlbumInfoDTO: Decodable {
    let notes: String?
    let musicBrainzId: String?
}

struct AlbumList2DTO: Decodable {
    let album: [AlbumID3DTO]?
}

struct ChildDTO: Decodable {
    let id: String
    let title: String
    let album: String?
    let albumId: String?
    let artist: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let size: Int64?
    let contentType: String?
    let suffix: String?
    let duration: Int?
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    /// OpenSubsonic only, and only where the file itself carries the tag.
    /// Absent on Subsonic and on every server that does not read it, which
    /// costs nothing — it simply stays nil.
    let bpm: Int?
    let playCount: Int?
    /// When it was last played. OpenSubsonic sends it; older servers do
    /// not, and then it stays nil, which reads as never played.
    let played: String?
    let starred: String?
    let userRating: Int?
    let replayGain: ReplayGainDTO?
    /// The song's own original date, where the server tags songs individually.
    let originalReleaseDate: ItemDateDTO?
    let originalYear: Int?
}

struct ReplayGainDTO: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
}

struct SongListDTO: Decodable {
    let song: [ChildDTO]?
}

struct ArtistInfo2DTO: Decodable {
    let biography: String?
    let similarArtist: [ArtistID3DTO]?
}

struct GenresDTO: Decodable {
    let genre: [GenreDTO]?
}

struct GenreDTO: Decodable {
    // The genre's name really is called "value" in the Subsonic contract.
    let value: String
    let songCount: Int?
    let albumCount: Int?
}

struct PlaylistsDTO: Decodable {
    let playlist: [PlaylistDTO]?
}

struct PlaylistDTO: Decodable {
    let id: String
    let name: String
    let comment: String?
    let owner: String?
    let isPublic: Bool?
    let songCount: Int?
    let duration: Int?
    let created: String?
    let changed: String?
    let coverArt: String?
    let entry: [ChildDTO]?

    enum CodingKeys: String, CodingKey {
        case id, name, comment, owner, songCount, duration, created, changed, coverArt, entry
        case isPublic = "public"
    }
}

struct SearchResult3DTO: Decodable {
    let artist: [ArtistID3DTO]?
    let album: [AlbumID3DTO]?
    let song: [ChildDTO]?
}

struct LyricsListDTO: Decodable {
    let structuredLyrics: [StructuredLyricsDTO]?
}

struct StructuredLyricsDTO: Decodable {
    let lang: String?
    let synced: Bool?
    /// Milliseconds.
    let offset: Double?
    let displayArtist: String?
    let displayTitle: String?
    let line: [LyricLineDTO]?
}

struct LyricLineDTO: Decodable {
    /// Milliseconds.
    let start: Double?
    let value: String
}

// MARK: - Lenient date parsing

enum SubsonicDates {
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: Date.ISO8601FormatStyle())
    }
}

// MARK: - Domain mapping

extension ArtistID3DTO {
    func domain(server: ServerID) -> Artist {
        Artist(
            id: MediaID(server: server, rawValue: id),
            name: name,
            sortName: sortName,
            albumCount: albumCount,
            artwork: coverArt.map { ArtworkID(server: server, rawValue: $0) },
            isFavorite: starred != nil,
            rating: userRating.flatMap { StarRating(stars: $0) },
            musicBrainzID: musicBrainzId
        )
    }
}

extension ArtistWithAlbumsDTO {
    func domainArtist(server: ServerID) -> Artist {
        Artist(
            id: MediaID(server: server, rawValue: id),
            name: name,
            sortName: sortName,
            albumCount: albumCount,
            artwork: coverArt.map { ArtworkID(server: server, rawValue: $0) },
            isFavorite: starred != nil,
            rating: userRating.flatMap { StarRating(stars: $0) },
            musicBrainzID: musicBrainzId
        )
    }
}

extension AlbumID3DTO {
    func domain(server: ServerID) -> Album {
        Album(
            id: MediaID(server: server, rawValue: id),
            name: name,
            artistName: artist,
            artistID: artistId.map { MediaID(server: server, rawValue: $0) },
            year: year,
            genre: genre,
            trackCount: songCount,
            duration: duration.map(TimeInterval.init),
            artwork: coverArt.map { ArtworkID(server: server, rawValue: $0) },
            addedAt: SubsonicDates.parse(created),
            playedAt: SubsonicDates.parse(played),
            playCount: playCount,
            isFavorite: starred != nil,
            rating: userRating.flatMap { StarRating(stars: $0) },
            releaseTypes: (releaseTypes ?? []).map(ReleaseType.init(matching:)),
            isCompilation: isCompilation ?? false,
            recordLabel: recordLabels?.compactMap(\.name).first,
            // The original date rather than a reissue's: a 1966 record repressed in 2015 is still
            // from 1966.
            releaseDate: originalReleaseDate?.date ?? releaseDate?.date
        )
    }
}

extension AlbumWithSongsDTO {
    func domainAlbum(server: ServerID) -> Album {
        Album(
            id: MediaID(server: server, rawValue: id),
            name: name,
            artistName: artist,
            artistID: artistId.map { MediaID(server: server, rawValue: $0) },
            year: year,
            genre: genre,
            trackCount: songCount,
            duration: duration.map(TimeInterval.init),
            artwork: coverArt.map { ArtworkID(server: server, rawValue: $0) },
            addedAt: SubsonicDates.parse(created),
            playedAt: SubsonicDates.parse(played),
            playCount: playCount,
            isFavorite: starred != nil,
            rating: userRating.flatMap { StarRating(stars: $0) },
            releaseTypes: (releaseTypes ?? []).map(ReleaseType.init(matching:)),
            isCompilation: isCompilation ?? false,
            recordLabel: recordLabels?.compactMap(\.name).first,
            // The original date rather than a reissue's: a 1966 record repressed in 2015 is still
            // from 1966.
            releaseDate: originalReleaseDate?.date ?? releaseDate?.date
        )
    }
}

extension ChildDTO {
    func domain(server: ServerID) -> Track {
        Track(
            id: MediaID(server: server, rawValue: id),
            title: title,
            albumName: album,
            albumID: albumId.map { MediaID(server: server, rawValue: $0) },
            artistName: artist,
            artistID: artistId.map { MediaID(server: server, rawValue: $0) },
            trackNumber: track,
            discNumber: discNumber,
            duration: duration.map(TimeInterval.init),
            year: year,
            originalYear: ItemDateDTO(year: originalYear).plausibleYear
                ?? originalReleaseDate?.plausibleYear,
            genre: genre,
            codec: suffix,
            contentType: contentType,
            bitRateKbps: bitRate,
            sampleRate: samplingRate,
            bitDepth: bitDepth,
            channelCount: channelCount,
            bpm: bpm,
            fileSize: size,
            artwork: coverArt.map { ArtworkID(server: server, rawValue: $0) },
            replayGain: replayGain.map {
                ReplayGain(
                    trackGain: $0.trackGain,
                    albumGain: $0.albumGain,
                    trackPeak: $0.trackPeak,
                    albumPeak: $0.albumPeak
                )
            },
            isFavorite: starred != nil,
            rating: userRating.flatMap { StarRating(stars: $0) },
            playCount: playCount,
            playedAt: SubsonicDates.parse(played)
        )
    }
}

extension PlaylistDTO {
    func domain(server: ServerID) -> Playlist {
        Playlist(
            id: MediaID(server: server, rawValue: id),
            name: name,
            comment: comment,
            trackCount: songCount,
            duration: duration.map(TimeInterval.init),
            isPublic: isPublic,
            changedAt: SubsonicDates.parse(changed),
            artwork: coverArt.map { ArtworkID(server: server, rawValue: $0) }
        )
    }
}
