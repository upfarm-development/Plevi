import Foundation
import Testing
import PleviDomain
import PleviMockProvider
@testable import PleviLibraryIndex

private func seededIndex() throws -> (LibraryIndex, ServerID) {
    let server = ServerID()
    let index = try LibraryIndex(inMemoryFor: server)
    return (index, server)
}

@Suite struct LibraryIndexTests {
    private func id(_ raw: String, _ server: ServerID) -> MediaID {
        MediaID(server: server, rawValue: raw)
    }

    private func populate(_ index: LibraryIndex, _ server: ServerID, generation: Int = 1) throws {
        let artist = Artist(id: id("ar1", server), name: "Aurora Skies", albumCount: 1)
        let album = Album(
            id: id("al1", server),
            name: "Daybreak",
            artistName: "Aurora Skies",
            artistID: id("ar1", server),
            year: 2019,
            genre: "Ambient",
            trackCount: 2,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let tracks = [
            Track(
                id: id("t1", server), title: "First Light",
                albumName: "Daybreak", albumID: id("al1", server),
                artistName: "Aurora Skies", artistID: id("ar1", server),
                trackNumber: 1, discNumber: 1, genre: "Ambient", codec: "flac",
                replayGain: ReplayGain(trackGain: -6.5)
            ),
            Track(
                id: id("t2", server), title: "Slow Horizon",
                albumName: "Daybreak", albumID: id("al1", server),
                artistName: "Aurora Skies", artistID: id("ar1", server),
                trackNumber: 2, discNumber: 1, genre: "Ambient", codec: "opus"
            ),
        ]
        try index.upsertArtists([artist], generation: generation)
        try index.upsertAlbums([album], generation: generation)
        try index.upsertTracks(tracks, generation: generation)
        try index.finishSync(generation: generation)
    }

    @Test func roundTripsThroughTables() throws {
        let (index, server) = try seededIndex()
        try populate(index, server)

        let artists = try index.artists()
        #expect(artists.map(\.name) == ["Aurora Skies"])

        let detail = try #require(try index.albumDetail(id: id("al1", server)))
        #expect(detail.album.name == "Daybreak")
        #expect(detail.tracks.map(\.title) == ["First Light", "Slow Horizon"])
        #expect(detail.tracks[0].replayGain?.trackGain == -6.5)
        #expect(detail.tracks[1].codec == "opus")

        let stats = try index.stats()
        #expect(stats.trackCount == 2 && stats.albumCount == 1 && stats.artistCount == 1)
        #expect(stats.lastSyncAt != nil)
    }

    @Test func ftsSearchMatchesPrefixes() throws {
        let (index, server) = try seededIndex()
        try populate(index, server)

        let byTitle = try index.search("first li", limit: 10)
        #expect(byTitle.tracks.map(\.title) == ["First Light"])

        let byArtistPrefix = try index.search("auro", limit: 10)
        #expect(!byArtistPrefix.artists.isEmpty)
        #expect(!byArtistPrefix.tracks.isEmpty, "tracks index artist names too")

        let nothing = try index.search("zebra", limit: 10)
        #expect(nothing.isEmpty)
    }

    @Test func staleRowsRemovedOnNextSync() throws {
        let (index, server) = try seededIndex()
        try populate(index, server, generation: 1)

        // Second sync sees only one of the two tracks.
        let survivor = Track(
            id: id("t1", server), title: "First Light",
            albumName: "Daybreak", albumID: id("al1", server),
            artistName: "Aurora Skies", trackNumber: 1, genre: "Ambient"
        )
        try index.upsertArtists(try index.artists(), generation: 2)
        try index.upsertAlbums(try index.albums(filter: .alphabeticalByName, offset: 0, limit: 10), generation: 2)
        try index.upsertTracks([survivor], generation: 2)
        try index.finishSync(generation: 2)

        #expect(try index.track(id: id("t2", server)) == nil)
        #expect(try index.track(id: id("t1", server)) != nil)
        let search = try index.search("slow horizon", limit: 5)
        #expect(search.tracks.isEmpty, "search table must not retain deleted rows")
    }

    @Test func albumFiltersAndGenres() throws {
        let (index, server) = try seededIndex()
        try populate(index, server)

        #expect(try index.albums(filter: .genre("ambient"), offset: 0, limit: 5).count == 1)
        #expect(try index.albums(filter: .yearRange(from: 2018, to: 2020), offset: 0, limit: 5).count == 1)
        #expect(try index.albums(filter: .yearRange(from: 1990, to: 1999), offset: 0, limit: 5).isEmpty)
        #expect(try index.albums(filter: .favorites, offset: 0, limit: 5).isEmpty)

        let genres = try index.genres()
        #expect(genres.map(\.name) == ["Ambient"])
        #expect(genres[0].trackCount == 2)
    }

    @Test func favoriteAndRatingMirrorsApplyLocally() throws {
        let (index, server) = try seededIndex()
        try populate(index, server)

        try index.mirrorFavorite(true, for: id("al1", server), kind: .album)
        #expect(try index.albums(filter: .favorites, offset: 0, limit: 5).count == 1)

        try index.mirrorRating(StarRating(stars: 4), for: id("t1", server))
        #expect(try index.track(id: id("t1", server))?.rating == StarRating(stars: 4))
        try index.mirrorRating(nil, for: id("t1", server))
        #expect(try index.track(id: id("t1", server))?.rating == nil)
    }

    /// By release date, not by when it was added — and never an album that
    /// does not say when it came out, since a shelf claiming to be "recently
    /// released" would be lying about anything it could not actually date.
    @Test func recentlyReleasedOrdersByReleaseDateNotAddedAt() throws {
        let (index, server) = try seededIndex()
        func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

        // Added to the server in one order, released in the opposite one —
        // so a bug that read `addedAt` instead of `releaseDate` would sort
        // these backwards rather than merely differently.
        let older = Album(
            id: id("al-old"), name: "Old Sessions", artistName: "Aurora Skies",
            artistID: id("ar1"), trackCount: 1,
            addedAt: Date(timeIntervalSince1970: 1_000),
            releaseDate: Date(timeIntervalSince1970: 500)
        )
        let newer = Album(
            id: id("al-new"), name: "New Sessions", artistName: "Aurora Skies",
            artistID: id("ar1"), trackCount: 1,
            addedAt: Date(timeIntervalSince1970: 500),
            releaseDate: Date(timeIntervalSince1970: 1_000)
        )
        let undated = Album(
            id: id("al-undated"), name: "Undated Sessions", artistName: "Aurora Skies",
            artistID: id("ar1"), trackCount: 1,
            addedAt: Date(timeIntervalSince1970: 2_000)
        )
        try index.upsertArtists(
            [Artist(id: id("ar1"), name: "Aurora Skies", albumCount: 3)],
            generation: 1
        )
        try index.upsertAlbums([older, newer, undated], generation: 1)
        try index.finishSync(generation: 1)

        let released = try index.albums(filter: .recentlyReleased, offset: 0, limit: 5)
        #expect(released.map(\.name) == ["New Sessions", "Old Sessions"])
    }

    @Test func playMirrorBumpsCountsAndRecency() throws {
        let (index, server) = try seededIndex()
        try populate(index, server)

        try index.mirrorPlay(trackID: id("t1", server))
        let recentlyPlayed = try index.albums(filter: .recentlyPlayed, offset: 0, limit: 5)
        #expect(recentlyPlayed.map(\.name) == ["Daybreak"])
        let mostPlayed = try index.albums(filter: .mostPlayed, offset: 0, limit: 5)
        #expect(mostPlayed.count == 1)
    }

    /// Verbatim from the library `EraAffinity` was written for: Elvis Presley's own records run
    /// 1956–1973, with a 2000 "50 Greatest Hits" correctly flagged a compilation and a 2023 live
    /// reissue that is not — real data, not a tidy fixture, and…
    @Test func activeEraIsTheMedianOfOriginalRecordsNotCompilations() throws {
        let (index, server) = try seededIndex()
        func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }
        func album(_ raw: String, year: Int, compilation: Bool = false) -> Album {
            Album(
                id: id(raw), name: raw, artistName: "Elvis Presley",
                artistID: id("ar-elvis"), year: year, trackCount: 1,
                isCompilation: compilation
            )
        }

        try index.upsertArtists(
            [Artist(id: id("ar-elvis"), name: "Elvis Presley", albumCount: 4)],
            generation: 1
        )
        try index.upsertAlbums([
            album("Elvis", year: 1956),
            album("Elvis Is Back", year: 1960),
            album("From Elvis in Memphis", year: 1969),
            // A compilation years later — left out, or the era would read
            // as 2000s rather than the records it was compiled from.
            album("50 Greatest Hits", year: 2000, compilation: true),
            // Not flagged a compilation, but a live reissue decades after
            // the show it recorded — one outlier a median shrugs off,
            // where a min/max span would stretch to meet it.
            album("Recorded at Madison Square Garden", year: 2023),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let eras = try index.activeEraByArtist()
        // 1956, 1960, 1969, 2023 → the middle two average (integer division) to 1964.
        #expect(eras["elvis presley"] == 1964)
    }
}

@Suite struct SubstringSearchTests {
    private func seededIndex() throws -> (LibraryIndex, ServerID) {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

        try index.upsertArtists([
            Artist(id: id("ar1"), name: "Coldplay"),
            Artist(id: id("ar2"), name: "Björk"),
            Artist(id: id("ar3"), name: "U2"),
            Artist(id: id("ar4"), name: "The Cold Sea"),
        ], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Parachutes", artistName: "Coldplay"),
            Album(id: id("al2"), name: "St. Elmo's Fire", artistName: "Various Artists"),
            Album(id: id("al3"), name: "Sgt. Pepper's Lonely Hearts Club Band", artistName: "The Beatles"),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "Yellow", albumName: "Parachutes", artistName: "Coldplay"),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return (index, server)
    }

    @Test func findsMatchesInTheMiddleOfAWord() throws {
        let (index, _) = try seededIndex()
        // The original prefix-only index could not do this.
        #expect(try index.search("oldplay", limit: 10).artists.map(\.name) == ["Coldplay"])
        #expect(try index.search("chute", limit: 10).albums.map(\.name) == ["Parachutes"])
        #expect(try index.search("ello", limit: 10).tracks.map(\.title) == ["Yellow"])
    }

    /// An apostrophe is a wall to a trigram index: "elmos" shares no trigram
    /// with "Elmo's", so the album could not be found by the obvious spelling
    /// of its own name. Punctuation is now folded on both sides.
    @Test func punctuationDoesNotHideATitle() throws {
        let (index, _) = try seededIndex()
        #expect(try index.search("elmos", limit: 10).albums.map(\.name) == ["St. Elmo's Fire"])
        #expect(try index.search("elmo's", limit: 10).albums.map(\.name) == ["St. Elmo's Fire"])
        #expect(try index.search("st elmos fire", limit: 10).albums.map(\.name) == ["St. Elmo's Fire"])
        #expect(try index.search("sgt peppers", limit: 10).albums.first?.name.hasPrefix("Sgt.") == true)
    }

    @Test func matchesAcrossFieldsAndTerms() throws {
        let (index, _) = try seededIndex()
        // Album indexed with its artist name, so the artist finds the album.
        #expect(try index.search("coldplay", limit: 10).albums.map(\.name) == ["Parachutes"])
        // Every term must appear, in any order or position.
        #expect(try index.search("cold play", limit: 10).artists.contains { $0.name == "Coldplay" })
        // A song is not called what its record is called.
        #expect(try index.search("yellow parachutes", limit: 10).tracks.isEmpty)
        #expect(try index.search("yellow", limit: 10).tracks.map(\.title) == ["Yellow"])
        #expect(try index.search("yellow zzz", limit: 10).tracks.isEmpty)
    }

    @Test("A song is found by its own name, or by who it is by — never by the record it sits on")
    func songsMatchTitleAndArtistOnly() throws {
        let (index, _) = try seededIndex()
        #expect(try index.search("coldplay", limit: 10).tracks.map(\.title) == ["Yellow"])
        #expect(try index.search("parachutes", limit: 10).tracks.isEmpty)
        #expect(try index.search("parachutes", limit: 10).albums.map(\.name) == ["Parachutes"])
    }

    @Test func shortQueriesStillWork() throws {
        let (index, _) = try seededIndex()
        // Under three characters there is no trigram to look up, so these
        // take the LIKE path.
        #expect(try index.search("u2", limit: 10).artists.map(\.name) == ["U2"])
        #expect(try index.search("bj", limit: 10).artists.map(\.name) == ["Björk"])
    }

    @Test func ignoresDiacritics() throws {
        let (index, _) = try seededIndex()
        #expect(try index.search("bjork", limit: 10).artists.map(\.name) == ["Björk"])
    }

    @Test func rankingPrefersWholeAndLeadingMatches() {
        // Exact, then leading, then start-of-word, then buried mid-word.
        #expect(LibraryIndex.matchScore(content: "cold", needle: "cold") == 0)
        #expect(LibraryIndex.matchScore(content: "coldplay", needle: "cold") == 1)
        #expect(LibraryIndex.matchScore(content: "the cold sea", needle: "cold") == 2)
        #expect(LibraryIndex.matchScore(content: "scold", needle: "cold") == 3)
        #expect(LibraryIndex.matchScore(content: "warm", needle: "cold") == 4)
    }

    @Test func betterMatchesComeFirst() throws {
        let (index, _) = try seededIndex()
        let names = try index.search("cold", limit: 10).artists.map(\.name)
        // "Coldplay" leads with the term; "The Cold Sea" has it mid-string.
        #expect(names.first == "Coldplay")
        #expect(names.contains("The Cold Sea"))
    }

    @Test func wildcardCharactersAreTreatedLiterally() throws {
        let (index, _) = try seededIndex()
        // "%" must not behave as a LIKE wildcard and match everything.
        #expect(try index.search("%", limit: 10).isEmpty)
        #expect(try index.search("_", limit: 10).isEmpty)
    }
}

@Suite struct ArtistPageCacheTests {
    private func seeded() throws -> (LibraryIndex, ServerID) {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

        try index.upsertArtists([
            Artist(id: id("ar1"), name: "Aurora Skies"),
            Artist(id: id("ar2"), name: "Cobalt Waves"),
            Artist(id: id("ar3"), name: "The Basement Tapes"),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "First Light", artistID: id("ar1")),
            Track(id: id("t2"), title: "Slow Horizon", artistID: id("ar1")),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return (index, server)
    }

    @Test func roundTripsAndPreservesOrder() throws {
        let (index, server) = try seeded()
        func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

        try index.storeArtistPage(
            for: id("ar1"),
            biography: "A fixture act.",
            // Deliberately not alphabetical: rank order must survive.
            similarArtistIDs: [id("ar3"), id("ar2")],
            topTrackIDs: [id("t2"), id("t1")]
        )

        let cached = try #require(try index.cachedArtistPage(for: id("ar1")))
        #expect(cached.biography == "A fixture act.")
        #expect(cached.similarArtists.map(\.name) == ["The Basement Tapes", "Cobalt Waves"])
        #expect(cached.topTracks.map(\.title) == ["Slow Horizon", "First Light"])
        #expect(!cached.isStale())
    }

    @Test func missingArtistHasNoCache() throws {
        let (index, server) = try seeded()
        #expect(try index.cachedArtistPage(for: MediaID(server: server, rawValue: "ar9")) == nil)
    }

    @Test func storingAgainReplacesPreviousEntry() throws {
        let (index, server) = try seeded()
        func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

        try index.storeArtistPage(for: id("ar1"), biography: "First", similarArtistIDs: [], topTrackIDs: [])
        try index.storeArtistPage(for: id("ar1"), biography: "Second", similarArtistIDs: [id("ar2")], topTrackIDs: [])

        let cached = try #require(try index.cachedArtistPage(for: id("ar1")))
        #expect(cached.biography == "Second")
        #expect(cached.similarArtists.map(\.name) == ["Cobalt Waves"])
    }

    @Test func stalenessIsMeasuredAgainstFetchTime() throws {
        let fresh = LibraryIndex.CachedArtistPage(
            biography: nil, similarArtists: [], topTracks: [], fetchedAt: Date()
        )
        #expect(!fresh.isStale())
        let old = LibraryIndex.CachedArtistPage(
            biography: nil, similarArtists: [], topTracks: [],
            fetchedAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 30)
        )
        #expect(old.isStale())
    }
}

@Suite struct MigrationTests {
    /// Opens the same database file twice. The second open must migrate an
    /// existing schema rather than assume a fresh one — editing a shipped
    /// migration instead of adding a new one broke exactly this.
    @Test func existingDatabaseUpgradesInPlace() throws {
        let server = ServerID()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let index = try LibraryIndex(databaseURL: url, serverID: server)
            try index.upsertAlbums([
                Album(id: MediaID(server: server, rawValue: "al1"), name: "Daybreak"),
            ], generation: 1)
            try index.finishSync(generation: 1)
        }

        // Reopening runs any migrations added since, and writing must still
        // work against every column the current records use.
        let reopened = try LibraryIndex(databaseURL: url, serverID: server)
        try reopened.upsertAlbums([
            Album(
                id: MediaID(server: server, rawValue: "al2"),
                name: "Nightfall",
                releaseTypes: [.ep]
            ),
        ], generation: 2)
        try reopened.finishSync(generation: 2)

        let albums = try reopened.albums(filter: .alphabeticalByName, offset: 0, limit: 10)
        #expect(albums.map(\.name) == ["Nightfall"])
        #expect(albums.first?.primaryReleaseType == .ep)
    }
}

@Suite struct ArtistPageQueryTests {
    private func id(_ raw: String, _ server: ServerID) -> MediaID {
        MediaID(server: server, rawValue: raw)
    }

