import Foundation
import GRDB
import PleviDomain

/// A question about the library, written as nested rules.
public struct LibraryFilter: Codable, Hashable, Sendable {
    /// What the filter is looking for. The same rules read differently
    /// depending on the answer: "rating is 5" on songs means five-star songs,
    /// on albums it means five-star records.
    public enum Subject: String, Codable, Sendable, CaseIterable {
        case songs
        case albums
        /// Thin by comparison, and honestly so: the index keeps a name, a
        /// count of records, a rating and a favourite flag for an artist, and
        /// that is all there is to ask about.
        case artists
    }

    public var subject: Subject
    public var root: FilterGroup

    public init(subject: Subject = .songs, root: FilterGroup = FilterGroup()) {
        self.subject = subject
        self.root = root
    }

    /// A filter with no rules in it matches the whole library, which is
    /// almost never what someone meant to build.
    public var isEmpty: Bool { root.isEmpty }

    /// Whether the answer to this filter is a function of the library's version and nothing else,
    /// so a list read under it may be kept.
    public var isCacheable: Bool {
        func cacheable(_ node: FilterNode) -> Bool {
            switch node {
            case .rule(let rule):
                switch rule.field {
                case .lastPlayed, .playCount, .albumPlayCount, .downloaded, .playlistName:
                    return false
                default:
                    if case .days = rule.value { return false }
                    return true
                }
            case .group(let group):
                return group.children.allSatisfy(cacheable)
            }
        }
        return root.children.allSatisfy(cacheable)
    }
}

/// Rules and groups, so a group can hold either.
public indirect enum FilterNode: Codable, Hashable, Sendable, Identifiable {
    case rule(FilterRule)
    case group(FilterGroup)

    public var id: UUID {
        switch self {
        case .rule(let rule): rule.id
        case .group(let group): group.id
        }
    }
}

public struct FilterGroup: Codable, Hashable, Sendable, Identifiable {
    /// Whether everything in the group has to match, or only something.
    public enum Match: String, Codable, Sendable, CaseIterable {
        case all
        case any

        public var title: String {
            switch self {
            case .all: "all"
            case .any: "any"
            }
        }
    }

    public var id: UUID
    public var match: Match
    public var children: [FilterNode]

    public init(id: UUID = UUID(), match: Match = .all, children: [FilterNode] = []) {
        self.id = id
        self.match = match
        self.children = children
    }

    public var isEmpty: Bool {
        children.allSatisfy { node in
            switch node {
            case .rule: false
            case .group(let group): group.isEmpty
            }
        }
    }
}

public struct FilterRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var field: FilterField
    public var op: FilterOperator
    public var value: FilterValue

    public init(
        id: UUID = UUID(),
        field: FilterField,
        op: FilterOperator,
        value: FilterValue = .none
    ) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }
}

/// What a rule asks about.
public enum FilterField: String, Codable, CaseIterable, Sendable, Identifiable {
    case title
    case albumName
    case artistName
    case genre
    case year
    case rating
    case playCount
    case dateAdded
    case lastPlayed
    case duration
    case codec
    case favourite
    case downloaded
    case compilation
    /// Songs only: what the file actually is. Every song in a real library
    /// carries both, which is why they are offered — a rule about something
    /// the server never sends would only ever match nothing.
    case bitRate
    case fileSize
    /// Records only.
    case trackCount
    case recordLabel
    /// "album", "ep", "single", "live", "compilation", "soundtrack" — a
    /// record can be several at once, so this is a *contains* question.
    case releaseType
    /// Artists only.
    case albumCount

    // Everything below is read off a column the library already syncs and stores; nothing here
    // needs a new query or a new join.

    /// The reviewer's score out of ten, where the server keeps one — Plex
    /// does, Subsonic has no such field at all. On a song this asks about
    /// the record it came on.
    case criticRating
    /// The record's own stars, asked about from a song. Distinct from
    /// `rating`, which on a song is the song's own.
    case albumRating
    /// The record's own year, asked about from a song. Distinct from
    /// `year`, which prefers the song's own where it has one.
    case albumYear
    /// When the music was made rather than when this pressing was — very
    /// often absent, which is why it is its own field rather than folded
    /// into `year`.
    case originalYear
    /// The record's play count, asked about from a song.
    case albumPlayCount
    /// Where a song sits on its record.
    case trackNumber
    case discNumber
    /// What the file is, past the codec name.
    case sampleRate
    case bitDepth
    case channels
    /// How fast it goes, where the file itself was tagged with it and
    /// the server passes the tag along. Nothing here measures it.
    case bpm
    /// The day the record came out, as against the day it arrived here.
    case albumReleaseDate
    /// The record's decade, as the first year of it: 1980 for the eighties.
    case albumDecade
    /// What an artist's records are filed under, asked of all of them at once.
    case artistGenre
    /// Which playlists a song is in, asked about by their names.
    case playlistName

