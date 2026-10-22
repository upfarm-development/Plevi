import Foundation
import PleviDomain

/// Plex's library responses, and the mapping onto the app's domain model.
struct PlexMediaContainerResponse: Decodable {
    let mediaContainer: Container

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }

    struct Container: Decodable {
        let size: Int?
        let totalSize: Int?
        let metadata: [PlexMetadata]?

        enum CodingKeys: String, CodingKey {
            case size, totalSize
            case metadata = "Metadata"
        }
    }

    var items: [PlexMetadata] {
        mediaContainer.metadata ?? []
    }
}

/// One row of a Plex library. The same shape serves artists, albums and
/// tracks; which fields are populated depends on `type`.
struct PlexMetadata: Decodable {
    let ratingKey: String?
    let key: String?
    let type: String?
    let title: String?
    let titleSort: String?
    let summary: String?

    /// The parent is the album for a track, the artist for an album.
    let parentRatingKey: String?
    /// The same relationship as `parentRatingKey`, as a path ("/library/metadata/501") rather than
    /// a bare id.
    let parentKey: String?
    let parentTitle: String?
    let parentThumb: String?
    @PlexNumber var parentIndex: Int?

    /// The grandparent is the artist for a track.
    let grandparentRatingKey: String?
    /// `grandparentKey`'s own path form — see `parentKey`.
    let grandparentKey: String?
    let grandparentTitle: String?
    /// The track's own artist, where it differs from the album's. Plex fills
    /// this in on compilations and features and leaves it out otherwise, so
    /// it is the credit to show when it is there.
    let originalTitle: String?
    let grandparentThumb: String?

    @PlexNumber var index: Int?
    @PlexNumber var year: Int?
    let thumb: String?
    let art: String?
    /// Milliseconds. Every duration Plex reports is in milliseconds.
    @PlexNumber var duration: Int?
    /// Seconds since the epoch.
    @PlexNumber var addedAt: Int64?
    @PlexNumber var lastViewedAt: Int64?
    /// History rows only — `/status/sessions/history/all`.
    @PlexNumber var viewedAt: Int64?
    @PlexNumber var viewCount: Int?
    @PlexNumber var leafCount: Int?
    @PlexNumber var childCount: Int?
    /// What a collection is made of — "album" or "artist". Only collections
    /// carry it, and without it the two kinds are indistinguishable.
    let subtype: String?
    /// 0–10. Plex stores a five-star rating doubled.
    @PlexNumber var userRating: Double?
    /// The critic's score, 0–10 — Plex's own `rating`, which is a wholly different number from the
    /// two beside it.
    @PlexNumber var rating: Double?
    @PlexNumber var audienceRating: Double?
    /// The audience's own popularity figure — how many of Plex's users have played or rated this,
    /// not what this listener has.
    @PlexNumber var ratingCount: Int?
    let originallyAvailableAt: String?
    /// Plex's name for the record label.
    let studio: String?

    /// Playlists only: the mosaic Plex builds from their covers.
    let composite: String?
    /// Playlists only: whether it is a rule rather than a list of songs.
    let smart: PlexBool?
    /// One playlist row's own identity, so duplicates and reorders are
    /// unambiguous — unlike Subsonic, which removes by position.
    @PlexNumber var playlistItemID: Int?

    let genre: [PlexTag]?
    let format: [PlexTag]?
    let subformat: [PlexTag]?
    let media: [PlexMedia]?
    /// One entry per online metadata service Plex has matched this item to
    /// — present only when the request carried `includeGuids=1`, and even
    /// then only for a matched artist. See `PlexMapper.musicBrainzID(from:)`.
    let guid: [PlexGuid]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, titleSort, summary
        case parentRatingKey, parentKey, parentTitle, parentThumb, parentIndex
        case grandparentRatingKey, grandparentKey, grandparentTitle, grandparentThumb
        case originalTitle
        case index, year, thumb, art, duration, addedAt, lastViewedAt, viewedAt
        case viewCount, leafCount, childCount, subtype, userRating, originallyAvailableAt, studio
        case rating, audienceRating, ratingCount
        case composite, smart
        case playlistItemID = "playlistItemID"
        case genre = "Genre"
        case format = "Format"
        case subformat = "Subformat"
        case media = "Media"
        case guid = "Guid"
    }
}

