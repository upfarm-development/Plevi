import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

@Suite("Every song in the library")
struct SongListTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded(count: Int) throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums((0..<max(1, count / 12)).map { n in
            Album(
                id: id("al\(n)"), name: "Album \(n)", artistName: "Artist \(n % 900)",
                addedAt: Date().addingTimeInterval(-Double(n) * 3600)
            )
        }, generation: 1)
        try index.upsertTracks((0..<count).map { n in
            Track(
                id: id("t\(n)"),
                // Titles that do not arrive in order, so the sort is doing work.
                title: String(format: "%@ song %05d", ["Zebra", "Apple", "Moon", "Kite"][n % 4], n),
                albumName: "Album \(n / 12)", albumID: id("al\(n / 12)"),
                artistName: "Artist \(n % 900)",
                rating: n % 5 == 0 ? StarRating(4) : nil,
                playCount: n % 7
            )
        }, generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Sorted by title, and actually sorted")
    func sortsByTitle() throws {
        let index = try seeded(count: 40)
        let titles = try index.tracks(order: .alphabeticalByTitle).map(\.title)
        #expect(titles == titles.sorted { $0.lowercased() < $1.lowercased() })
        #expect(titles.first?.hasPrefix("Apple") == true)
    }

    @Test("Sorted by artist, then by title within each")
    func sortsByArtist() throws {
        let index = try seeded(count: 40)
        let rows = try index.tracks(order: .alphabeticalByArtist)
        let artists = rows.map { $0.artistName ?? "" }
        #expect(artists == artists.sorted { $0.lowercased() < $1.lowercased() })
    }

    @Test("Most played leaves out what has never been played")
    func mostPlayed() throws {
        let index = try seeded(count: 40)
        let rows = try index.tracks(order: .mostPlayed)
        #expect(rows.allSatisfy { ($0.playCount ?? 0) > 0 })
        #expect(rows.count < 40, "every song came back, so the filter did nothing")
        let counts = rows.map { $0.playCount ?? 0 }
        #expect(counts == counts.sorted(by: >))
    }

    @Test("Highest rated leaves out the unrated")
    func highestRated() throws {
        let index = try seeded(count: 40)
        let rows = try index.tracks(order: .highestRated)
        #expect(rows.allSatisfy { $0.rating != nil })
        #expect(rows.count == 8)
    }

    /// 61,287 songs is the real number in Alice's Music library, and a third of it is the
    /// comparison point.
    private static let wholeLibrary = 61_287
    private static let aThirdOfIt = 20_429

    /// One read of the whole track table and one sort, so the cost should follow the size of the
    /// library rather than the square of it.
    @Test("Tripling the library triples the reading, and does not square it")
    func handlesTheWholeLibrary() throws {
        let small = try seeded(count: Self.aThirdOfIt)
        let large = try seeded(count: Self.wholeLibrary)

        // Best of four, never the mean: contention only ever *adds* time, so the quickest of a few
        // attempts is the closest this machine got to the real cost.
        let clock = ContinuousClock()
        var best = [Int: Double]()
        for round in 0..<4 {
            for (count, index) in [(Self.aThirdOfIt, small), (Self.wholeLibrary, large)] {
                let started = clock.now
                let rows = try index.tracks(order: .alphabeticalByTitle)
                let elapsed = started.duration(to: clock.now).seconds
                #expect(rows.count == count)
                guard round > 0 else { continue }
                best[count] = min(best[count] ?? .infinity, elapsed)
            }
        }
        guard let smallest = best[Self.aThirdOfIt], let largest = best[Self.wholeLibrary],
              smallest > 0, largest.isFinite else {
            Issue.record("no round was measured, or the clock did not move")
            return
        }
        let growth = largest / smallest

        print("""
            SONGSCALE \(Self.aThirdOfIt) songs in \(String(format: "%.3f", smallest))s, \
            \(Self.wholeLibrary) in \(String(format: "%.3f", largest))s — \
            \(String(format: "%.1f", growth))x for 3x the songs
            """)
        #expect(
            growth < 6,
            """
            tripling the library cost \(String(format: "%.1f", growth))x the time \
            (\(String(format: "%.3f", smallest))s -> \(String(format: "%.3f", largest))s). \
            Reading and sorting the whole library has gone quadratic.
            """
        )
        #expect(largest < 8, "took \(String(format: "%.2f", largest))s")
    }
}