    public var id: String { rawValue }

    /// What the field is called, said the same way wherever it appears.
    public func title(for subject: LibraryFilter.Subject) -> String {
        switch self {
        // The subject's own name, whatever the subject is.
        case .title:
            switch subject {
            case .albums: "Album title"
            case .songs: "Track title"
            case .artists: "Artist name"
            }
        case .albumName: "Album title"
        case .artistName: "Artist name"

        // These belong to whichever thing is being filtered, so they are
        // named for it.
        case .playlistName: "Playlist name"
        case .genre: subject == .albums ? "Album genre" : "Track genre"
        case .year: subject == .albums ? "Album year" : "Track year"
        case .rating:
            switch subject {
            case .albums: "Album rating"
            case .songs: "Track rating"
            case .artists: "Artist rating"
            }
        case .favourite:
            switch subject {
            case .albums: "Album favourite"
            case .songs: "Track favourite"
            case .artists: "Artist favourite"
            }
        case .playCount: subject == .albums ? "Album play count" : "Track play count"
        case .lastPlayed:
            switch subject {
            case .albums: "Album last played"
            case .artists: "Artist last played"
            case .songs: "Track last played"
            }
        case .duration: subject == .albums ? "Album length" : "Track length"
        // A song has no added date of its own — the record it came on is the
        // nearest true answer — so it is named for the record on both of
        // those. An artist's is the day their first record arrived.
        case .dateAdded: subject == .artists ? "Artist date added" : "Album date added"

        // Always the record's, whichever screen asks.
        case .criticRating: "Album critic rating"
        case .albumRating: "Album rating"
        case .albumYear: "Album year"
        case .artistGenre: "Artist genre"
        case .albumReleaseDate: "Album date released"
        case .albumDecade: "Album decade"
        case .albumPlayCount: "Album play count"
        case .compilation: "Album is a compilation"
        case .recordLabel: "Album record label"
        case .releaseType: "Album release type"
        case .trackCount: "Album track count"

        // Always the song's, or the file behind it.
        case .originalYear: "Track original year"
        case .trackNumber: "Track number"
        // "Disc number" until the list came to be sorted by whose property
        // each field is: it was the one track field that did not say so, and
        // it filed itself under D in the middle of the record's fields.
        case .discNumber: "Track disc number"
        case .codec: "Track format"
        case .bitRate: "Track bit rate"
        case .fileSize: "Track file size"
        case .sampleRate: "Track sample rate"
        case .bitDepth: "Track bit depth"
        case .channels: "Track channels"
        case .bpm: "Track BPM"

        // Ours, not the server's, and about whichever thing is listed.
        case .downloaded: "Downloaded"
        case .albumCount: "Artist album count"
        }
    }

    /// The kind of answer the field takes, which decides both the operators
    /// offered and the editor shown for the value.
    public enum Kind: Sendable {
        case text
        case number
        case rating
        case date
        case flag
    }

    public var kind: Kind {
        switch self {
        case .title, .albumName, .artistName, .genre, .codec, .artistGenre: .text
        case .recordLabel, .releaseType, .playlistName: .text
        case .year, .playCount, .duration: .number
        case .bitRate, .fileSize, .trackCount, .albumCount: .number
        case .albumYear, .originalYear, .albumPlayCount: .number
        case .trackNumber, .discNumber: .number
        case .sampleRate, .bitDepth, .channels, .bpm: .number
        case .rating, .albumRating: .rating
        // Out of ten on the server's own scale, not a five-star rating —
        // asked about as a plain number so "at least 8" means what it says.
        case .criticRating: .number
        case .dateAdded, .lastPlayed, .albumReleaseDate: .date
        // The first year of the decade, so "is 1980" means the eighties.
        case .albumDecade: .number
        case .favourite, .downloaded, .compilation: .flag
        }
    }