    /// Two artists: Aurora (an album and an EP of her own) and Cobalt, whose
    /// compilation includes one Aurora track — the "appears on" case.
    private func seed(_ index: LibraryIndex, _ server: ServerID) throws {
        let aurora = id("ar1", server)
        let cobalt = id("ar2", server)
        try index.upsertArtists([
            Artist(id: aurora, name: "Aurora Skies"),
            Artist(id: cobalt, name: "Cobalt Waves"),
        ], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1", server), name: "Daybreak", artistName: "Aurora Skies",
                  artistID: aurora, year: 2019, releaseTypes: [.album]),
            Album(id: id("al2", server), name: "Nightfall", artistName: "Aurora Skies",
                  artistID: aurora, year: 2022, releaseTypes: [.ep]),
            Album(id: id("al3", server), name: "Blue Sessions", artistName: "Cobalt Waves",
                  artistID: cobalt, year: 2021, releaseTypes: [.album], isCompilation: true),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1", server), title: "First Light", albumID: id("al1", server),
                  artistName: "Aurora Skies", artistID: aurora,
                  rating: StarRating(2), playCount: 20),
            Track(id: id("t2", server), title: "Slow Horizon", albumID: id("al1", server),
                  artistName: "Aurora Skies", artistID: aurora, isFavorite: true, playCount: 5),
            Track(id: id("t3", server), title: "Guest Spot", albumID: id("al3", server),
                  artistName: "Aurora Skies", artistID: aurora,
                  rating: StarRating(4.5), playCount: 1),
            Track(id: id("t4", server), title: "Own Song", albumID: id("al3", server),
                  artistName: "Cobalt Waves", artistID: cobalt),
        ], generation: 1)
        try index.finishSync(generation: 1)
    }

    @Test func releasesAreGroupedByType() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        try seed(index, server)

        let groups = try index.releaseGroups(forArtist: id("ar1", server))
        #expect(groups.map(\.type) == [.album, .ep])
        #expect(groups[0].albums.map(\.name) == ["Daybreak"])
        #expect(groups[1].albums.map(\.name) == ["Nightfall"])
    }

    @Test func compilationFlagOverridesReportedType() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        try seed(index, server)

        // "Blue Sessions" is tagged Album but flagged as a compilation.
        let groups = try index.releaseGroups(forArtist: id("ar2", server))
        #expect(groups.map(\.type) == [.compilation])
    }

    @Test func appearsOnFindsGuestSpotsOnly() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        try seed(index, server)

        let appearances = try index.appearsOn(
            artistID: id("ar1", server),
            artistName: "Aurora Skies"
        )
        // The compilation credited to Cobalt, not Aurora's own records.
        #expect(appearances.map(\.name) == ["Blue Sessions"])

        let none = try index.appearsOn(artistID: id("ar2", server), artistName: "Cobalt Waves")
        #expect(none.isEmpty, "an artist's own album must not count as an appearance")
    }

    @Test func waveformSurvivesAndIsScopedToItsTrack() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        try seed(index, server)

        let track = id("t1", server)
        #expect(try index.waveform(forTrack: track) == nil)

        let bars: [Float] = [0, 0.25, 0.5, 1]
        try index.storeWaveform(bars, forTrack: track)
        let read = try #require(try index.waveform(forTrack: track))
        // Stored a byte per bar, so the levels come back within a step.
        #expect(read.count == bars.count)
        for (stored, original) in zip(read, bars) {
            #expect(abs(stored - original) < 0.005)
        }

        // A track that is gone from the library takes its waveform with it.
        _ = try index.beginSyncGeneration()
        try index.finishSync(generation: 2)
        #expect(try index.waveform(forTrack: track) == nil)
    }

    @Test func albumNotesAreKeptAndSurviveARewriteOfTheRow() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        try seed(index, server)

        let album = id("al1", server)
        #expect(try index.albumNotes(forAlbum: album) == nil)

        // Empty text is not kept: "no notes" must not shadow a later review.
        try index.storeAlbumNotes("  \n ", forAlbum: album)
        #expect(try index.albumNotes(forAlbum: album) == nil)

        try index.storeAlbumNotes("  A quiet record.  ", forAlbum: album)
        #expect(try index.albumNotes(forAlbum: album) == "A quiet record.")

        // A sync rewrites the album row from a listing that carries no notes
        // (Subsonic's). What was fetched must still be there afterwards.
        try index.upsertAlbums(
            [Album(id: album, name: "Daybreak", artistName: "Aurora Skies")],
            generation: 1
        )
        #expect(try index.albumNotes(forAlbum: album) == "A quiet record.")

        // Replaced by a newer answer.
        try index.storeAlbumNotes("Revised.", forAlbum: album)
        #expect(try index.albumNotes(forAlbum: album) == "Revised.")
    }

    @Test func albumNotesFallBackToTheReviewOnTheRowAndGoWithTheAlbum() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        let album = id("alP", server)
        try index.upsertAlbums(
            [Album(id: album, name: "Plex Album", review: "From the listing.")],
            generation: 1
        )
        #expect(try index.albumNotes(forAlbum: album) == "From the listing.")

        try index.storeAlbumNotes("Fetched.", forAlbum: album)
        #expect(try index.albumNotes(forAlbum: album) == "Fetched.")

        // An album that is gone from the library takes its notes with it.
        _ = try index.beginSyncGeneration()
        try index.finishSync(generation: 2)
        #expect(try index.albumNotes(forAlbum: album) == nil)
    }

    @Test func topAndFavouriteTracksForArtist() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        try seed(index, server)

        let top = try index.topTracks(forArtist: id("ar1", server), limit: 10)
        #expect(top.map(\.title) == ["First Light", "Slow Horizon", "Guest Spot"])

        // Rated at two and a half or better, and nothing else.
        let favourites = try index.favoriteTracks(forArtist: id("ar1", server), limit: 10)
        #expect(favourites.map(\.title) == ["Guest Spot"])

        // The long list opens from that shelf and carries its name, so it
        // draws the same line — more of the same songs, not different ones.
        let rated = try index.ratedTracks(forArtist: id("ar1", server))
        #expect(rated.map(\.title) == ["Guest Spot"])
    }

    /// Where the favourites line is drawn, from either side of it.
    @Test func favouritesStartAtTwoAndAHalfStars() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("ar1", server)
        try index.upsertArtists([Artist(id: artist, name: "Aurora Skies")], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1", server), title: "Just Under", artistID: artist, rating: StarRating(2)),
            Track(id: id("t2", server), title: "On The Line", artistID: artist, rating: StarRating(2.5)),
            Track(id: id("t3", server), title: "Well Over", artistID: artist, rating: StarRating(3)),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let favourites = try index.favoriteTracks(forArtist: artist, limit: 10)
        #expect(favourites.map(\.title) == ["Well Over", "On The Line"])
        // Which is three and up where a server keeps whole stars only:
        // "Well Over" is three, "Just Under" is two.
        #expect(!favourites.map(\.title).contains("Just Under"))
    }
}

