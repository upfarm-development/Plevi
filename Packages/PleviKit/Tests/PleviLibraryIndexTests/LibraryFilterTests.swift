import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// Filters built out of nested rules, run against a library shaped like a
/// real one: the records carry the year and the genre, most songs carry
/// neither.
@Suite("Library filters")
struct LibraryFilterTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("ar1")
        try index.upsertArtists([Artist(id: artist, name: "Aurora Skies")], generation: 1)
        try index.upsertAlbums([
            Album(
                id: id("al1"), name: "Daybreak", artistName: "Aurora Skies", artistID: artist,
                year: 1974, genre: "Folk",
                addedAt: Date().addingTimeInterval(-40 * 24 * 60 * 60),
                rating: StarRating(5)
            ),
            Album(
                id: id("al2"), name: "Night Shift", artistName: "Aurora Skies", artistID: artist,
                year: 1994, genre: "Jazz",
                addedAt: Date().addingTimeInterval(-400 * 24 * 60 * 60),
                rating: StarRating(2)
            ),
        ], generation: 1)
        try index.upsertTracks([
            // No year, no genre of their own: the record carries both.
            Track(id: id("t1"), title: "Bare Song", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist,
                  duration: 200, codec: "flac", rating: StarRating(5), playCount: 12),
            Track(id: id("t2"), title: "Second Light", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist,
                  duration: 400, codec: "flac", rating: nil, playCount: 0),
            Track(id: id("t3"), title: "Night Drive", albumName: "Night Shift", albumID: id("al2"),
                  artistName: "Aurora Skies", artistID: artist,
                  duration: 150, codec: "mp3", rating: StarRating(3), playCount: 30),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func filter(
        _ subject: LibraryFilter.Subject,
        _ match: FilterGroup.Match = .all,
        _ rules: [FilterRule]
    ) -> LibraryFilter {
        LibraryFilter(
            subject: subject,
            root: FilterGroup(match: match, children: rules.map { .rule($0) })
        )
    }

    // MARK: The basics

    @Test("A filter with no rules is not a filter for nothing")
    func emptyMatchesEverything() throws {
        let index = try seeded()
        let empty = LibraryFilter(subject: .songs)
        #expect(empty.isEmpty)
        #expect(try index.count(matching: empty) == 3)
    }

    @Test("A rule about the record reaches songs that carry nothing themselves")
    func songsInheritTheirAlbum() throws {
        let index = try seeded()
        // Neither song on Daybreak has a year or a genre of its own.
        let seventies = filter(.songs, .all, [
            FilterRule(field: .year, op: .atLeast, value: .number(1970)),
            FilterRule(field: .year, op: .lessThan, value: .number(1980)),
        ])
        #expect(try index.tracks(matching: seventies).map(\.title).sorted()
                == ["Bare Song", "Second Light"])

        let folk = filter(.songs, .all, [
            FilterRule(field: .genre, op: .matches, value: .text("Folk")),
        ])
        #expect(try index.count(matching: folk) == 2)
    }

    @Test("Unrated is a question you can ask")
    func unrated() throws {
        let index = try seeded()
        let unrated = filter(.songs, .all, [
            FilterRule(field: .rating, op: .isNotSet),
        ])
        #expect(try index.tracks(matching: unrated).map(\.title) == ["Second Light"])

        let rated = filter(.songs, .all, [FilterRule(field: .rating, op: .isSet)])
        #expect(try index.count(matching: rated) == 2)
    }

    @Test("'Is not' keeps the songs that have nothing there at all")
    func isNotIncludesEmpties() throws {
        let index = try seeded()
        // An unrated song is certainly not a five-star song. Leaving it out
        // would be a filter that quietly ignores everything unrated.
        let notFive = filter(.songs, .all, [
            FilterRule(field: .rating, op: .notEquals, value: .number(5)),
        ])
        #expect(try index.tracks(matching: notFive).map(\.title).sorted()
                == ["Night Drive", "Second Light"])
    }

    // MARK: Text

    @Test("Text rules: is, contains, begins, ends, and their negatives")
    func textRules() throws {
        let index = try seeded()
        func titles(_ op: FilterOperator, _ text: String) throws -> [String] {
            try index.tracks(matching: filter(.songs, .all, [
                FilterRule(field: .title, op: op, value: .text(text)),
            ])).map(\.title).sorted()
        }
        #expect(try titles(.matches, "Bare Song") == ["Bare Song"])
        // Case is not the question anyone is asking.
        #expect(try titles(.matches, "bare song") == ["Bare Song"])
        #expect(try titles(.contains, "igh") == ["Night Drive", "Second Light"])
        #expect(try titles(.beginsWith, "Night") == ["Night Drive"])
        #expect(try titles(.endsWith, "Light") == ["Second Light"])
        #expect(try titles(.doesNotContain, "igh") == ["Bare Song"])
        #expect(try titles(.doesNotMatch, "Bare Song") == ["Night Drive", "Second Light"])
    }

    @Test("Case is not the question in any alphabet")
    func caseFoldingReachesPastAscii() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertTracks([
            Track(id: id("t1"), title: "LØPETUR"),
            Track(id: id("t2"), title: "Blåveis"),
            Track(id: id("t3"), title: "STRASSE"),
        ], generation: 1)
        try index.finishSync(generation: 1)

        func titles(_ op: FilterOperator, _ text: String) throws -> [String] {
            try index.tracks(matching: filter(.songs, .all, [
                FilterRule(field: .title, op: op, value: .text(text)),
            ])).map(\.title).sorted()
        }

        // SQLite's own LIKE folds ASCII and stops there, so each of these
        // used to find nothing: to it, Ø and ø are unrelated characters.
        #expect(try titles(.contains, "løpe") == ["LØPETUR"])
        #expect(try titles(.beginsWith, "løpetur") == ["LØPETUR"])
        #expect(try titles(.endsWith, "øpetur") == ["LØPETUR"])
        #expect(try titles(.contains, "BLÅ") == ["Blåveis"])
        // And the ASCII it always handled still works.
        #expect(try titles(.contains, "strasse") == ["STRASSE"])
        #expect(try titles(.doesNotContain, "løpe").sorted() == ["Blåveis", "STRASSE"].sorted())
    }

    @Test("A percent sign is a percent sign, not a wildcard")
    func wildcardsAreNotSmuggledIn() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertTracks([
            Track(id: id("t1"), title: "100% Cotton"),
            Track(id: id("t2"), title: "Something Else"),
        ], generation: 1)
        try index.finishSync(generation: 1)

        // If % were passed through to LIKE, this would match both.
        let literal = filter(.songs, .all, [
            FilterRule(field: .title, op: .contains, value: .text("%")),
        ])
        #expect(try index.tracks(matching: literal).map(\.title) == ["100% Cotton"])
    }

    @Test("A quote in a title is a quote, not a broken query")
    func quotesAreSafe() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertTracks([
            Track(id: id("t1"), title: "Rock 'n' Roll"),
            Track(id: id("t2"), title: "Quiet"),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let quoted = filter(.songs, .all, [
            FilterRule(field: .title, op: .contains, value: .text("'n'")),
        ])
        #expect(try index.tracks(matching: quoted).map(\.title) == ["Rock 'n' Roll"])

        // And the shape people worry about: text that tries to end the
        // statement and start another.
        let hostile = filter(.songs, .all, [
            FilterRule(field: .title, op: .contains, value: .text("'; DROP TABLE track; --")),
        ])
        #expect(try index.count(matching: hostile) == 0)
        // The table is still there, which is the point.
        #expect(try index.count(matching: LibraryFilter(subject: .songs)) == 2)
    }

    // MARK: Groups

    @Test("Any of these, all of those, nested")
    func nestedGroups() throws {
        let index = try seeded()
        // Five stars, and either folk or jazz.
        let nested = LibraryFilter(
            subject: .songs,
            root: FilterGroup(match: .all, children: [
                .rule(FilterRule(field: .rating, op: .atLeast, value: .number(3))),
                .group(FilterGroup(match: .any, children: [
                    .rule(FilterRule(field: .genre, op: .matches, value: .text("Folk"))),
                    .rule(FilterRule(field: .genre, op: .matches, value: .text("Jazz"))),
                ])),
            ])
        )
        #expect(try index.tracks(matching: nested).map(\.title).sorted()
                == ["Bare Song", "Night Drive"])
    }

    @Test("Match-any at the top means either rule will do")
    func anyAtTheTop() throws {
        let index = try seeded()
        let either = filter(.songs, .any, [
            FilterRule(field: .title, op: .matches, value: .text("Bare Song")),
            FilterRule(field: .codec, op: .matches, value: .text("mp3")),
        ])
        #expect(try index.tracks(matching: either).map(\.title).sorted()
                == ["Bare Song", "Night Drive"])
    }

    @Test("Three levels deep still means what it says")
    func threeLevels() throws {
        let index = try seeded()
        // (played more than 10 times) AND ( flac AND (five stars OR unrated) )
        let deep = LibraryFilter(
            subject: .songs,
            root: FilterGroup(match: .all, children: [
                .rule(FilterRule(field: .playCount, op: .greaterThan, value: .number(10))),
                .group(FilterGroup(match: .all, children: [
                    .rule(FilterRule(field: .codec, op: .matches, value: .text("flac"))),
                    .group(FilterGroup(match: .any, children: [
                        .rule(FilterRule(field: .rating, op: .equals, value: .number(5))),
                        .rule(FilterRule(field: .rating, op: .isNotSet)),
                    ])),
                ])),
            ])
        )
        #expect(try index.tracks(matching: deep).map(\.title) == ["Bare Song"])
    }

    @Test("An empty group inside a filter is ignored, not treated as a wall")
    func emptyGroupIgnored() throws {
        let index = try seeded()
        let withEmpty = LibraryFilter(
            subject: .songs,
            root: FilterGroup(match: .all, children: [
                .rule(FilterRule(field: .codec, op: .matches, value: .text("flac"))),
                .group(FilterGroup(match: .any, children: [])),
            ])
        )
        #expect(try index.count(matching: withEmpty) == 2)
    }

    @Test("A rule with nothing typed in it yet does not narrow anything")
    func halfWrittenRule() throws {
        let index = try seeded()
        // Someone has added a rule and not filled it in. It should not mean
        // "songs whose title is empty".
        let unfinished = filter(.songs, .all, [
            FilterRule(field: .title, op: .contains, value: .text("   ")),
        ])
        #expect(try index.count(matching: unfinished) == 3)
    }

    // MARK: Dates

    @Test("Added in the last month, and not in the last month")
    func dateRules() throws {
        let index = try seeded()
        let recent = filter(.songs, .all, [
            FilterRule(field: .dateAdded, op: .inTheLast, value: .days(60)),
        ])
        #expect(try index.tracks(matching: recent).map(\.title).sorted()
                == ["Bare Song", "Second Light"])

        let old = filter(.songs, .all, [
            FilterRule(field: .dateAdded, op: .notInTheLast, value: .days(60)),
        ])
        #expect(try index.tracks(matching: old).map(\.title) == ["Night Drive"])
    }

    @Test("Never played counts as not played lately")
    func neverPlayedIsNotRecent() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Untouched", addedAt: Date(), playedAt: nil),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "Never Heard", albumID: id("al1")),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let notLately = filter(.songs, .all, [
            FilterRule(field: .lastPlayed, op: .notInTheLast, value: .days(180)),
        ])
        #expect(try index.tracks(matching: notLately).map(\.title) == ["Never Heard"])
    }

    // MARK: Albums

    @Test("The same rules asked about records instead of songs")
    func albumSubject() throws {
        let index = try seeded()
        let goodRecords = filter(.albums, .all, [
            FilterRule(field: .rating, op: .atLeast, value: .number(4)),
        ])
        #expect(try index.albums(matching: goodRecords).map(\.name) == ["Daybreak"])
        #expect(try index.count(matching: goodRecords) == 1)

        let seventies = filter(.albums, .all, [
            FilterRule(field: .year, op: .lessThan, value: .number(1980)),
        ])
        #expect(try index.albums(matching: seventies).map(\.name) == ["Daybreak"])
    }

    @Test("Asking for songs of an album filter, or the other way round, gets nothing")
    func subjectMismatch() throws {
        let index = try seeded()
        let albumFilter = filter(.albums, .all, [
            FilterRule(field: .year, op: .atLeast, value: .number(1900)),
        ])
        #expect(try index.tracks(matching: albumFilter).isEmpty)

        let songFilter = filter(.songs, .all, [
            FilterRule(field: .title, op: .isSet),
        ])
        #expect(try index.albums(matching: songFilter).isEmpty)
    }

    @Test("A field the subject does not have is dropped, not guessed at")
    func fieldNotOnSubject() throws {
        let index = try seeded()
        // Codec belongs to a song. Asked of albums it cannot be answered, so
        // it narrows nothing rather than excluding everything.
        let onAlbums = filter(.albums, .all, [
            FilterRule(field: .codec, op: .matches, value: .text("flac")),
        ])
        #expect(try index.count(matching: onAlbums) == 2)
        #expect(!FilterField.codec.applies(to: .albums))
        #expect(!FilterField.fields(for: .albums).contains(.codec))
    }

    // MARK: Downloads

    @Test("Downloaded is a rule like any other")
    func downloadedRule() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t3", state: .done, fileName: "a.mp3"))

        let kept = filter(.songs, .all, [FilterRule(field: .downloaded, op: .isTrue)])
        #expect(try index.tracks(matching: kept).map(\.title) == ["Night Drive"])

        let notKept = filter(.songs, .all, [FilterRule(field: .downloaded, op: .isFalse)])
        #expect(try index.tracks(matching: notKept).map(\.title).sorted()
                == ["Bare Song", "Second Light"])

        // And on records: the album with a downloaded song in it.
        let recordsKept = filter(.albums, .all, [FilterRule(field: .downloaded, op: .isTrue)])
        #expect(try index.albums(matching: recordsKept).map(\.name) == ["Night Shift"])
    }

    @Test("Offline, a filter finds only what is on the phone")
    func downloadedOnly() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t3", state: .done, fileName: "a.mp3"))
        let everything = LibraryFilter(subject: .songs)
        #expect(try index.tracks(matching: everything, downloadedOnly: true).map(\.title)
                == ["Night Drive"])
        #expect(try index.count(matching: everything, downloadedOnly: true) == 1)
    }

    // MARK: Limits

    @Test("The limit is honoured")
    func limit() throws {
        let index = try seeded()
        #expect(try index.tracks(matching: LibraryFilter(subject: .songs), limit: 2).count == 2)
    }
}