/// One line of `includeGuids=1`'s `Guid` array — an external metadata service's own id for this
/// item, e.g. `mbid://70248960-cb53-4ea4-943a-...` for a MusicBrainz match or `tvdb://...` for a TV
/// one.
struct PlexGuid: Decodable {
    let id: String?
}

struct PlexTag: Decodable {
    let tag: String?
}

struct PlexMedia: Decodable {
    let audioCodec: String?
    let container: String?
    @PlexNumber var bitrate: Int?
    @PlexNumber var audioChannels: Int?
    let part: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case audioCodec, container, bitrate, audioChannels
        case part = "Part"
    }
}

struct PlexPart: Decodable {
    @PlexNumber var id: Int?
    /// The path the file is streamed from, e.g. `/library/parts/1/2/file.flac`.
    let key: String?
    let file: String?
    @PlexNumber var size: Int64?
    let container: String?
    let stream: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case id, key, file, size, container
        case stream = "Stream"
    }
}

/// One stream inside a file — for music, the audio itself.
struct PlexStream: Decodable {
    @PlexNumber var id: Int?
    /// 1 is video, 2 audio, 3 subtitles, 4 lyrics.
    @PlexNumber var streamType: Int?
    /// Where the stream's own content is fetched from, for the kinds that
    /// have content of their own — a lyric stream is a file, and this is the
    /// path to it.
    let key: String?
    /// `lrc` or `txt` on a lyric stream. Taken as a hint only: what decides
    /// how the file is read is what is in it.
    let format: String?
    let codec: String?
    @PlexNumber var bitrate: Int?
    /// Hertz.
    @PlexNumber var samplingRate: Int?
    @PlexNumber var bitDepth: Int?
    @PlexNumber var channels: Int?
    /// Loudness, as Plex's own analysis measured it.
    @PlexNumber var gain: Double?
    @PlexNumber var peak: Double?
    @PlexNumber var loudness: Double?
    @PlexNumber var albumGain: Double?
    @PlexNumber var albumPeak: Double?
}


// MARK: - Mapping

/// Turns Plex rows into domain objects.
enum PlexMapper {
    /// Plex rates 0–10; a `StarRating` is 0.5–5 in half steps. Halving is
    /// exact in both directions, so a rating set in Plex reads back
    /// identically here and one set here shows the same in Plex.
    static func starRating(fromPlex rating: Double?) -> StarRating? {
        guard let rating, rating > 0 else { return nil }
        // Snapped to the nearest half star: Plex's own UI writes whole
        // numbers, but its API will accept anything.
        let halves = (rating).rounded()
        return StarRating(min(max(halves / 2, 0.5), 5))
    }

    static func plexRating(from rating: StarRating?) -> Double {
        guard let rating else { return 0 }
        return rating.value * 2
    }

    /// Just the year off one of those dates.
    static func originalYear(from raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let head = raw.split(separator: "-").first, head.count == 4,
              let year = Int(head), (1000...2999).contains(year)
        else { return nil }
        return year
    }