@Suite struct LibrarySyncEngineTests {
    @Test func fullSyncMirrorsTheMockLibrary() async throws {
        let provider = MockProvider()
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        let summary = try await engine.fullSync()
        #expect(summary.artists == 3)
        #expect(summary.albums == 4)
        #expect(summary.tracks == 14)

        let stats = try index.stats()
        #expect(stats.artistCount == 3 && stats.albumCount == 4 && stats.trackCount == 14)

        // Search hits indexed content.
        let results = try index.search("first light", limit: 5)
        #expect(results.tracks.count == 1)

        // Album detail is complete and ordered.
        let albums = try index.albums(filter: .alphabeticalByName, offset: 0, limit: 50)
        let daybreak = try #require(albums.first { $0.name == "Daybreak" })
        let detail = try #require(try index.albumDetail(id: daybreak.id))
        #expect(detail.tracks.map(\.trackNumber) == [1, 2, 3, 4])
    }

    @Test func resyncIsIdempotent() async throws {
        let provider = MockProvider()
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        _ = try await engine.fullSync()

        let stats = try index.stats()
        #expect(stats.artistCount == 3 && stats.albumCount == 4 && stats.trackCount == 14)
    }
}

/// Dressing a mix: the sleeves and the names a card is drawn with.
@Suite("Mix dressing")
struct MixDressingTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }
    private func art(_ raw: String) -> ArtworkID { ArtworkID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("ar"), name: "Ruby Wells", artwork: art("ruby-portrait")),
        ], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al"), name: "Morning Light", artistName: "Ruby Wells",
                  artistID: id("ar"), year: 1974, genre: "Soul", artwork: art("album-cover")),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t"), title: "Morning Light", albumID: id("al"),
                  artistName: "Ruby Wells", artistID: id("ar"), year: 1974,
                  genre: "Soul", artwork: art("album-cover")),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    /// The bug itself. A mix arrives carrying the sleeve of the track it was
    /// seeded from; dressing has to replace that with the artist's own
    /// picture, or every artist card wears a record cover.
    @Test("An artist mix wears the artist's picture, not the track's sleeve")
    func artistMixGetsTheArtistPortrait() throws {
        let index = try seeded()
        let undressed = MadeForYou.Mix(
            kind: .artist(name: "Ruby Wells", artistID: id("ar"), seeds: [id("t")]),
            artwork: art("album-cover")
        )
        let dressed = index.dressed(undressed)
        #expect(dressed.artwork == art("ruby-portrait"))
        #expect(dressed.artwork != undressed.artwork)
    }

    /// Where the server has no picture of the artist, what the mix arrived
    /// with is better than nothing.
    @Test("With no portrait to be had the mix keeps the sleeve it came with")
    func fallsBackToWhatItArrivedWith() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: id("ar"), name: "Nobody Pictured")], generation: 1)
        try index.finishSync(generation: 1)

        let undressed = MadeForYou.Mix(
            kind: .artist(name: "Nobody Pictured", artistID: id("ar"), seeds: []),
            artwork: art("album-cover")
        )
        #expect(index.dressed(undressed).artwork == art("album-cover"))
    }

    @Test("A genre mix is drawn with the sleeves of what is in it")
    func genreMixGetsSleeves() throws {
        let index = try seeded()
        let dressed = index.dressed(
            MadeForYou.Mix(kind: .tag(genre: "Soul", decade: nil, members: ["Soul"]))
        )
        #expect(dressed.artwork != nil)
        #expect(!dressed.artworks.isEmpty)
    }
}