/// The song orders added so a filtered list can be looked through rather than
/// only saved, and the direction that turns any of them over.
@Suite("Sorting the songs list")
struct SongOrderDirectionTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// Deliberately not uniform: every field varies independently, so a sort
    /// on one of them cannot accidentally agree with a sort on another and
    /// pass a test it should fail.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Bravo", artistName: "Artist",
                  addedAt: Date(timeIntervalSince1970: 300)),
            Album(id: id("al2"), name: "Alpha", artistName: "Artist",
                  addedAt: Date(timeIntervalSince1970: 100)),
        ], generation: 1)
        try index.upsertTracks([
            track("t1", title: "Delta", album: "al1", disc: 1, no: 2,
                  year: 1999, duration: 300, played: 500, plays: 9, stars: 5),
            track("t2", title: "Alpha", album: "al1", disc: 1, no: 1,
                  year: 1971, duration: 100, played: 100, plays: 3, stars: 2),
            track("t3", title: "Charlie", album: "al2", disc: 1, no: 1,
                  year: 1985, duration: 200, played: 300, plays: 6, stars: 4),
            // Never played and never rated: the shapes that ask about playing
            // or rating must leave this out rather than file it at zero.
            track("t4", title: "Bravo", album: "al2", disc: 1, no: 2,
                  year: nil, duration: nil, played: nil, plays: 0, stars: nil),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func track(
        _ raw: String, title: String, album: String, disc: Int, no: Int,
        year: Int?, duration: Double?, played: Double?, plays: Int, stars: Double?
    ) -> Track {
        Track(
            id: id(raw), title: title,
            albumID: id(album), artistName: "Artist",
            trackNumber: no, discNumber: disc, duration: duration, year: year,
            rating: stars.flatMap(StarRating.init),
            playCount: plays,
            playedAt: played.map { Date(timeIntervalSince1970: $0) }
        )
    }

    @Test("Date played is newest first, and leaves out what was never played")
    func lastPlayed() throws {
        let index = try seeded()
        let rows = try index.tracks(order: .lastPlayed)
        #expect(rows.map(\.title) == ["Delta", "Charlie", "Alpha"])
        #expect(rows.contains { $0.title == "Bravo" } == false)
    }

    @Test("Reversing date played gives oldest first, still without the unplayed")
    func lastPlayedReversed() throws {
        let index = try seeded()
        let rows = try index.tracks(order: .lastPlayed, direction: .reverse)
        #expect(rows.map(\.title) == ["Alpha", "Charlie", "Delta"])
        // Reversing asks the same question backwards; it does not turn "never
        // played" into an answer.
        #expect(rows.contains { $0.title == "Bravo" } == false)
    }

    @Test("Z–A is A–Z backwards, over the same songs")
    func titleBothWays() throws {
        let index = try seeded()
        let forward = try index.tracks(order: .alphabeticalByTitle).map(\.title)
        let reverse = try index.tracks(order: .alphabeticalByTitle, direction: .reverse).map(\.title)
        #expect(forward == ["Alpha", "Bravo", "Charlie", "Delta"])
        #expect(reverse == forward.reversed())
    }

    @Test("Sorting by album keeps each record in its own running order")
    func byAlbum() throws {
        let index = try seeded()
        let rows = try index.tracks(order: .alphabeticalByAlbum)
        // Alpha the record before Bravo the record — and within each, the
        // track numbers rather than the titles.
        #expect(rows.map(\.title) == ["Charlie", "Bravo", "Alpha", "Delta"])
    }

    @Test("Play count runs both ways and never includes the unplayed")
    func playCountBothWays() throws {
        let index = try seeded()
        let most = try index.tracks(order: .mostPlayed).map(\.playCount)
        let fewest = try index.tracks(order: .mostPlayed, direction: .reverse).map(\.playCount)
        #expect(most == [9, 6, 3])
        #expect(fewest == [3, 6, 9])
    }

    @Test("Year and length sort on their own values, not on each other's")
    func yearAndLength() throws {
        let index = try seeded()
        // The fixture's year order and duration order disagree on purpose, so
        // one of these passing tells you nothing about the other.
        #expect(try index.tracks(order: .year).map(\.title) == ["Delta", "Charlie", "Alpha"])
        #expect(try index.tracks(order: .year, direction: .reverse).map(\.title)
                == ["Alpha", "Charlie", "Delta"])
        #expect(try index.tracks(order: .duration).map(\.title) == ["Delta", "Charlie", "Alpha"])
    }

    @Test("Every order names its two directions in words that fit what it measures")
    func directionsAreNamed() {
        #expect(LibraryIndex.SongOrder.alphabeticalByTitle.scale.label(.forward) == "A–Z")
        #expect(LibraryIndex.SongOrder.alphabeticalByTitle.scale.label(.reverse) == "Z–A")
        #expect(LibraryIndex.SongOrder.lastPlayed.scale.label(.forward) == "Newest first")
        #expect(LibraryIndex.SongOrder.lastPlayed.scale.label(.reverse) == "Oldest first")
        #expect(LibraryIndex.SongOrder.mostPlayed.scale.label(.forward) == "Highest first")
    }
}