    public func applies(to subject: LibraryFilter.Subject) -> Bool {
        switch self {
        case .albumName, .codec, .bitRate, .fileSize: subject == .songs
        case .trackNumber, .discNumber, .sampleRate, .bitDepth, .channels,
             .bpm: subject == .songs
        // Read off the record either way: on an album page they are its own
        // columns, and a song reaches them through the join its query
        // already makes.
        case .albumRating, .albumYear, .albumPlayCount, .originalYear: subject == .songs
        case .criticRating: subject != .artists
        case .albumReleaseDate, .albumDecade: subject != .artists
        case .compilation, .recordLabel, .releaseType: subject != .artists
        // Songs only. A record is not in a playlist; some of its songs are,
        // and answering for the record would mean either "all of them" or
        // "any of them" without saying which.
        case .playlistName: subject == .songs
        case .trackCount: subject == .albums
        case .albumCount: subject == .artists
        // An artist has a name, a rating and a favourite flag. Everything
        // else — a year, a genre, a length, a format — belongs to the music,
        // not to the person who made it.
        case .title, .rating, .favourite: true
        // Answered for an artist from their records — see `artistGenreExpression` and its two
        // neighbours.
        case .dateAdded, .lastPlayed: true
        case .artistGenre: subject == .artists
        case .artistName, .genre, .year, .playCount, .duration, .downloaded:
            subject != .artists
        }
    }

    /// Which thing a field is about, for putting a list of forty of them in an order somebody can
    /// find something in.
    public enum Family: Int, Comparable, Sendable {
        case artist
        case album
        case track
        case playlist
        /// Ours rather than the music's. One field, and it belongs at the
        /// end because it is not a property of anything on the server.
        case ours

        public static func < (first: Family, second: Family) -> Bool {
            first.rawValue < second.rawValue
        }
    }

    /// Whose property this is, on the screen being filtered.
    public func family(for subject: LibraryFilter.Subject) -> Family {
        switch self {
        case .artistName, .albumCount, .artistGenre:
            .artist
        case .albumName, .criticRating, .albumRating, .albumYear,
             .albumPlayCount, .compilation, .recordLabel, .releaseType,
             .trackCount, .albumReleaseDate, .albumDecade:
            .album
        // The record's on a song or a record; the person's own on an artist.
        case .dateAdded:
            subject == .artists ? .artist : .album
        case .originalYear, .trackNumber, .discNumber, .codec, .bitRate,
             .fileSize, .sampleRate, .bitDepth, .channels, .bpm:
            .track
        case .playlistName:
            .playlist
        case .downloaded:
            .ours
        // Named for whatever is being listed, so they follow it.
        case .title, .rating, .favourite:
            switch subject {
            case .artists: .artist
            case .albums: .album
            case .songs: .track
            }
        // The same, except that an artist is never asked these — see
        // `applies(to:)` — so there is no artist answer to give.
        case .year, .playCount, .duration:
            subject == .albums ? .album : .track
        case .genre:
            subject == .albums ? .album : .track
        case .lastPlayed:
            switch subject {
            case .albums: .album
            case .artists: .artist
            case .songs: .track
            }
        }
    }

    /// Every field this subject can be asked about, in the order they are offered.
    public func isAnswerable(by capabilities: ServerCapabilities) -> Bool {
        switch self {
        case .criticRating: capabilities.contains(.criticRatings)
        default: true
        }
    }

    public static func fields(
        for subject: LibraryFilter.Subject,
        on capabilities: ServerCapabilities = .everything
    ) -> [FilterField] {
        allCases
            .filter { $0.applies(to: subject) && $0.isAnswerable(by: capabilities) }
            .sorted { first, second in
                let families = (first.family(for: subject), second.family(for: subject))
                guard families.0 == families.1 else { return families.0 < families.1 }
                return first.title(for: subject)
                    .localizedStandardCompare(second.title(for: subject)) == .orderedAscending
            }
    }
}

public enum FilterOperator: String, Codable, CaseIterable, Sendable, Identifiable {
    // Text
    case matches
    case doesNotMatch
    case contains
    case doesNotContain
    case beginsWith
    case endsWith
    // Numbers, ratings, lengths
    case equals
    case notEquals
    case atLeast
    case atMost
    case greaterThan
    case lessThan
    // Dates
    case before
    case after
    case inTheLast
    case notInTheLast
    // Anything, and the only way to ask for unrated
    case isSet
    case isNotSet
    // Flags
    case isTrue
    case isFalse