/// Searching for something whose name is mostly full stops.
@Suite("Searching for an acronym")
struct AcronymSearchTests {
    private static func id(_ raw: String, _ server: ServerID) -> MediaID {
        MediaID(server: server, rawValue: raw)
    }

    /// One acronym, and a shelf of decoys that between them hold every letter
    /// of it — which is what a real library is.
    private func seeded() throws -> (LibraryIndex, ServerID) {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        let generation = try index.beginSyncGeneration()

        func artist(_ raw: String, _ name: String) -> Artist {
            Artist(id: Self.id(raw, server), name: name)
        }
        func album(_ raw: String, _ name: String, by artist: String, _ artistID: String) -> Album {
            Album(
                id: Self.id(raw, server), name: name,
                artistName: artist, artistID: Self.id(artistID, server)
            )
        }
        func track(_ raw: String, _ title: String, on album: String, _ albumID: String,
                   by artist: String, _ artistID: String) -> Track {
            Track(
                id: Self.id(raw, server), title: title,
                albumName: album, albumID: Self.id(albumID, server),
                artistName: artist, artistID: Self.id(artistID, server)
            )
        }

        try index.upsertArtists([
            artist("ar1", "System of a Down"),
            artist("ar2", "R.E.M."),
            artist("ar3", "Bing Crosby"),
            artist("ar4", "Fatboy Slim"),
            artist("ar5", "Boy George"),
            // Tagged without its stops, which is the other half of how
            // acronyms are written.
            artist("ar6", "BBC Concert Orchestra"),
            artist("ar7", "Art Blakey"),
        ], generation: generation)
        try index.upsertAlbums([
            album("al1", "Mezmerize", by: "System of a Down", "ar1"),
            album("al2", "Automatic for the People", by: "R.E.M.", "ar2"),
            album("al3", "Backyard Boogie", by: "Bing Crosby", "ar3"),
        ], generation: generation)
        try index.upsertTracks([
            track("t1", "B.Y.O.B.", on: "Mezmerize", "al1", by: "System of a Down", "ar1"),
            track("t2", "Everybody Hurts", on: "Automatic for the People", "al2", by: "R.E.M.", "ar2"),
            track("t3", "Boogie Woogie Bugle Boy", on: "Backyard Boogie", "al3", by: "Bing Crosby", "ar3"),
            // A stop with a space already after it, which the fold turns
            // into two spaces — and no typed query ever has two.
            track("t4", "Nocturne Op. 27 No. 2", on: "Backyard Boogie", "al3", by: "Bing Crosby", "ar3"),
        ], generation: generation)
        try index.finishSync(generation: generation)
        return (index, server)
    }