/// Sorting the artists list, which until now could only be alphabetical.
@Suite("Sorting the artists list")
struct ArtistOrderTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("a"), name: "Aaron", rating: StarRating(3)),
            Artist(id: id("b"), name: "Beth", rating: StarRating(5)),
            Artist(id: id("c"), name: "Carl", rating: nil),
        ], generation: 1)
        try index.upsertAlbums([
            // Aaron: two records, the later play is the one that should count.
            Album(id: id("a1"), name: "One", artistName: "Aaron", artistID: id("a"),
                  addedAt: Date(timeIntervalSince1970: 10),
                  playedAt: Date(timeIntervalSince1970: 100), playCount: 2),
            Album(id: id("a2"), name: "Two", artistName: "Aaron", artistID: id("a"),
                  addedAt: Date(timeIntervalSince1970: 20),
                  playedAt: Date(timeIntervalSince1970: 500), playCount: 3),
            // Beth: one record, played between Aaron's two.
            Album(id: id("b1"), name: "Solo", artistName: "Beth", artistID: id("b"),
                  addedAt: Date(timeIntervalSince1970: 30),
                  playedAt: Date(timeIntervalSince1970: 300), playCount: 9),
            // Carl: never played at all.
            Album(id: id("c1"), name: "Quiet", artistName: "Carl", artistID: id("c"),
                  addedAt: Date(timeIntervalSince1970: 40)),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Alphabetical still works, both ways")
    func alphabetical() throws {
        let index = try seeded()
        #expect(try index.artists().map(\.name) == ["Aaron", "Beth", "Carl"])
        #expect(try index.artists(order: .alphabetical, direction: .reverse).map(\.name)
                == ["Carl", "Beth", "Aaron"])
    }

    @Test("Date played takes the artist's most recent record, not their first")
    func lastPlayed() throws {
        let index = try seeded()
        // Aaron leads on the strength of album Two at t=500, even though his
        // other record was played long before Beth's. Taking any album rather
        // than the latest would put Beth first.
        #expect(try index.artists(order: .lastPlayed).map(\.name) == ["Aaron", "Beth", "Carl"])
    }

    @Test("An artist who has never been played sorts last whichever way it runs")
    func neverPlayedSortsLast() throws {
        let index = try seeded()
        let forward = try index.artists(order: .lastPlayed).map(\.name)
        let reverse = try index.artists(order: .lastPlayed, direction: .reverse).map(\.name)
        #expect(forward.last == "Carl")
        // Not simply the reverse: Carl has no answer to give, so he stays at
        // the bottom rather than being promoted to the top of "oldest first".
        #expect(reverse == ["Beth", "Aaron", "Carl"])
    }

    @Test("Play count adds up an artist's records rather than taking one")
    func mostPlayed() throws {
        let index = try seeded()
        // Beth's single record at 9 beats Aaron's two at 2 + 3 = 5.
        #expect(try index.artists(order: .mostPlayed).map(\.name) == ["Beth", "Aaron", "Carl"])
    }

    @Test("Album count counts records, and rating reads the artist's own")
    func countsAndRating() throws {
        let index = try seeded()
        #expect(try index.artists(order: .albumCount).map(\.name).first == "Aaron")
        let rated = try index.artists(order: .highestRated).map(\.name)
        #expect(rated == ["Beth", "Aaron", "Carl"])
    }

    @Test("A filtered artist list sorts the same way an unfiltered one does")
    func filteredSortsToo() throws {
        let index = try seeded()
        var filter = LibraryFilter(subject: .artists)
        // `.title` is the artist's own name here — `.artistName` is about
        // the artist *of* a song or record and does not apply to a list of
        // artists at all.
        filter.root.children = [
            .rule(FilterRule(field: .title, op: .contains, value: .text("a")))
        ]
        // Aaron and Carl both contain "a"; ordered by play date Aaron leads.
        let rows = try index.artists(matching: filter, order: .lastPlayed).map(\.name)
        #expect(rows == ["Aaron", "Carl"])
    }
}

