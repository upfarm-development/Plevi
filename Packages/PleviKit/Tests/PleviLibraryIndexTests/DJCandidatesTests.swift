import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The local-index candidate pools DJ Era, Purist, Deep Cuts, Gold and Fresh draw from — each a
/// thin wrapper over `stationTracks`/ `tracks(matching:)`, so what these tests actually prove is
/// that the exclusion filter and the per-strategy…
@Suite("DJ candidate pools")
struct DJCandidatesTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("ar1")
        try index.upsertArtists([Artist(id: artist, name: "Aurora Skies")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1970"), name: "Seventies Record", artistID: artist, year: 1975),
            Album(id: id("al1990"), name: "Nineties Record", artistID: artist, year: 1994),
            Album(id: id("alFresh"), name: "New Arrival", artistID: artist, year: 2024, addedAt: Date()),
            Album(id: id("alOld"), name: "Old Arrival", artistID: artist, year: 2020,
                  addedAt: Date().addingTimeInterval(-400 * 24 * 60 * 60)),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1975a"), title: "Seventies A", albumID: id("al1970"), artistID: artist,
                  year: 1975, genre: "Rock", rating: StarRating(5), playCount: 40),
            Track(id: id("t1975b"), title: "Seventies B", albumID: id("al1970"), artistID: artist,
                  year: 1975, genre: "Jazz", rating: nil, playCount: 0),
            Track(id: id("t1975c"), title: "Seventies C — low rated", albumID: id("al1970"), artistID: artist,
                  year: 1975, genre: "Rock", rating: StarRating(2), playCount: 1),
            Track(id: id("t1994"), title: "Nineties", albumID: id("al1990"), artistID: artist,
                  year: 1994, genre: "Rock", rating: StarRating(3.5), playCount: 10),
            Track(id: id("tfresh"), title: "Fresh", albumID: id("alFresh"), artistID: artist,
                  genre: "Electronic", rating: nil, playCount: 0),
            Track(id: id("told"), title: "Old", albumID: id("alOld"), artistID: artist,
                  genre: "Electronic", rating: nil, playCount: 0),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Era candidates are limited to the requested decade")
    func eraCandidates() throws {
        let index = try seeded()
        let seventies = try index.djEraCandidates(decade: 1970, excluding: [], limit: 10)
        // t1975c is below the general rating floor (2 stars) and is
        // excluded by stationTracks itself, not by this layer.
        #expect(Set(seventies.map(\.id)) == [id("t1975a"), id("t1975b")])
    }

    @Test("The exclusion set is honoured")
    func exclusionIsHonoured() throws {
        let index = try seeded()
        let seventies = try index.djEraCandidates(decade: 1970, excluding: [id("t1975a")], limit: 10)
        #expect(!seventies.contains { $0.id == id("t1975a") })
        #expect(seventies.contains { $0.id == id("t1975b") })
    }

    @Test("Genre candidates match any of the given genre spellings")
    func genreCandidates() throws {
        let index = try seeded()
        let rock = try index.djGenreCandidates(matchingAnyOf: ["Rock"], excluding: [], limit: 10)
        #expect(Set(rock.map(\.id)) == [id("t1975a"), id("t1994")])
    }

    @Test("An empty genre list returns nothing rather than everything")
    func emptyGenreListReturnsNothing() throws {
        let index = try seeded()
        #expect(try index.djGenreCandidates(matchingAnyOf: [], excluding: [], limit: 10).isEmpty)
    }

    @Test("Deep Cuts respects the given play-count threshold")
    func deepCutsThreshold() throws {
        let index = try seeded()
        let barely = try index.djDeepCutsCandidates(playsAtMost: 2, excluding: [], limit: 10)
        let ids = Set(barely.map(\.id))
        #expect(ids.contains(id("t1975b")), "never played")
        #expect(!ids.contains(id("t1975a")), "played 40 times")
        #expect(!ids.contains(id("t1994")), "played 10 times")
    }

    @Test("Deep Cuts still holds to the general rating floor — barely played is not the same as badly rated")
    func deepCutsStillRespectsGeneralFloor() throws {
        let index = try seeded()
        let barely = try index.djDeepCutsCandidates(playsAtMost: 2, excluding: [], limit: 10)
        // t1975c is played only once, which would qualify on play count alone, but it is rated 2
        // stars — below the general floor every station already applies before Deep Cuts' own
        // threshold narrows it further.
        #expect(!barely.contains { $0.id == id("t1975c") })
    }

    @Test("Gold applies its own, stricter threshold rather than the general floor")
    func goldStricterThreshold() throws {
        let index = try seeded()
        let gold = try index.djGoldCandidates(atLeast: 4.0, excluding: [], limit: 10)
        // Only the 5-star track clears 4.0; the 3.5-star track clears the
        // general 2.5 floor but not Gold's own line.
        #expect(gold.map(\.id) == [id("t1975a")])
    }

    @Test("Gold requires an explicit rating — unrated does not pass, unlike every other floor")
    func goldExcludesUnrated() throws {
        let index = try seeded()
        let gold = try index.djGoldCandidates(atLeast: 2.5, excluding: [], limit: 10)
        // At 2.5 every rated-and-above track (5, 3.5) clears the line, but
        // the unrated ones (t1975b, tfresh, told) do not — unlike the
        // general floor, which would have let silence through.
        #expect(Set(gold.map(\.id)) == [id("t1975a"), id("t1994")])
    }

    @Test("Gold finds the rated songs in a library where most are unrated")
    func goldInAMostlyUnratedLibrary() throws {
        // The pool used to be a random sample of the whole library filtered
        // for rating in Swift, so a batch came back short — or empty — when
        // few songs were rated.
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("ar1")
        try index.upsertArtists([Artist(id: artist, name: "Aurora Skies")], generation: 1)
        try index.upsertAlbums([Album(id: id("al"), name: "Record", artistID: artist, year: 2001)], generation: 1)
        var tracks = (0..<600).map {
            Track(id: id("plain\($0)"), title: "Plain \($0)", albumID: id("al"), artistID: artist, rating: nil)
        }
        tracks += (0..<6).map {
            Track(id: id("gold\($0)"), title: "Gold \($0)", albumID: id("al"), artistID: artist, rating: StarRating(4.5))
        }
        try index.upsertTracks(tracks, generation: 1)
        try index.finishSync(generation: 1)

        for _ in 0..<5 {
            let gold = try index.djGoldCandidates(atLeast: 4.0, excluding: [], limit: 6)
            #expect(Set(gold.map(\.id)) == Set((0..<6).map { id("gold\($0)") }))
        }
        let fewer = try index.djGoldCandidates(atLeast: 4.0, excluding: [id("gold0")], limit: 6)
        #expect(fewer.count == 5)
        #expect(!fewer.contains { $0.id == id("gold0") })
    }

    @Test("Fresh finds songs on a recently added album, and only those")
    func freshCandidates() throws {
        let index = try seeded()
        let fresh = try index.djFreshCandidates(addedWithinDays: 90, excluding: [], limit: 10)
        #expect(fresh.map(\.id) == [id("tfresh")])
    }

    @Test("Fresh excludes an album added outside the window")
    func freshExcludesOldArrival() throws {
        let index = try seeded()
        let fresh = try index.djFreshCandidates(addedWithinDays: 90, excluding: [], limit: 10)
        #expect(!fresh.contains { $0.id == id("told") })
    }

    @Test("Fresh holds to the general rating floor, same as every other DJ")
    func freshRespectsGeneralFloor() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("floorTest")
        try index.upsertArtists([Artist(id: artist, name: "Floor Test")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("alFloor"), name: "New Release", artistID: artist, year: 2024, addedAt: Date()),
        ], generation: 1)
        try index.upsertTracks([
            // Unrated — the general floor lets this through, the same as
            // an album's worth of songs nobody has rated yet always does.
            Track(id: id("tUnrated"), title: "Unrated", albumID: id("alFloor"), artistID: artist,
                  genre: "Pop", rating: nil, playCount: 0),
            // Explicitly rated, and above the line.
            Track(id: id("tGoodRating"), title: "Good Rating", albumID: id("alFloor"), artistID: artist,
                  genre: "Pop", rating: StarRating(3), playCount: 0),
            // Explicitly rated below 2.5 — the one case the floor exists to catch, and the one gap
            // this candidate pool used to have: every other DJ's pool goes through `stationTracks`,
            // which bakes the floor in; this one queries `tracks(matching:)`…
            Track(id: id("tBadRating"), title: "Bad Rating", albumID: id("alFloor"), artistID: artist,
                  genre: "Pop", rating: StarRating(1.5), playCount: 0),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let fresh = try index.djFreshCandidates(addedWithinDays: 30, excluding: [], limit: 10)
        #expect(Set(fresh.map(\.id)) == [id("tUnrated"), id("tGoodRating")])
    }

    /// The bug, as a test: four albums added within the window, the newest a few minutes ahead of
    /// the rest — the exact shape that put every one of Fresh's picks on the single newest record
    /// before this was fixed.
    @Test("Fresh draws from more than just the single newest album")
    func freshDrawsAcrossMultipleAlbums() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("prolific")
        try index.upsertArtists([Artist(id: artist, name: "Prolific Artist")], generation: 1)
        let albums = (1...4).map { n in
            Album(
                id: id("alM\(n)"), name: "Album \(n)", artistID: artist, year: 2024,
                addedAt: Date().addingTimeInterval(-Double(4 - n) * 60 * 60)
            )
        }
        try index.upsertAlbums(albums, generation: 1)
        let tracks = (1...4).flatMap { n in
            (1...3).map { t in
                Track(
                    id: id("tM\(n)-\(t)"), title: "Album \(n) Track \(t)", albumID: id("alM\(n)"), artistID: artist,
                    genre: "Pop", rating: nil, playCount: 0
                )
            }
        }
        try index.upsertTracks(tracks, generation: 1)
        try index.finishSync(generation: 1)

        // Twenty independent draws of two, from a pool of four equally sized, equally eligible
        // albums.
        var albumsSeen: Set<MediaID> = []
        for _ in 0..<20 {
            let draw = try index.djFreshCandidates(addedWithinDays: 1, excluding: [], limit: 2)
            albumsSeen.formUnion(draw.compactMap(\.albumID))
        }
        #expect(albumsSeen.count > 1)
    }

    @Test("The fallback pool draws broadly and respects exclusions")
    func fallbackPool() throws {
        let index = try seeded()
        let pool = try index.djFallbackPool(excluding: [id("t1975a")], limit: 100)
        #expect(!pool.contains { $0.id == id("t1975a") })
        #expect(pool.count >= 2)
    }

    @Test("A limit narrower than what is available is respected")
    func limitIsRespected() throws {
        let index = try seeded()
        let capped = try index.djEraCandidates(decade: 1970, excluding: [], limit: 1)
        #expect(capped.count == 1)
    }
}