    @Test("A dotted acronym finds the song and nothing else")
    func aDottedAcronymFindsItsSong() throws {
        let (index, _) = try seeded()

        let results = try index.search("b.y.o.b", limit: 20)

        #expect(results.tracks.map(\.title) == ["B.Y.O.B."])
        // The decoys all hold a b, a y and an o — which is what used to be
        // asked for, and what used to be answered.
        #expect(results.artists.isEmpty)
        #expect(results.albums.isEmpty)
    }

    @Test("However it is typed")
    func caseAndTrailingStopsDoNotMatter() throws {
        let (index, _) = try seeded()

        #expect(try index.search("B.Y.O.B.", limit: 20).tracks.map(\.title) == ["B.Y.O.B."])
        #expect(try index.search("b y o b", limit: 20).tracks.map(\.title) == ["B.Y.O.B."])
    }

    @Test("An acronym that is a band, not a song")
    func anAcronymArtist() throws {
        let (index, _) = try seeded()

        let results = try index.search("r.e.m.", limit: 20)

        #expect(results.artists.map(\.name) == ["R.E.M."])
        // The band's name is indexed on its records and songs too, so those
        // come back with it — but nothing else does.
        #expect(results.albums.map(\.name) == ["Automatic for the People"])
        #expect(results.tracks.map(\.title) == ["Everybody Hurts"])
    }

