import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The artist page's favourites, on a library that holds an artist's own
/// records and the collections their songs were sold on — which is most
/// real libraries.
@Suite("Favourites on a compilation-heavy library")
struct ArtistFavouritesTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private var artist: MediaID { id("ar1") }

    /// One artist, two records: their own album from 1977 and a
    /// various-artists collection from 2003 that licensed two of its songs.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: artist, name: "Television")], generation: 1)
        try index.upsertAlbums([
            Album(
                id: id("al-own"), name: "Marquee Moon",
                artistName: "Television", artistID: artist, year: 1977
            ),
            Album(
                id: id("al-hits"), name: "Punk Essentials",
                artistName: "Various Artists", year: 2003, isCompilation: true
            ),
        ], generation: 1)
        try index.upsertTracks([
            track("t-own-1", "Marquee Moon", on: "al-own", rating: 4, number: 1),
            track("t-own-2", "Venus", on: "al-own", rating: 5, number: 2),
            track("t-own-3", "Friction", on: "al-own", rating: 3, number: 3),
            // The same two recordings, licensed onto the collection and
            // rated there too — which is how they both end up qualifying.
            track("t-hits-1", "Marquee Moon (2003 Remaster)", on: "al-hits", rating: 4, number: 7),
            track("t-hits-2", "Venus - Remastered", on: "al-hits", rating: 5, number: 8),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func track(
        _ raw: String, _ title: String, on album: String, rating: Double, number: Int
    ) -> Track {
        Track(
            id: id(raw), title: title,
            albumName: album == "al-own" ? "Marquee Moon" : "Punk Essentials",
            albumID: id(album),
            artistName: "Television", artistID: artist,
            trackNumber: number, discNumber: 1,
            year: album == "al-own" ? 1977 : 2003,
            rating: StarRating(rating)
        )
    }

    @Test("A song licensed onto a collection appears once")
    func oneRowPerSong() throws {
        let index = try seeded()
        let favourites = try index.favoriteTracks(forArtist: artist, limit: 10)
        #expect(favourites.map(\.title) == ["Venus", "Marquee Moon", "Friction"])
    }

    @Test("It is the artist's own record that survives, not the collection")
    func theRecordSurvives() throws {
        let index = try seeded()
        let favourites = try index.favoriteTracks(forArtist: artist, limit: 10)
        #expect(favourites.allSatisfy { $0.albumName == "Marquee Moon" })
        #expect(favourites.map(\.id.rawValue) == ["t-own-2", "t-own-1", "t-own-3"])
    }

    @Test("The limit counts songs rather than rows")
    func theLimitCountsSongs() throws {
        let index = try seeded()
        // Two, not one: without folding first, a limit of two would have
        // been spent on two copies of "Venus".
        let favourites = try index.favoriteTracks(forArtist: artist, limit: 2)
        #expect(favourites.map(\.title) == ["Venus", "Marquee Moon"])
    }

    @Test("The long list behind the shelf follows the same rule")
    func theLongListFolds() throws {
        let index = try seeded()
        let rated = try index.ratedTracks(forArtist: artist)
        #expect(rated.map(\.title) == ["Venus", "Marquee Moon", "Friction"])
    }

    @Test("A rating on the collection's copy is still the listener's word")
    func theHigherRatingWins() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: artist, name: "Television")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al-own"), name: "Marquee Moon", artistID: artist, year: 1977),
            Album(id: id("al-hits"), name: "Punk Essentials", artistName: "Various Artists", year: 2003),
        ], generation: 1)
        try index.upsertTracks([
            Track(
                id: id("t-own"), title: "Marquee Moon", albumName: "Marquee Moon",
                albumID: id("al-own"), artistID: artist, year: 1977, rating: StarRating(3)
            ),
            Track(
                id: id("t-hits"), title: "Marquee Moon", albumName: "Punk Essentials",
                albumID: id("al-hits"), artistID: artist, year: 2003, rating: StarRating(5)
            ),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let favourites = try index.favoriteTracks(forArtist: artist, limit: 10)
        #expect(favourites.map(\.id.rawValue) == ["t-hits"])
        #expect(favourites.first?.rating?.value == 5)
    }

    @Test("A live take is a different song and keeps its place")
    func performancesAreNotDuplicates() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: artist, name: "Television")], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "Marquee Moon", artistID: artist, rating: StarRating(4)),
            Track(id: id("t2"), title: "Marquee Moon (Live at the Old Waldorf)", artistID: artist, rating: StarRating(4)),
        ], generation: 1)
        try index.finishSync(generation: 1)

        #expect(try index.favoriteTracks(forArtist: artist, limit: 10).count == 2)
    }

    @Test("The copy on the phone is the one the shelf keeps")
    func theDownloadedCopySurvives() throws {
        let index = try seeded()
        // Only the collection's copy of "Venus" was ever downloaded. Without
        // asking, folding would keep the artist's own pressing and the shelf
        // would need the network to play a song already on the phone.
        try index.saveDownload(DownloadRecord(trackId: "t-hits-2", state: .done, fileName: "v.flac"))

        let favourites = try index.favoriteTracks(forArtist: artist, limit: 10)
        #expect(favourites.map(\.title) == ["Venus - Remastered", "Marquee Moon", "Friction"])
        // The other song was not downloaded either way, so it is unmoved.
        #expect(favourites[1].id.rawValue == "t-own-1")
    }

    @Test("Popular folds duplicate pressings the same way Favourites does")
    func topTracksFoldsDuplicatePressings() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: artist, name: "Television")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al-own"), name: "Marquee Moon", artistID: artist, year: 1977),
            Album(id: id("al-hits"), name: "Punk Essentials", artistName: "Various Artists", year: 2003),
        ], generation: 1)
        try index.upsertTracks([
            // The song most heard is on its own record — the studio copy —
            // but the same recording was also licensed onto a compilation,
            // where it has a play count of its own.
            Track(
                id: id("t-own"), title: "Marquee Moon", albumName: "Marquee Moon",
                albumID: id("al-own"), artistID: artist, trackNumber: 1, playCount: 40
            ),
            Track(
                id: id("t-hits"), title: "Marquee Moon (2003 Remaster)", albumName: "Punk Essentials",
                albumID: id("al-hits"), artistID: artist, trackNumber: 7, playCount: 12
            ),
            Track(
                id: id("t-other"), title: "Venus", albumName: "Marquee Moon",
                albumID: id("al-own"), artistID: artist, trackNumber: 2, playCount: 5
            ),
        ], generation: 1)
        try index.finishSync(generation: 1)

        // One row for the shared recording, not two — without folding, the
        // studio and compilation copies would each hold half its total plays
        // and the shelf would show the artist's best-known song twice.
        let top = try index.topTracks(forArtist: artist, limit: 10)
        #expect(top.map(\.title) == ["Marquee Moon", "Venus"])
        #expect(top.map(\.id.rawValue) == ["t-own", "t-other"])
    }

    @Test("A song with no record at all still comes back")
    func tracksWithoutAlbumsSurvive() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: artist, name: "Television")], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "Little Johnny Jewel", artistID: artist, rating: StarRating(4)),
        ], generation: 1)
        try index.finishSync(generation: 1)

        #expect(try index.favoriteTracks(forArtist: artist, limit: 10).map(\.title) == ["Little Johnny Jewel"])
    }
}

