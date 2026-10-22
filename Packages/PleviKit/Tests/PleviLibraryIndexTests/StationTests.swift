import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// What each radio draws on.
@Suite("Radio stations")
struct StationTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("ar1")
        try index.upsertArtists([Artist(id: artist, name: "Aurora Skies")], generation: 1)
        try index.upsertTracks([
            // Loved and played to death.
            Track(id: id("t1"), title: "Anthem", artistID: artist, year: 1985,
                  genre: "Rock", rating: StarRating(5), playCount: 40),
            // Loved, never played.
            Track(id: id("t2"), title: "Sleeper", artistID: artist, year: 1994,
                  genre: "Rock", rating: StarRating(4.5), playCount: nil),
            // Unloved, unplayed.
            Track(id: id("t3"), title: "Filler", artistID: artist, year: 2004,
                  genre: "Jazz", rating: nil, playCount: 0),
            // Middling — and below the rating floor every station now
            // applies, so it is absent from all of them. See
            // `RadioRatingFloorTests` for the floor itself.
            Track(id: id("t4"), title: "Middle", artistID: artist, year: 1988,
                  genre: "Jazz", rating: StarRating(2), playCount: 7),
            // Above the general floor every station holds to, but below Highly Rated's own, higher
            // bar — the exact boundary that bar exists to draw.
            Track(id: id("t5"), title: "Nearly", artistID: artist, year: 1975,
                  genre: "Pop", rating: StarRating(2.5), playCount: 40),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Everything means everything")
    func everything() throws {
        let index = try seeded()
        // Four of the five: "Middle" is rated below the floor. "Nearly", at
        // 2.5, clears the general floor even though it will not clear
        // Highly Rated's own, higher one.
        #expect(try index.stationTracks(.everything).count == 4)
    }

    @Test("Highly rated holds to its own line, above the general floor")
    func highlyRated() throws {
        let index = try seeded()
        let titles = Set(try index.stationTracks(.highlyRated).map(\.title))
        // 5 and 4.5 are in. "Nearly", at 2.5, clears the floor every other
        // station holds to but not Highly Rated's own line at 3 — the whole
        // point of the two being different numbers.
        #expect(titles == ["Anthem", "Sleeper"])
    }

    @Test("Deep cuts are the ones nobody plays")
    func deepCuts() throws {
        let index = try seeded()
        let titles = Set(try index.stationTracks(.deepCuts()).map(\.title))
        #expect(titles == ["Sleeper", "Filler"])
        // A wider net would catch the middling one too, but the rating floor
        // has already taken it.
        #expect(try index.stationTracks(.deepCuts(playsAtMost: 10)).count == 2)
    }

    @Test("A decade is ten years, not eleven")
    func decade() throws {
        let index = try seeded()
        let eighties = Set(try index.stationTracks(.decades([1980])).map(\.title))
        // "Middle" is also from 1988, but is below the rating floor.
        #expect(eighties == ["Anthem"])
        #expect(try index.stationTracks(.decades([1990])).map(\.title) == ["Sleeper"])
        #expect(try index.stationTracks(.decades([2010])).isEmpty)
    }

    @Test("Several decades play as one station")
    func decadesTogether() throws {
        let index = try seeded()
        let picked = Set(try index.stationTracks(.decades([1990, 2000])).map(\.title))
        #expect(picked == ["Sleeper", "Filler"])
        // Nothing chosen is nothing to play, not everything.
        #expect(try index.stationTracks(.decades([])).isEmpty)
    }

    @Test("A genre station is those genres")
    func genre() throws {
        let index = try seeded()
        #expect(Set(try index.stationTracks(.genres(["Jazz"])).map(\.title)) == ["Filler"])
        #expect(try index.stationTracks(.genres(["Jazz", "Rock"])).count == 3)
        #expect(try index.stationTracks(.genres([])).isEmpty)
    }

    @Test("A song with no year of its own uses its album's")
    func yearComesFromTheAlbum() throws {
        // How a real Plex library arrives: the record carries the year and
        // the genre, the songs carry neither.
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Daybreak", year: 1974, genre: "Folk"),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "Bare Song", albumID: id("al1")),
        ], generation: 1)
        try index.finishSync(generation: 1)

        #expect(try index.stationTracks(.decades([1970])).map(\.title) == ["Bare Song"])
        #expect(try index.stationTracks(.decades([1980])).isEmpty)
        #expect(try index.stationTracks(.genres(["Folk"])).map(\.title) == ["Bare Song"])
    }

    @Test("The limit is honoured")
    func limit() throws {
        let index = try seeded()
        #expect(try index.stationTracks(.everything, limit: 2).count == 2)
    }

    @Test("Offline, a station plays only what is on the phone")
    func offline() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t3", state: .done, fileName: "a.flac"))
        #expect(try index.stationTracks(.everything, downloadedOnly: true).map(\.title) == ["Filler"])
        #expect(try index.stationTracks(.highlyRated, downloadedOnly: true).isEmpty)
    }

    @Test("An empty station reports itself empty")
    func size() throws {
        let index = try seeded()
        #expect(try index.stationSize(.decades([1960])) == 0)
        #expect(try index.stationSize(.everything) == 1)
    }
}