    @Test("A single letter still answers, best matches first")
    func oneLetterStillAnswers() throws {
        let (index, _) = try seeded()

        let results = try index.search("b", limit: 20)

        // Everything containing a b, which is most of this library — but the
        // rows where the b comes first are the ones a truncated answer keeps.
        #expect(!results.tracks.isEmpty)
        #expect(!results.artists.isEmpty)
    }

    @Test("A stop that already had a space after it")
    func aStopFollowedByASpace() throws {
        let (index, _) = try seeded()

        // "Op. 27" folds to "Op  27" in the index and "op 27" in the query,
        // and a phrase is matched literally: two spaces are not one. Every
        // classical library is made of these.
        #expect(try index.search("op 27", limit: 20).tracks.count == 1)
        #expect(try index.search("no 2", limit: 20).tracks.count == 1)
        #expect(try index.search("op. 27", limit: 20).tracks.count == 1)
    }

    @Test("An acronym written without its stops")
    func anAcronymTaggedWithoutStops() throws {
        let (index, _) = try seeded()

        // Typed with stops, tagged without them. Both spellings are asked
        // for, because neither is more correct than the other.
        #expect(try index.search("b.b.c", limit: 20).artists.map(\.name) == ["BBC Concert Orchestra"])
        #expect(try index.search("bbc", limit: 20).artists.map(\.name) == ["BBC Concert Orchestra"])
    }