    public var id: String { rawValue }

    public func title(for field: FilterField) -> String {
        switch self {
        case .matches: "is"
        case .doesNotMatch: "is not"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .beginsWith: "begins with"
        case .endsWith: "ends with"
        case .equals: "is"
        case .notEquals: "is not"
        case .atLeast: "is at least"
        case .atMost: "is at most"
        case .greaterThan: "is more than"
        case .lessThan: "is less than"
        case .before: "is before"
        case .after: "is after"
        case .inTheLast: "is in the last"
        case .notInTheLast: "is not in the last"
        // "Is set" is true but says nothing.
        case .isSet:
            switch field {
            case .rating: "is rated"
            case .lastPlayed: "has been played"
            case .dateAdded: "is known"
            default: "is set"
            }
        case .isNotSet:
            switch field {
            case .rating: "is unrated"
            case .lastPlayed: "has never been played"
            case .dateAdded: "is unknown"
            default: "is not set"
            }
        case .isTrue: "is yes"
        case .isFalse: "is no"
        }
    }

    /// Whether the operator needs a value typed in beside it.
    public var needsValue: Bool {
        switch self {
        case .isSet, .isNotSet, .isTrue, .isFalse: false
        default: true
        }
    }

    /// The tests offered for a particular field.
    public static func operators(for field: FilterField) -> [FilterOperator] {
        let all = operators(for: field.kind)
        switch field {
        case .playCount, .albumPlayCount:
            // Never played is "is 0" here, and that rule works. The record's
            // count is read through `COALESCE(…, 0)` as well.
            return all.filter { $0 != .isSet && $0 != .isNotSet }
        case .playlistName, .artistGenre:
            // See the notes on those cases: the value is every playlist the song is in, or every
            // genre the artist's records are filed under, run together — so only the questions that
            // are true of a list make sense.
            return [.contains, .doesNotContain]
        default:
            return all
        }
    }

    public static func operators(for kind: FilterField.Kind) -> [FilterOperator] {
        switch kind {
        case .text:
            [.matches, .doesNotMatch, .contains, .doesNotContain, .beginsWith, .endsWith, .isSet, .isNotSet]
        case .number:
            [.equals, .notEquals, .atLeast, .atMost, .greaterThan, .lessThan, .isSet, .isNotSet]
        case .rating:
            [.equals, .notEquals, .atLeast, .atMost, .greaterThan, .lessThan, .isSet, .isNotSet]
        case .date:
            [.before, .after, .inTheLast, .notInTheLast, .isSet, .isNotSet]
        case .flag:
            [.isTrue, .isFalse]
        }
    }
}

/// How a span of time is written on screen.
public enum FilterPeriod: String, CaseIterable, Identifiable, Sendable {
    case days
    case weeks
    case months
    case years

    public var id: String { rawValue }

    /// How many days one of these is.
    public var days: Int {
        switch self {
        case .days: 1
        case .weeks: 7
        case .months: 30
        case .years: 365
        }
    }

    /// "day" / "days", so the line reads as a sentence.
    public func title(count: Int) -> String {
        let singular = String(rawValue.dropLast())
        return count == 1 ? singular : rawValue
    }
}

public extension FilterValue {
    /// The longest span a rule may hold, in days: ten thousand years, far
    /// past any library and far short of overflowing `Int` or the date
    /// arithmetic behind a cutoff.
    static let maximumDays = 3_650_000

    /// A span typed as `count` of `unit`, clamped so a field that is held on
    /// a nine keeps meaning "a very long time" rather than trapping on the
    /// multiplication.
    static func days(count: Int, unit: FilterPeriod) -> FilterValue {
        let limit = maximumDays / unit.days
        return .days(min(max(0, count), limit) * unit.days)
    }

    /// The largest unit a number of days divides into exactly, and how many of them.
    static func spelled(days: Int) -> (count: Int, unit: FilterPeriod) {
        guard days > 0 else { return (days, .days) }
        for unit in [FilterPeriod.years, .months, .weeks] where days % unit.days == 0 {
            return (days / unit.days, unit)
        }
        return (days, .days)
    }
}