/// The rules added because whole stars and a handful of fields were not
/// enough to ask a real library a real question.
@Suite("Finer filters")
struct FinerFilterTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func days(_ count: Double) -> Date {
        Date().addingTimeInterval(-count * 24 * 60 * 60)
    }

    /// A library with half-star ratings, files of different weights, and a
    /// record whose songs were last played on different days from the record
    /// itself.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(
                id: id("al1"), name: "Daybreak", artistName: "Aurora Skies",
                trackCount: 12,
                // The record was played yesterday, by way of one of its songs.
                playedAt: days(1),
                releaseTypes: [.album], recordLabel: "Harmonia"
            ),
            Album(
                id: id("al2"), name: "Sessions", artistName: "Aurora Skies",
                trackCount: 4,
                releaseTypes: [.ep, .live], recordLabel: "Nightjar"
            ),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "Half Past", albumName: "Daybreak", albumID: id("al1"),
                  bitRateKbps: 1_024, fileSize: 40_000_000,
                  rating: StarRating(2.5), playCount: 3, playedAt: days(1)),
            Track(id: id("t2"), title: "Exactly Two", albumName: "Daybreak", albumID: id("al1"),
                  bitRateKbps: 128, fileSize: 3_000_000,
                  rating: StarRating(2), playCount: 0),
            Track(id: id("t3"), title: "Nearly Four", albumName: "Sessions", albumID: id("al2"),
                  bitRateKbps: 320, fileSize: 9_000_000,
                  rating: StarRating(3.5), playCount: 9, playedAt: days(400)),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func songs(_ index: LibraryIndex, _ rules: [FilterRule]) throws -> [String] {
        let filter = LibraryFilter(
            subject: .songs,
            root: FilterGroup(match: .all, children: rules.map { .rule($0) })
        )
        return try index.tracks(matching: filter).map(\.title).sorted()
    }

    private func albums(_ index: LibraryIndex, _ rules: [FilterRule]) throws -> [String] {
        let filter = LibraryFilter(
            subject: .albums,
            root: FilterGroup(match: .all, children: rules.map { .rule($0) })
        )
        return try index.albums(matching: filter).map(\.name).sorted()
    }

    // MARK: Half stars

    @Test("Two and a half stars and up is a question that can be asked")
    func halfStarsAtLeast() throws {
        // The whole reason for this: the picker offered 1 to 5 and nothing
        // between, so a library rated in halves could not be asked about.
        let index = try seeded()
        #expect(try songs(index, [
            FilterRule(field: .rating, op: .atLeast, value: .number(2.5)),
        ]) == ["Half Past", "Nearly Four"])
    }

    @Test("More than two stars leaves out the songs rated exactly two")
    func moreThanIsNotAtLeast() throws {
        let index = try seeded()
        #expect(try songs(index, [
            FilterRule(field: .rating, op: .greaterThan, value: .number(2)),
        ]) == ["Half Past", "Nearly Four"])
        // And the difference between the two tests is real: "at least two"
        // keeps the two-star song that "more than two" drops.
        #expect(try songs(index, [
            FilterRule(field: .rating, op: .atLeast, value: .number(2)),
        ]) == ["Exactly Two", "Half Past", "Nearly Four"])
    }

    @Test("Ratings offer more than and less than")
    func ratingsOfferTheComparisons() {
        let offered = FilterOperator.operators(for: FilterField.rating)
        #expect(offered.contains(.greaterThan))
        #expect(offered.contains(.lessThan))
    }

    // MARK: A song's own played date

    @Test("Not played in a year asks about the song, not the record it is on")
    func lastPlayedIsTheSongs() throws {
        // The record "Daybreak" was played yesterday — by "Half Past".
        let index = try seeded()
        #expect(try songs(index, [
            FilterRule(field: .lastPlayed, op: .notInTheLast, value: .days(365)),
        ]) == ["Exactly Two", "Nearly Four"])
    }

    @Test("Never played is a question you can ask of a song")
    func neverPlayed() throws {
        let index = try seeded()
        #expect(try songs(index, [
            FilterRule(field: .lastPlayed, op: .isNotSet),
        ]) == ["Exactly Two"])
    }

    @Test("The wording says what the field means")
    func plainerWording() {
        #expect(FilterOperator.isNotSet.title(for: .lastPlayed) == "has never been played")
        #expect(FilterOperator.isSet.title(for: .lastPlayed) == "has been played")
        #expect(FilterOperator.isNotSet.title(for: .rating) == "is unrated")
    }

    @Test("Play count does not offer a question with a fixed answer")
    func playCountHidesIsSet() {
        // The index reads it through COALESCE(…, 0), so "is set" would be
        // true of every song in the library.
        let offered = FilterOperator.operators(for: FilterField.playCount)
        #expect(!offered.contains(.isSet))
        #expect(!offered.contains(.isNotSet))
    }

    // MARK: The new fields

    @Test("Songs can be asked about the file")
    func bitRateAndSize() throws {
        let index = try seeded()
        #expect(try songs(index, [
            FilterRule(field: .bitRate, op: .lessThan, value: .number(320)),
        ]) == ["Exactly Two"])
        #expect(try songs(index, [
            FilterRule(field: .fileSize, op: .atLeast, value: .number(10_000_000)),
        ]) == ["Half Past"])
    }

    @Test("Records can be asked about their length, label and kind")
    func albumFields() throws {
        let index = try seeded()
        #expect(try albums(index, [
            FilterRule(field: .trackCount, op: .greaterThan, value: .number(5)),
        ]) == ["Daybreak"])
        #expect(try albums(index, [
            FilterRule(field: .recordLabel, op: .matches, value: .text("Nightjar")),
        ]) == ["Sessions"])
        // A record can be several kinds at once, so this is a contains.
        #expect(try albums(index, [
            FilterRule(field: .releaseType, op: .contains, value: .text("live")),
        ]) == ["Sessions"])
    }

    @Test("A field is only offered where it means something")
    func fieldsBelongToASubject() {
        let songFields = FilterField.fields(for: .songs)
        let albumFields = FilterField.fields(for: .albums)
        // Bit rate is a property of a file, and a record is not one file.
        #expect(songFields.contains(.bitRate))
        #expect(!albumFields.contains(.bitRate))
        // A song has no track count: a record counts its songs, a song does
        // not count itself.
        #expect(albumFields.contains(.trackCount))
        #expect(!songFields.contains(.trackCount))

        // A song *does* have a release type, a label and a compilation flag, by way of the record
        // it came on — "songs from live albums" is a real question, and the songs query already
        // joins the album table to answer it.
        #expect(albumFields.contains(.releaseType))
        #expect(songFields.contains(.releaseType))
        #expect(songFields.contains(.recordLabel))
        #expect(songFields.contains(.compilation))

        // The record's own numbers, asked about from a song, and named so
        // they cannot be mistaken for the song's own.
        #expect(songFields.contains(.albumRating))
        #expect(songFields.contains(.criticRating))
        #expect(songFields.contains(.albumYear))
        // On an album page those would be two ways of saying one thing, so
        // only the reviewer's score is offered there.
        #expect(albumFields.contains(.criticRating))
        #expect(!albumFields.contains(.albumRating))
        #expect(!albumFields.contains(.albumYear))

        // File detail belongs to a file, so it is songs only.
        #expect(songFields.contains(.sampleRate))
        #expect(!albumFields.contains(.sampleRate))
        #expect(songFields.contains(.trackNumber))
        #expect(!albumFields.contains(.trackNumber))

        // An artist is a person, not a recording.
        let artistFields = FilterField.fields(for: .artists)
        #expect(!artistFields.contains(.criticRating))
        #expect(!artistFields.contains(.sampleRate))
    }
}