/// Sorting the albums list, which could previously only run one way.
@Suite("Sorting the albums list")
struct AlbumOrderDirectionTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("1"), name: "Bravo", artistName: "Zed",
                  addedAt: Date(timeIntervalSince1970: 100),
                  playedAt: Date(timeIntervalSince1970: 900), playCount: 1),
            Album(id: id("2"), name: "Alpha", artistName: "Yves",
                  addedAt: Date(timeIntervalSince1970: 300),
                  playedAt: Date(timeIntervalSince1970: 100), playCount: 7),
            Album(id: id("3"), name: "Charlie", artistName: "Xena",
                  addedAt: Date(timeIntervalSince1970: 200),
                  playedAt: nil, playCount: 0),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func names(_ index: LibraryIndex, _ f: AlbumFilter, _ d: LibraryIndex.SortDirection) throws -> [String] {
        try index.albums(filter: f, direction: d, offset: 0, limit: 50).map(\.name)
    }

    @Test("A–Z and Z–A over the same records")
    func alphabetical() throws {
        let index = try seeded()
        #expect(try names(index, .alphabeticalByName, .forward) == ["Alpha", "Bravo", "Charlie"])
        #expect(try names(index, .alphabeticalByName, .reverse) == ["Charlie", "Bravo", "Alpha"])
    }

    @Test("Date added runs newest first, and oldest first reversed")
    func added() throws {
        let index = try seeded()
        #expect(try names(index, .recentlyAdded, .forward) == ["Alpha", "Charlie", "Bravo"])
        #expect(try names(index, .recentlyAdded, .reverse) == ["Bravo", "Charlie", "Alpha"])
    }

    @Test("Date played keeps leaving out what was never played, either way")
    func played() throws {
        let index = try seeded()
        #expect(try names(index, .recentlyPlayed, .forward) == ["Bravo", "Alpha"])
        #expect(try names(index, .recentlyPlayed, .reverse) == ["Alpha", "Bravo"])
    }

    @Test("Sorting by artist reversed puts Z first without disturbing the tiebreak")
    func byArtist() throws {
        let index = try seeded()
        #expect(try names(index, .alphabeticalByArtist, .forward) == ["Charlie", "Alpha", "Bravo"])
        #expect(try names(index, .alphabeticalByArtist, .reverse) == ["Bravo", "Alpha", "Charlie"])
    }
}