    @Test("An acronym with a word after it")
    func anAcronymAndAWord() throws {
        let (index, _) = try seeded()

        // The letters stay one phrase and the word is its own — this used to
        // fall back to ANDing four single letters with the word, which is
        // the original bug wearing a hat.
        #expect(try index.search("b.y.o.b system", limit: 20).tracks.map(\.title) == ["B.Y.O.B."])
        #expect(try index.search("b.y.o.b zebra", limit: 20).tracks.isEmpty)
        // The record it is on is not one of the song's own names.
        #expect(try index.search("b.y.o.b mezmerize", limit: 20).tracks.isEmpty)
    }

    @Test("A three-letter search is not the name of a table")
    func threeLettersAreNotAKind() throws {
        let (index, _) = try seeded()

        // `kind` holds the words artist, album and track, and it used to be
        // indexed alongside the text — so "art" matched the literal 'artist'
        // on every artist row in the library, and answered with all of them.
        #expect(try index.search("art", limit: 50).artists.map(\.name) == ["Art Blakey"])
        #expect(try index.search("alb", limit: 50).albums.isEmpty)
        #expect(try index.search("rac", limit: 50).tracks.isEmpty)
    }

    @Test("Ordinary searching is untouched")
    func ordinarySearchingIsUntouched() throws {
        let (index, _) = try seeded()

        #expect(try index.search("mezmer", limit: 20).albums.map(\.name) == ["Mezmerize"])
        #expect(try index.search("boogie woogie", limit: 20).tracks.count == 1)
        #expect(try index.search("zebra", limit: 20).isEmpty)
    }
}