/// Seconds as a `Double`, for the scale suites' ratios and their printing.
private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// The favourites read has no `LIMIT` of its own — the limit counts songs, and how many rows a song
/// takes up is not known until the rows are in hand.
@Suite("A whole library filed under one artist")
struct ArtistFavouritesScaleTests {
    /// A compilation-heavy library can file most of itself under one name.
    private static let worstArtist = 20_000
    /// Still far more than the thousand-row first draw, so the shelf's work
    /// is bounded here too and the two sizes are honestly comparable.
    private static let aQuarterOfIt = 5_000

    /// An artist with `count` rated songs spread over 800 collections.
    private static func index(
        ratedSongs count: Int
    ) throws -> (index: LibraryIndex, artist: MediaID) {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = MediaID(server: server, rawValue: "va")
        try index.upsertArtists([Artist(id: artist, name: "Various Artists")], generation: 1)

        let albums = (0..<800).map { i in
            Album(
                id: MediaID(server: server, rawValue: "al\(i)"),
                name: "Collection \(i)", artistName: "Various Artists",
                year: 1970 + (i % 50), isCompilation: true
            )
        }
        try index.upsertAlbums(albums, generation: 1)

        // A thousand titles and eight hundred collections at both sizes, so the folding has real
        // work to do rather than 20,000 distinct keys — the large fixture holds twenty copies of
        // each song where the small one holds five.
        let tracks = (0..<count).map { i in
            Track(
                id: MediaID(server: server, rawValue: "t\(i)"),
                title: "Song \(i % 1_000)",
                albumName: "Collection \(i % 800)",
                albumID: MediaID(server: server, rawValue: "al\(i % 800)"),
                artistName: "Various Artists", artistID: artist,
                trackNumber: i % 20, discNumber: 1,
                duration: 180 + Double(i % 120),
                year: 1970 + (i % 50),
                rating: StarRating(3)
            )
        }
        try index.upsertTracks(tracks, generation: 1)
        try index.finishSync(generation: 1)
        return (index, artist)
    }