public enum FilterValue: Codable, Hashable, Sendable {
    case text(String)
    case number(Double)
    case date(Date)
    /// For "in the last —": a number of days, so the rule keeps meaning the
    /// same thing as time passes rather than freezing on the day it was made.
    case days(Int)
    case none
}

// MARK: - Turning a filter into SQL

/// A compiled filter: a WHERE clause and the values to bind to it.
struct CompiledFilter {
    var sql: String
    var arguments: [any DatabaseValueConvertible]

    /// No rules at all: every row qualifies. Written as a clause rather than
    /// as a special case so the caller has one shape to deal with.
    static var matchesEverything: CompiledFilter { CompiledFilter(sql: "1", arguments: []) }
}

extension LibraryFilter {
    /// Column expressions per subject.
    public var playlistNamesAskedAbout: [String] {
        var found: [String] = []
        func walk(_ node: FilterNode) {
            switch node {
            case .rule(let rule):
                guard rule.field == .playlistName, case .text(let text) = rule.value else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !found.contains(trimmed) { found.append(trimmed) }
            case .group(let group):
                group.children.forEach(walk)
            }
        }
        walk(.group(root))
        return found
    }

    func column(for field: FilterField) -> String? {
        switch subject {
        case .songs:
            switch field {
            case .title: "track.title"
            case .albumName: "COALESCE(track.albumName, album.name)"
            case .artistName: "track.artistName"
            case .genre: "COALESCE(track.genre, album.genre)"
            case .year: "COALESCE(track.year, album.year)"
            case .rating: "track.rating"
            case .playCount: "COALESCE(track.playCount, 0)"
            // A song has no added date of its own; the record it came on is
            // the nearest true answer.
            case .dateAdded: "album.addedAt"
            // The song's own played date, not its record's.
            case .lastPlayed: "track.playedAt"
            case .duration: "track.duration"
            case .codec: "track.codec"
            case .bitRate: "track.bitRateKbps"
            case .fileSize: "track.fileSize"
            case .favourite: "track.isFavorite"
            case .downloaded: Self.downloadedSongExpression
            case .compilation: "album.isCompilation"
            case .recordLabel: "album.recordLabel"
            case .releaseType: "album.releaseTypes"
            case .criticRating: "album.criticRating"
            case .albumRating: "album.rating"
            case .albumYear: "album.year"
            case .albumReleaseDate: "album.releaseDate"
            case .albumDecade: Self.decadeExpression("album.year")
            case .albumPlayCount: "COALESCE(album.playCount, 0)"
            case .originalYear: "track.originalYear"
            case .trackNumber: "track.trackNumber"
            case .discNumber: "track.discNumber"
            case .sampleRate: "track.sampleRate"
            case .bitDepth: "track.bitDepth"
            case .channels: "track.channelCount"
            case .bpm: "track.bpm"
            case .playlistName: Self.playlistNamesExpression
            case .trackCount, .albumCount, .artistGenre: nil
            }
        case .albums:
            switch field {
            case .title: "album.name"
            case .albumName: nil
            case .artistName: "album.artistName"
            case .genre: "album.genre"
            case .year: "album.year"
            case .rating: "album.rating"
            case .playCount: "COALESCE(album.playCount, 0)"
            case .dateAdded: "album.addedAt"
            case .lastPlayed: "album.playedAt"
            case .duration: "album.duration"
            case .codec, .bitRate, .fileSize: nil
            case .favourite: "album.isFavorite"
            case .downloaded: Self.downloadedAlbumExpression
            case .compilation: "album.isCompilation"
            case .trackCount: "album.trackCount"
            case .recordLabel: "album.recordLabel"
            case .releaseType: "album.releaseTypes"
            case .albumCount: nil
            case .criticRating: "album.criticRating"
            case .albumReleaseDate: "album.releaseDate"
            case .albumDecade: Self.decadeExpression("album.year")
            // The record *is* the subject here, so its own year, stars and plays are already asked
            // for by `year`, `rating` and `playCount`; a second way to say the same thing would
            // only be a second thing to get wrong.
            case .albumRating, .albumYear, .albumPlayCount, .originalYear,
                 .trackNumber, .discNumber, .sampleRate, .bitDepth, .channels,
                 .bpm, .playlistName, .artistGenre:
                nil
            }

        case .artists:
            switch field {
            case .title: "artist.name"
            case .rating: "artist.rating"
            case .favourite: "artist.isFavorite"
            case .albumCount: "artist.albumCount"
            // Read off their records, because the artist table has no such
            // column and no server this app speaks to would fill one.
            case .artistGenre: Self.artistGenresExpression
            case .dateAdded: Self.artistAddedExpression
            case .lastPlayed: Self.artistPlayedExpression
            // Nothing else on this table, and a rule about a column that is
            // not there must find nothing rather than pretend.
            case .albumName, .artistName, .genre, .year, .playCount,
                 .duration, .codec, .downloaded, .compilation,
                 .bitRate, .fileSize, .trackCount, .recordLabel, .releaseType,
                 .criticRating, .albumRating, .albumYear, .albumPlayCount,
                 .albumReleaseDate, .albumDecade,
                 .originalYear, .trackNumber, .discNumber, .sampleRate,
                 .bitDepth, .channels, .bpm, .playlistName:
                nil
            }
        }
    }