    /// Plex writes release dates as plain `yyyy-MM-dd` — except when it writes only the year.
    static func releaseDate(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        if let exact = formatter.date(from: raw) { return exact }
        guard let year = originalYear(from: raw) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)
    }

    /// Plex reports every duration in milliseconds.
    static func duration(fromMilliseconds value: Int?) -> TimeInterval? {
        guard let value, value > 0 else { return nil }
        return TimeInterval(value) / 1000
    }

    static func date(fromEpochSeconds value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    /// Artwork is addressed by its path on the server, which already carries
    /// the version — a changed cover gets a new path, so cached images never
    /// go stale behind the user's back.
    static func artwork(_ path: String?, server: ServerID) -> ArtworkID? {
        guard let path, !path.isEmpty else { return nil }
        return ArtworkID(server: server, rawValue: path)
    }

    static func mediaID(_ ratingKey: String?, server: ServerID) -> MediaID? {
        guard let ratingKey, !ratingKey.isEmpty else { return nil }
        return MediaID(server: server, rawValue: ratingKey)
    }

    /// The same id, falling back to reading it out of a path ("/library/metadata/501") when the
    /// bare id itself is not there — which a session-history row has been seen doing for
    /// `parentRatingKey`/`grandparentRatingKey` even though an ordinary…
    static func mediaID(ratingKey: String?, orPath path: String?, server: ServerID) -> MediaID? {
        if let direct = mediaID(ratingKey, server: server) { return direct }
        guard let path, let last = path.split(separator: "/").last, !last.isEmpty else { return nil }
        return MediaID(server: server, rawValue: String(last))
    }

    // MARK: Objects

    static func artist(_ item: PlexMetadata, server: ServerID) -> Artist? {
        guard let id = mediaID(item.ratingKey, server: server) else { return nil }
        return Artist(
            id: id,
            name: item.title ?? "Unknown Artist",
            sortName: item.titleSort,
            albumCount: item.childCount,
            artwork: artwork(item.thumb, server: server),
            rating: starRating(fromPlex: item.userRating),
            musicBrainzID: musicBrainzID(from: item.guid)
        )
    }

    /// Pulls the MusicBrainz id out of an `includeGuids=1` `Guid` array.
    /// Only present on a matched artist, and only asked for at all on the
    /// bulk artist listing — see `PlexProvider.artists()`.
    static func musicBrainzID(from guids: [PlexGuid]?) -> String? {
        guard let guids else { return nil }
        for guid in guids {
            guard let id = guid.id, id.hasPrefix("mbid://") else { continue }
            let mbid = id.dropFirst("mbid://".count)
            return mbid.isEmpty ? nil : String(mbid)
        }
        return nil
    }

    static func album(_ item: PlexMetadata, server: ServerID) -> Album? {
        guard let id = mediaID(item.ratingKey, server: server) else { return nil }
        let types = releaseTypes(for: item)
        return Album(
            id: id,
            name: item.title ?? "Unknown Album",
            artistName: item.parentTitle,
            artistID: mediaID(item.parentRatingKey, server: server),
            year: item.year,
            genre: item.genre?.first?.tag,
            trackCount: item.leafCount,
            duration: duration(fromMilliseconds: item.duration),
            artwork: artwork(item.thumb ?? item.parentThumb, server: server),
            addedAt: date(fromEpochSeconds: item.addedAt),
            playedAt: date(fromEpochSeconds: item.lastViewedAt),
            playCount: item.viewCount,
            rating: starRating(fromPlex: item.userRating),
            releaseTypes: types,
            isCompilation: types.contains(.compilation),
            recordLabel: item.studio?.nonEmptyValue,
            releaseDate: releaseDate(from: item.originallyAvailableAt),
            criticRating: item.rating,
            // Plex carries the review on the album row itself, so it arrives with a listing and
            // costs nothing extra — which is what lets a shelf pick a well-reviewed record without
            // a request per candidate.
            review: item.summary?.nonEmptyValue
        )
    }

    /// - Parameter resolvingArtistIDByName: Known artist names mapped to their own id (typically
    /// the whole library's), consulted only when `item.originalTitle` names someone other than the
    /// album's own artist — see the note on `artistID` below.
    static func track(
        _ item: PlexMetadata,
        server: ServerID,
        resolvingArtistIDByName: [String: MediaID] = [:]
    ) -> Track? {
        guard let id = mediaID(item.ratingKey, server: server) else { return nil }
        let media = item.media?.first
        let part = media?.part?.first
        let audio = part?.stream?.first { $0.streamType == 2 }
        // Hoisted out of the initialiser: with every one of these written
        // inline the type checker gives up on the expression.
        let credit: String? = item.originalTitle ?? item.grandparentTitle
        let bitRate: Int? = media?.bitrate ?? audio?.bitrate
        let channels: Int? = media?.audioChannels ?? audio?.channels
        let thumb: String? = item.thumb ?? item.parentThumb ?? item.grandparentThumb
        let gain: ReplayGain? = replayGain(from: audio)
        // A track's own id, not the album's — `grandparentRatingKey` is always the *album's*
        // artist, Plex having no direct reference for whoever `originalTitle` merely names in text.
        let artistID: MediaID?
        if let credit, credit != item.grandparentTitle,
           let resolved = resolvingArtistIDByName[credit.lowercased()] {
            artistID = resolved
        } else {
            artistID = mediaID(item.grandparentRatingKey, server: server)
        }
        return Track(
            id: id,
            title: item.title ?? "Unknown",
            albumName: item.parentTitle,
            albumID: mediaID(item.parentRatingKey, server: server),
            // The track's own credit when Plex has one; the album's artist
            // otherwise. A compilation whose every row said "Various Artists"
            // was this field being ignored.
            artistName: credit,
            artistID: artistID,
            trackNumber: item.index,
            // Plex puts the disc number on the *parent* index of a track.
            discNumber: item.parentIndex,
            duration: duration(fromMilliseconds: item.duration),
            year: item.year,
            // Plex sends `originallyAvailableAt` on whatever it is describing, so a track row
            // carries the song's own original date when the library has one — the album mapping
            // below has always read the same attribute.
            originalYear: originalYear(from: item.originallyAvailableAt),
            genre: item.genre?.first?.tag,
            codec: media?.audioCodec,
            contentType: nil,
            bitRateKbps: bitRate,
            sampleRate: audio?.samplingRate,
            bitDepth: audio?.bitDepth,
            channelCount: channels,
            fileSize: part?.size,
            artwork: artwork(thumb, server: server),
            replayGain: gain,
            rating: starRating(fromPlex: item.userRating),
            playCount: item.viewCount,
            playedAt: date(fromEpochSeconds: item.lastViewedAt),
            popularity: item.ratingCount
        )
    }

    /// Reference loudness for track gain, in LUFS.
    static let referenceLoudness = -18.0

    /// What Plex knows about a track's loudness, as ReplayGain.
    static func lyricStreamKey(in metadata: PlexMetadata) -> String? {
        for media in metadata.media ?? [] {
            for part in media.part ?? [] {
                for stream in part.stream ?? [] where stream.streamType == 4 {
                    if let key = stream.key, !key.isEmpty { return key }
                }
            }
        }
        return nil
    }

    static func replayGain(from stream: PlexStream?) -> ReplayGain? {
        guard let stream else { return nil }
        let trackGain = stream.loudness.map { referenceLoudness - $0 }
        let albumGain = stream.albumGain ?? stream.gain
        guard trackGain != nil || albumGain != nil else { return nil }
        return ReplayGain(
            trackGain: trackGain,
            albumGain: albumGain,
            trackPeak: stream.peak,
            albumPeak: stream.albumPeak ?? stream.peak
        )
    }

    /// Plex files release categories under Format and Subformat tags rather than a dedicated field,
    /// so those tags go through the same normalisation as OpenSubsonic's `releaseTypes` list.
    static func releaseTypes(for item: PlexMetadata) -> [ReleaseType] {
        let known: Set<String> = [
            "album", "single", "singles", "ep", "eps", "compilation",
            "compilations", "live", "remix", "remixes", "soundtrack",
            "original soundtrack", "ost", "demo", "demos",
        ]
        var types: [ReleaseType] = []
        for tag in ((item.format ?? []) + (item.subformat ?? [])).compactMap(\.tag) {
            let normalised = tag.lowercased().trimmingCharacters(in: .whitespaces)
            guard known.contains(normalised) else { continue }
            let mapped = ReleaseType(matching: normalised)
            if !types.contains(mapped) { types.append(mapped) }
        }
        return types
    }
}


extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