    /// The shelf asks for ten songs, draws a thousand rows, and never sees the rest — so what it
    /// costs is the draw, and the draw is the same whether the artist has five thousand songs or
    /// twenty thousand.
    @Test("The shelf costs the same on a huge artist as on a merely large one")
    func theDrawIsBounded() throws {
        let large = try Self.index(ratedSongs: Self.worstArtist)
        let small = try Self.index(ratedSongs: Self.aQuarterOfIt)

        let clock = ContinuousClock()
        var best = [Int: Double]()
        // Both sizes every round rather than one size measured to death and
        // then the next, so a burst of load lands on both of them.
        for round in 0..<4 {
            for (count, fixture) in [(Self.aQuarterOfIt, small), (Self.worstArtist, large)] {
                let started = clock.now
                let shelf = try fixture.index.favoriteTracks(
                    forArtist: fixture.artist, limit: 10
                )
                let elapsed = started.duration(to: clock.now).seconds
                #expect(shelf.count == 10)
                // The first read of each pays for warming the database's
                // caches, which is a cost of the fixture and not of the draw.
                guard round > 0 else { continue }
                best[count] = min(best[count] ?? .infinity, elapsed)
            }
        }

        // Never force-unwrapped: dropping the round count to watch the test
        // fail faster would otherwise turn a failing assertion into a crash
        // with no message on it.
        guard let smallest = best[Self.aQuarterOfIt], let largest = best[Self.worstArtist],
              smallest > 0, largest.isFinite else {
            Issue.record("no round was measured, or the clock did not move")
            return
        }
        let growth = largest / smallest
        print("""
            SCALE shelf on \(Self.aQuarterOfIt) songs in \
            \(String(format: "%.3f", smallest))s, on \
            \(Self.worstArtist) in \(String(format: "%.3f", largest))s — \
            \(String(format: "%.1f", growth))x for 4x the songs
            """)
        #expect(
            growth < 2,
            """
            quadrupling the artist cost \(String(format: "%.1f", growth))x the time \
            (\(String(format: "%.3f", smallest))s -> \
            \(String(format: "%.3f", largest))s). \
            The shelf is reading the whole artist, not a bounded draw.
            """
        )

        // The backstop a ratio cannot be: a read that became equally slower at every size would
        // keep the growth flat while the artist page sat there blank.
        #expect(largest < 8, "took \(String(format: "%.2f", largest))s")

        // And the long list still gets everything it asked for.
        #expect(try large.index.ratedTracks(forArtist: large.artist).count == 500)
    }
}