    /// Every playlist name a song is filed under, run together.
    private static func decadeExpression(_ column: String) -> String {
        // `NULLIF(…, 0)` rather than a null check alone: a record with no year is stored as zero on
        // some servers, and `(0 / 10) * 10` is a perfectly good nought — so "decade is set" would
        // have been true of every record that has no year at all.
        "((NULLIF(\(column), 0) / 10) * 10)"
    }

    /// Everything the artist's records are filed under, run together — the same shape as the
    /// playlist names above, and asked the same way: an artist is filed under several genres or
    /// none, so "is" would be asking whether the whole run is exactly…
    private static let artistGenresExpression = """
        (SELECT GROUP_CONCAT(album.genre, '\n')
         FROM album WHERE album.artistId = artist.id AND album.genre IS NOT NULL)
        """

    /// When their first record arrived, which is when they did.
    private static let artistAddedExpression = """
        (SELECT MIN(album.addedAt) FROM album WHERE album.artistId = artist.id)
        """

    /// The last time anything of theirs was played.
    private static let artistPlayedExpression = """
        (SELECT MAX(album.playedAt) FROM album WHERE album.artistId = artist.id)
        """

    private static let playlistNamesExpression = """
        (SELECT GROUP_CONCAT(indexedPlaylist.name, '\n')
         FROM playlistMember
         JOIN indexedPlaylist ON indexedPlaylist.id = playlistMember.playlistId
         WHERE playlistMember.trackId = track.id)
        """

    private static let downloadedSongExpression = """
        (SELECT COUNT(*) FROM download WHERE download.trackId = track.id AND download.state = 'done')
        """

    private static let downloadedAlbumExpression = """
        (SELECT COUNT(*) FROM download
         JOIN track AS downloadedTrack ON downloadedTrack.id = download.trackId
         WHERE downloadedTrack.albumId = album.id AND download.state = 'done')
        """

    func compile() -> CompiledFilter {
        // Parenthesised as a whole: callers append `AND downloaded…` and an
        // order's own clause, and an "any" root is a bare `a OR b`, which
        // those bound to only its last alternative.
        guard let compiled = compile(root) else { return .matchesEverything }
        return CompiledFilter(sql: "(\(compiled.sql))", arguments: compiled.arguments)
    }

    /// `nil` when nothing in the group produced a test.
    private func compile(_ group: FilterGroup) -> CompiledFilter? {
        var parts: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        for child in group.children {
            let compiled: CompiledFilter
            switch child {
            case .rule(let rule):
                guard let piece = compile(rule) else { continue }
                compiled = piece
            case .group(let inner):
                guard !inner.isEmpty, let piece = compile(inner) else { continue }
                compiled = piece
            }
            parts.append("(\(compiled.sql))")
            arguments.append(contentsOf: compiled.arguments)
        }
        guard !parts.isEmpty else { return nil }
        let joiner = group.match == .all ? " AND " : " OR "
        return CompiledFilter(sql: parts.joined(separator: joiner), arguments: arguments)
    }