@Suite("Filtering artists")
struct ArtistFilterTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("a1"), name: "Aurora Skies", albumCount: 9,
                   isFavorite: true, rating: StarRating(5)),
            Artist(id: id("a2"), name: "Blue Harbour", albumCount: 2,
                   isFavorite: false, rating: StarRating(2)),
            Artist(id: id("a3"), name: "Cinder Lane", albumCount: 7,
                   isFavorite: false, rating: nil),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func matches(_ index: LibraryIndex, _ rules: [FilterRule]) throws -> [String] {
        let filter = LibraryFilter(
            subject: .artists,
            root: FilterGroup(match: .all, children: rules.map { .rule($0) })
        )
        return try index.artists(matching: filter).map(\.name)
    }

    @Test("Artists with more than a few records")
    func byAlbumCount() throws {
        let index = try seeded()
        #expect(try matches(index, [
            FilterRule(field: .albumCount, op: .greaterThan, value: .number(5)),
        ]) == ["Aurora Skies", "Cinder Lane"])
    }

    @Test("Artists you rated well, and the unrated left out")
    func byRating() throws {
        let index = try seeded()
        #expect(try matches(index, [
            FilterRule(field: .rating, op: .atLeast, value: .number(4)),
        ]) == ["Aurora Skies"])
        #expect(try matches(index, [
            FilterRule(field: .rating, op: .isNotSet),
        ]) == ["Cinder Lane"])
    }

    @Test("Favourites, and names")
    func byFavouriteAndName() throws {
        let index = try seeded()
        #expect(try matches(index, [FilterRule(field: .favourite, op: .isTrue)])
                == ["Aurora Skies"])
        #expect(try matches(index, [
            FilterRule(field: .title, op: .contains, value: .text("harbour")),
        ]) == ["Blue Harbour"])
    }

    @Test("Only what an artist actually has is offered")
    func fieldsAreHonest() {
        let fields = FilterField.fields(for: .artists)
        #expect(fields.contains(.title))
        #expect(fields.contains(.rating))
        #expect(fields.contains(.favourite))
        #expect(fields.contains(.albumCount))
        // Answered from the artist's records rather than from a column on
        // the artist — which is not the same as not being answerable, and
        // was treated as if it were until the subqueries went in.
        #expect(fields.contains(.dateAdded))
        #expect(fields.contains(.lastPlayed))
        #expect(fields.contains(.artistGenre))
        // The index keeps none of these for an artist, and nothing on their
        // records answers them either, so offering them would be offering
        // rules that can only ever find nothing.
        #expect(!fields.contains(.year))
        // `genre` is the song's or the record's own. An artist's is asked
        // through `artistGenre`, which offers only the questions that make
        // sense of a run of them.
        #expect(!fields.contains(.genre))
        #expect(!fields.contains(.duration))
        #expect(!fields.contains(.playCount))
        #expect(FilterOperator.operators(for: .artistGenre) == [.contains, .doesNotContain])
    }

    @Test("The running count agrees with the list")
    func countMatchesTheRows() throws {
        let index = try seeded()
        let filter = LibraryFilter(
            subject: .artists,
            root: FilterGroup(match: .all, children: [
                .rule(FilterRule(field: .albumCount, op: .atLeast, value: .number(7))),
            ])
        )
        #expect(try index.count(matching: filter) == 2)
        #expect(try index.artists(matching: filter).count == 2)
    }
}