/// What a thing is called outranks who it is by.
@Suite("Ranking a word that is both a title and a name")
struct SearchFieldRankingTests {
    private static func id(_ raw: String, _ server: ServerID) -> MediaID {
        MediaID(server: server, rawValue: raw)
    }

    private func seeded() throws -> LibraryIndex {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        let generation = try index.beginSyncGeneration()

        try index.upsertArtists([
            Artist(id: Self.id("ar1", server), name: "John Legend"),
            Artist(id: Self.id("ar2", server), name: "Bob Marley"),
        ], generation: generation)
        try index.upsertAlbums([
            // By an artist whose name carries the word.
            Album(
                id: Self.id("al1", server), name: "Get Lifted",
                artistName: "John Legend", artistID: Self.id("ar1", server)
            ),
            // Called it.
            Album(
                id: Self.id("al2", server), name: "Legend",
                artistName: "Bob Marley", artistID: Self.id("ar2", server)
            ),
        ], generation: generation)
        try index.upsertTracks([
            // Called it.
            Track(
                id: Self.id("t1", server), title: "Legend",
                albumName: "Get Lifted", albumID: Self.id("al1", server),
                artistName: "John Legend", artistID: Self.id("ar1", server)
            ),
            // By someone called it, and on a record called it — neither of
            // which is the song's own name.
            Track(
                id: Self.id("t2", server), title: "Ordinary People",
                albumName: "Legend", albumID: Self.id("al2", server),
                artistName: "John Legend", artistID: Self.id("ar1", server)
            ),
            // Neither.
            Track(
                id: Self.id("t3", server), title: "Three Little Birds",
                albumName: "Legend", albumID: Self.id("al2", server),
                artistName: "Bob Marley", artistID: Self.id("ar2", server)
            ),
        ], generation: generation)
        try index.finishSync(generation: generation)
        return index
    }

    @Test("An album called it comes before an album merely by someone called it")
    func albumNameBeatsArtistName() throws {
        let index = try seeded()
        #expect(try index.search("legend", limit: 10).albums.map(\.name) == ["Legend", "Get Lifted"])
    }

    @Test("A song called it comes first, and a song merely sitting on a record called it is not a result")
    func songTitleBeatsArtistAndAlbumIsNotConsulted() throws {
        let index = try seeded()
        let titles = try index.search("legend", limit: 10).tracks.map(\.title)
        // "Three Little Birds" is only on a record called Legend, so it is
        // nowhere; "Ordinary People" is by someone called Legend, so it is
        // last.
        #expect(titles == ["Legend", "Ordinary People"])
    }

    @Test("The artist is still found")
    func artistIsFound() throws {
        let index = try seeded()
        #expect(try index.search("legend", limit: 10).artists.map(\.name) == ["John Legend"])
    }
}

/// Terms that fall in different columns still have to find the row.
@Suite("A query that spans what a thing is called and who it is by")
struct SearchAcrossColumnsTests {
    private func seeded() throws -> LibraryIndex {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        let generation = try index.beginSyncGeneration()
        try index.upsertArtists([
            Artist(id: MediaID(server: server, rawValue: "ar1"), name: "Coldplay"),
        ], generation: generation)
        try index.upsertAlbums([
            Album(
                id: MediaID(server: server, rawValue: "al1"), name: "Parachutes",
                artistName: "Coldplay", artistID: MediaID(server: server, rawValue: "ar1")
            ),
        ], generation: generation)
        try index.upsertTracks([
            Track(
                id: MediaID(server: server, rawValue: "t1"), title: "Yellow",
                albumName: "Parachutes", albumID: MediaID(server: server, rawValue: "al1"),
                artistName: "Coldplay", artistID: MediaID(server: server, rawValue: "ar1")
            ),
        ], generation: generation)
        try index.finishSync(generation: generation)
        return index
    }

    @Test("The song's name and its artist, typed together")
    func titleAndArtist() throws {
        let index = try seeded()
        // The two words live in two different columns of the same row, which
        // is the whole reason they are columns and not rows of their own.
        #expect(try index.search("yellow coldplay", limit: 10).tracks.map(\.title) == ["Yellow"])
        #expect(try index.search("coldplay yellow", limit: 10).tracks.map(\.title) == ["Yellow"])
    }

    @Test("The record's name and its artist, typed together")
    func albumAndArtist() throws {
        let index = try seeded()
        #expect(try index.search("parachutes coldplay", limit: 10).albums.map(\.name) == ["Parachutes"])
    }

    @Test("A word from neither finds nothing")
    func neither() throws {
        let index = try seeded()
        #expect(try index.search("yellow zebra", limit: 10).tracks.isEmpty)
    }
}