/// Seconds as a `Double`, for the scale suite's ratios and its printing.
private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// What the car asks the library for, at the size a real library is.
@Suite("Reading a large library for the car")
struct CarPlayScaleTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// What the car really asks for: a library with a thousand and a half
    /// artists in it.
    private static let realLibrary = 1_500
    /// Four times that, to have something to compare it against. Nothing in a
    /// phone's library is this size; it exists to make the shape of the curve
    /// visible, not to model anything.
    private static let fourTimesIt = 6_000

    /// `count` artists and nothing else, which is all a plain alphabetical
    /// read has to work with.
    private func artistsAlone(_ count: Int) throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists((0..<count).map { n in
            Artist(id: id("ar\(n)"), name: String(format: "Artist %05d", n))
        }, generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    /// The same, each with a record behind them, so that the per-artist
    /// subqueries have something to do rather than answering nil immediately.
    private func artistsWithRecords(_ count: Int) throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists((0..<count).map { n in
            Artist(id: id("ar\(n)"), name: String(format: "Artist %05d", n))
        }, generation: 1)
        try index.upsertAlbums((0..<count).map { n in
            Album(
                id: id("al\(n)"), name: "Album \(n)",
                artistName: "Artist \(n)", artistID: id("ar\(n)"),
                playedAt: Date(timeIntervalSince1970: Double(n))
            )
        }, generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    /// What one `read` costs at each size, as the best of four timed rounds.
    private static let sampleTarget = 0.05

    private func bestTimes(
        _ fixtures: [(count: Int, index: LibraryIndex)],
        read: (LibraryIndex) throws -> [Artist]
    ) rethrows -> [Int: Double] {
        let clock = ContinuousClock()
        var reads = [Int: Int]()
        for fixture in fixtures {
            let started = clock.now
            let artists = try read(fixture.index)
            let one = started.duration(to: clock.now).seconds
            #expect(artists.count == fixture.count)
            reads[fixture.count] = min(max(Int(Self.sampleTarget / max(one, 1e-6)), 1), 200)
        }

        var best = [Int: Double]()
        for _ in 0..<4 {
            for fixture in fixtures {
                let count = reads[fixture.count] ?? 1
                let started = clock.now
                for _ in 0..<count { _ = try read(fixture.index) }
                let each = started.duration(to: clock.now).seconds / Double(count)
                best[fixture.count] = min(best[fixture.count] ?? .infinity, each)
            }
        }
        return best
    }

    /// A plain alphabetical read is one pass over the artist table and a sort, so quadrupling the
    /// artists should cost about four times as much.
    @Test("A thousand artists come back quickly enough to open a list on")
    func manyArtists() throws {
        let small = try artistsAlone(Self.realLibrary)
        let large = try artistsAlone(Self.fourTimesIt)

        let best = try bestTimes([
            (Self.realLibrary, small), (Self.fourTimesIt, large),
        ]) { try $0.artists() }
        // Never force-unwrapped: dropping the round count to watch the test
        // fail faster would otherwise turn a failing assertion into a crash.
        guard let smallest = best[Self.realLibrary], let largest = best[Self.fourTimesIt],
              smallest > 0, largest.isFinite else {
            Issue.record("no round was measured, or the clock did not move")
            return
        }
        let growth = largest / smallest

        print("""
            CARSCALE alphabetical: \(Self.realLibrary) artists in \
            \(String(format: "%.4f", smallest))s, \
            \(Self.fourTimesIt) in \(String(format: "%.4f", largest))s — \
            \(String(format: "%.1f", growth))x for 4x the artists
            """)
        #expect(
            growth < 8,
            """
            quadrupling the artists cost \(String(format: "%.1f", growth))x the time \
            (\(String(format: "%.4f", smallest))s -> \
            \(String(format: "%.4f", largest))s). \
            The read has picked up work it does once per artist.
            """
        )
        // The backstop a ratio cannot be: a read that became equally slower at
        // both sizes would keep the growth at 4x while the car sat waiting.
        // The real figure is two milliseconds, so this is catastrophe only.
        #expect(largest < 2, "took \(String(format: "%.2f", largest))s")
    }

    /// Sorting by last played orders on a correlated subquery — `SELECT MAX(album.playedAt) FROM
    /// album WHERE album.artistId = artist.id` — which runs once per artist.
    @Test("Sorting by a derived value stays a lookup, not a scan")
    func sortingByPlayDateStaysALookup() throws {
        let small = try artistsWithRecords(Self.realLibrary)
        let large = try artistsWithRecords(Self.fourTimesIt)

        let best = try bestTimes([
            (Self.realLibrary, small), (Self.fourTimesIt, large),
        ]) { try $0.artists(order: .lastPlayed) }
        // Never force-unwrapped: dropping the round count to watch the test
        // fail faster would otherwise turn a failing assertion into a crash.
        guard let smallest = best[Self.realLibrary], let largest = best[Self.fourTimesIt],
              smallest > 0, largest.isFinite else {
            Issue.record("no round was measured, or the clock did not move")
            return
        }
        let growth = largest / smallest

        print("""
            CARSCALE last played: \(Self.realLibrary) artists in \
            \(String(format: "%.4f", smallest))s, \
            \(Self.fourTimesIt) in \(String(format: "%.4f", largest))s — \
            \(String(format: "%.1f", growth))x for 4x the artists
            """)
        #expect(
            growth < 8,
            """
            quadrupling the artists cost \(String(format: "%.1f", growth))x the time \
            (\(String(format: "%.4f", smallest))s -> \
            \(String(format: "%.4f", largest))s). \
            The per-artist subquery is scanning the album table, not looking up \
            an index — check that album.artistId is still indexed.
            """
        )
        // As above: catastrophe only. The real figure is three milliseconds.
        #expect(largest < 2, "took \(String(format: "%.2f", largest))s")
    }
}