/// The fields added when the filters were widened: a song asking about the record it came on, and
/// the file detail underneath it.
@Suite("Filtering on the record a song came from")
struct WiderFilterTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(
                id: id("acclaimed"), name: "Acclaimed", artistName: "One", year: 1971,
                rating: StarRating(2), criticRating: 9.4
            ),
            Album(
                id: id("loved"), name: "Loved", artistName: "Two", year: 2011,
                rating: StarRating(5), criticRating: 4
            ),
        ], generation: 1)
        try index.upsertTracks([
            // Its own stars are low and its record's are high, and the other
            // way round on the second — so a rule that confused the two
            // would come back with the wrong song rather than none.
            Track(id: id("t1"), title: "On Acclaimed", albumID: id("acclaimed"),
                  artistName: "One", trackNumber: 3, discNumber: 1, year: 1971,
                  originalYear: 1968, sampleRate: 44_100, bitDepth: 16,
                  rating: StarRating(1), playCount: 2),
            Track(id: id("t2"), title: "On Loved", albumID: id("loved"),
                  artistName: "Two", trackNumber: 11, discNumber: 2, year: 2011,
                  originalYear: 2011, sampleRate: 96_000, bitDepth: 24,
                  rating: StarRating(5), playCount: 40),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func titles(_ index: LibraryIndex, _ field: FilterField, _ op: FilterOperator, _ value: FilterValue) throws -> [String] {
        var filter = LibraryFilter()
        filter.subject = .songs
        filter.root = FilterGroup(match: .all, children: [
            .rule(FilterRule(field: field, op: op, value: value)),
        ])
        return try index.tracks(matching: filter, limit: 50).map(\.title)
    }

    @Test("A song can be asked about its record's critic score")
    func criticRating() throws {
        let index = try seeded()
        #expect(try titles(index, .criticRating, .atLeast, .number(8)) == ["On Acclaimed"])
    }

    @Test("The record's stars and the song's own stars are different questions")
    func albumRatingIsNotTheSongs() throws {
        let index = try seeded()
        // The record with five stars, whose song has one.
        #expect(try titles(index, .albumRating, .atLeast, .number(4.5)) == ["On Loved"])
        // The song with one star, whose record has five.
        #expect(try titles(index, .rating, .atMost, .number(1)) == ["On Acclaimed"])
    }

    @Test("Original year is asked separately from the year on the sleeve")
    func originalYear() throws {
        let index = try seeded()
        #expect(try titles(index, .originalYear, .lessThan, .number(1970)) == ["On Acclaimed"])
        // The same song's pressing is 1971, so the plain year finds nothing.
        #expect(try titles(index, .year, .lessThan, .number(1970)).isEmpty)
    }

    @Test("Where a song sits on its record can be asked about")
    func trackAndDiscNumber() throws {
        let index = try seeded()
        #expect(try titles(index, .trackNumber, .atMost, .number(5)) == ["On Acclaimed"])
        #expect(try titles(index, .discNumber, .equals, .number(2)) == ["On Loved"])
    }

    @Test("So can what the file actually is")
    func fileDetail() throws {
        let index = try seeded()
        #expect(try titles(index, .sampleRate, .greaterThan, .number(48_000)) == ["On Loved"])
        #expect(try titles(index, .bitDepth, .equals, .number(16)) == ["On Acclaimed"])
    }
}

@Suite("What the filter fields are called")
struct FilterFieldNamingTests {
    /// The same rule should read the same way wherever it was written. A
    /// field whose meaning depends on the subject says whose property it is;
    /// a field that always means the record's says so on every screen.
    @Test("A name never leaves its subject to be inferred from the screen")
    func namesCarryTheirSubject() {
        #expect(FilterField.rating.title(for: .songs) == "Track rating")
        #expect(FilterField.rating.title(for: .albums) == "Album rating")
        #expect(FilterField.rating.title(for: .artists) == "Artist rating")

        // The record's own score is called the same thing from either screen,
        // because it is the same thing.
        #expect(FilterField.criticRating.title(for: .songs) == "Album critic rating")
        #expect(FilterField.criticRating.title(for: .albums) == "Album critic rating")

        // And a song asking about its record's stars uses the very name the
        // album screen uses for them.
        #expect(FilterField.albumRating.title(for: .songs)
                == FilterField.rating.title(for: .albums))
        #expect(FilterField.albumYear.title(for: .songs)
                == FilterField.year.title(for: .albums))
        #expect(FilterField.albumPlayCount.title(for: .songs)
                == FilterField.playCount.title(for: .albums))
    }

    @Test("No two fields offered together share a name")
    func namesAreUniqueWithinASubject() {
        for subject in [LibraryFilter.Subject.songs, .albums, .artists] {
            let names = FilterField.fields(for: subject).map { $0.title(for: subject) }
            #expect(Set(names).count == names.count, "duplicate field name in \(subject)")
        }
    }

    @Test("Every offered field has a column behind it, and every unoffered one does not")
    func offeredFieldsAreAnswerable() {
        // A field on the menu that no column answers would be a rule that
        // silently finds nothing; one off the menu that a column *would*
        // answer is a question needlessly withheld.
        for subject in [LibraryFilter.Subject.songs, .albums, .artists] {
            for field in FilterField.allCases {
                let offered = field.applies(to: subject)
                var filter = LibraryFilter()
                filter.subject = subject
                let answerable = filter.column(for: field) != nil
                #expect(offered == answerable, "\(field) in \(subject): offered \(offered), answerable \(answerable)")
            }
        }
    }
}