    private func compile(_ rule: FilterRule) -> CompiledFilter? {
        // A field the subject does not have — an album's codec — is dropped
        // rather than guessed at. It can only get there by switching a
        // half-built filter from songs to albums.
        guard let column = column(for: rule.field) else { return nil }

        switch rule.op {
        case .isSet:
            return CompiledFilter(sql: "\(column) IS NOT NULL", arguments: [])
        case .isNotSet:
            return CompiledFilter(sql: "\(column) IS NULL", arguments: [])
        case .isTrue:
            return CompiledFilter(sql: "\(column) > 0", arguments: [])
        case .isFalse:
            return CompiledFilter(
                sql: "(\(column) IS NULL OR \(column) = 0)",
                arguments: []
            )
        default:
            break
        }

        switch rule.value {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return compileText(column: column, op: rule.op, text: trimmed)
        case .number(let number):
            return compileComparison(column: column, op: rule.op, value: number)
        case .days(let days):
            return compileWithinDays(column: column, op: rule.op, days: days)
        case .date(let date):
            return compileDate(column: column, op: rule.op, date: date)
        case .none:
            return nil
        }
    }

    private func compileText(
        column: String,
        op: FilterOperator,
        text: String
    ) -> CompiledFilter? {
        // LIKE with the pattern bound rather than pasted, so % and _ typed by
        // a person are the pattern they asked for and nothing else is.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        switch op {
        case .matches:
            return CompiledFilter(sql: "\(column) = ? COLLATE NOCASE", arguments: [text])
        case .doesNotMatch:
            return CompiledFilter(
                sql: "(\(column) IS NULL OR \(column) <> ? COLLATE NOCASE)",
                arguments: [text]
            )
        // Both sides folded in Swift rather than left to LIKE, which folds case for ASCII and
        // nothing else: to SQLite, Ø and ø are two unrelated characters, so a playlist called
        // "LØPE" was invisible to someone who typed "løpe" — and it is not only…
        case .contains:
            return CompiledFilter(
                sql: "swiftLowercaseString(\(column)) LIKE ? ESCAPE '\\'",
                arguments: ["%\(escaped.lowercased())%"]
            )
        case .doesNotContain:
            return CompiledFilter(
                sql: "(\(column) IS NULL OR swiftLowercaseString(\(column)) NOT LIKE ? ESCAPE '\\')",
                arguments: ["%\(escaped.lowercased())%"]
            )
        case .beginsWith:
            return CompiledFilter(
                sql: "swiftLowercaseString(\(column)) LIKE ? ESCAPE '\\'",
                arguments: ["\(escaped.lowercased())%"]
            )
        case .endsWith:
            return CompiledFilter(
                sql: "swiftLowercaseString(\(column)) LIKE ? ESCAPE '\\'",
                arguments: ["%\(escaped.lowercased())"]
            )
        default:
            return nil
        }
    }

    private func compileComparison(
        column: String,
        op: FilterOperator,
        value: Double
    ) -> CompiledFilter? {
        let comparison: String
        switch op {
        case .equals: comparison = "="
        case .notEquals: comparison = "<>"
        case .atLeast: comparison = ">="
        case .atMost: comparison = "<="
        case .greaterThan: comparison = ">"
        case .lessThan: comparison = "<"
        default: return nil
        }
        // "is not" has to keep the rows with nothing in the column: a song
        // with no rating is certainly not rated three stars, and leaving it
        // out would be a filter that quietly ignores half a library.
        if op == .notEquals {
            return CompiledFilter(
                sql: "(\(column) IS NULL OR \(column) <> ?)",
                arguments: [value]
            )
        }
        return CompiledFilter(sql: "\(column) \(comparison) ?", arguments: [value])
    }

    private func compileWithinDays(
        column: String,
        op: FilterOperator,
        days: Int
    ) -> CompiledFilter? {
        let clamped = min(max(0, days), FilterValue.maximumDays)
        let cutoff = Date().addingTimeInterval(-Double(clamped) * 24 * 60 * 60)
        switch op {
        case .inTheLast:
            return CompiledFilter(sql: "\(column) >= ?", arguments: [cutoff])
        case .notInTheLast:
            // Never played counts as not played lately, which is the whole
            // point of asking.
            return CompiledFilter(
                sql: "(\(column) IS NULL OR \(column) < ?)",
                arguments: [cutoff]
            )
        default:
            return nil
        }
    }

    private func compileDate(
        column: String,
        op: FilterOperator,
        date: Date
    ) -> CompiledFilter? {
        switch op {
        case .before:
            return CompiledFilter(sql: "\(column) < ?", arguments: [date])
        case .after:
            return CompiledFilter(sql: "\(column) > ?", arguments: [date])
        default:
            return nil
        }
    }
}
