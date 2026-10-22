import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// Decade radios against a library where the pressing year and the music's
/// year are not the same thing.
@Suite("Decade radio eras")
struct DecadeEraTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func date(_ year: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)!
    }

    /// A library holding a 2011 compilation of 1970s soul, the artists' own
    /// seventies records to measure them against, and a modern record so the
    /// station has something it should *not* pick.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)

        try index.upsertArtists([
            Artist(id: id("ar-soul"), name: "Ruby Wells"),
            Artist(id: id("ar-modern"), name: "Neon Parade"),
            Artist(id: id("ar-unknown"), name: "Nobody Else"),
        ], generation: 1)

        try index.upsertAlbums([
            // The compilation: pressed in 2011, no original date, various
            // artists. Its own year is a lie about the music on it.
            Album(
                id: id("al-comp"), name: "70s Soul Gold", artistName: "Various Artists",
                year: 2011, isCompilation: true
            ),
            // Ruby's own records, which is what places her in the seventies.
            Album(
                id: id("al-ruby1"), name: "Morning Light", artistName: "Ruby Wells",
                artistID: id("ar-soul"), year: 1974
            ),
            Album(
                id: id("al-ruby2"), name: "Coming Home", artistName: "Ruby Wells",
                artistID: id("ar-soul"), year: 1976
            ),
            // A genuinely modern record.
            Album(
                id: id("al-modern"), name: "Glass Arcade", artistName: "Neon Parade",
                artistID: id("ar-modern"), year: 2014
            ),
            // A reissue: pressed 2015, but the server knows it is from 1966.
            Album(
                id: id("al-reissue"), name: "First Sessions", artistName: "Ruby Wells",
                artistID: id("ar-soul"), year: 2015, releaseDate: date(1966)
            ),
        ], generation: 1)

        try index.upsertTracks([
            // On the compilation, by an artist we can place.
            Track(id: id("t-comp-ruby"), title: "Soul Gold Opener",
                  albumID: id("al-comp"), artistName: "Ruby Wells",
                  artistID: id("ar-soul"), year: 2011),
            // On the compilation, but carrying its own original year.
            Track(id: id("t-comp-tagged"), title: "Tagged Original",
                  albumID: id("al-comp"), artistName: "Someone Tagged",
                  year: 2011, originalYear: 1973),
            // On the compilation, by an artist with nothing else here.
            Track(id: id("t-comp-unknown"), title: "Orphan Cut",
                  albumID: id("al-comp"), artistName: "Nobody Else", year: 2011),
            // Ordinary seventies records.
            Track(id: id("t-ruby1"), title: "Morning Light", albumID: id("al-ruby1"),
                  artistName: "Ruby Wells", artistID: id("ar-soul"), year: 1974),
            // Ordinary modern record.
            Track(id: id("t-modern"), title: "Glass Arcade", albumID: id("al-modern"),
                  artistName: "Neon Parade", artistID: id("ar-modern"), year: 2014),
            // The reissue's song: filed 2015, actually 1966.
            Track(id: id("t-reissue"), title: "First Sessions", albumID: id("al-reissue"),
                  artistName: "Ruby Wells", artistID: id("ar-soul"), year: 2015),
        ], generation: 1)

        try index.finishSync(generation: 1)
        return index
    }

    @Test("A modern compilation of seventies music plays in the seventies")
    func compilationLandsInItsRealDecade() throws {
        let index = try seeded()
        let titles = Set(try index.stationTracks(.decades([1970])).map(\.title))
        // Placed by its artist's other records.
        #expect(titles.contains("Soul Gold Opener"))
        // Placed by its own original-year tag.
        #expect(titles.contains("Tagged Original"))
        // An ordinary seventies record is still there.
        #expect(titles.contains("Morning Light"))
    }

    @Test("The compilation's own pressing year does not put it in the 2010s")
    func compilationDoesNotLandInPressingDecade() throws {
        let index = try seeded()
        let titles = Set(try index.stationTracks(.decades([2010])).map(\.title))
        #expect(!titles.contains("Soul Gold Opener"))
        #expect(!titles.contains("Tagged Original"))
        // The genuinely modern record is the only thing here.
        #expect(titles.contains("Glass Arcade"))
    }

    @Test("A song on a compilation by an unknown artist is left out entirely")
    func unplaceableCompilationTrackIsExcluded() throws {
        let index = try seeded()
        let seventies = Set(try index.stationTracks(.decades([1970])).map(\.title))
        let tens = Set(try index.stationTracks(.decades([2010])).map(\.title))
        // Nothing is known about it, so it is not guessed into either.
        #expect(!seventies.contains("Orphan Cut"))
        #expect(!tens.contains("Orphan Cut"))
    }

    @Test("A reissue plays in the decade it was recorded")
    func reissueUsesOriginalDate() throws {
        let index = try seeded()
        let sixties = Set(try index.stationTracks(.decades([1960])).map(\.title))
        let tens = Set(try index.stationTracks(.decades([2010])).map(\.title))
        #expect(sixties.contains("First Sessions"))
        #expect(!tens.contains("First Sessions"))
    }

    @Test("The radio decade list offers the decades the music is from")
    func decadeListUsesEras() throws {
        let index = try seeded()
        let decades = Set(try index.radioDecades())
        // The seventies are real here even though no album is filed under
        // them except Ruby's own.
        #expect(decades.contains(1970))
        #expect(decades.contains(1960))
        #expect(decades.contains(2010))
    }

    @Test("The radio picker never offers a decade whose station would play nothing")
    func pickerAgreesWithTheStations() throws {
        let index = try seeded()
        for decade in try index.radioDecades() {
            let tracks = try index.stationTracks(.decades([decade]))
            #expect(!tracks.isEmpty, "\(decade)s was offered but plays nothing")
        }
    }

    @Test("A decade whose every song is below the rating floor is not offered")
    func floorRemovesADecadeFromThePicker() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("al"), name: "Thin Record", artistName: "Someone", year: 1982),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t"), title: "Poorly Rated", albumID: id("al"),
                  artistName: "Someone", year: 1982, rating: StarRating(2)),
        ], generation: 1)
        try index.finishSync(generation: 1)

        #expect(try index.stationTracks(.decades([1980])).isEmpty)
        #expect(!(try index.radioDecades()).contains(1980))
    }

    @Test("A greatest-hits record does not drag its artist's era forward")
    func greatestHitsExcludedFromArtistEra() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: id("ar"), name: "Ruby Wells")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "Morning Light", artistName: "Ruby Wells", year: 1974),
            Album(id: id("a2"), name: "Coming Home", artistName: "Ruby Wells", year: 1976),
            // Never flagged by the server, but obviously a collection — and
            // dated to when somebody pressed it.
            Album(id: id("a3"), name: "Greatest Hits", artistName: "Ruby Wells", year: 2019),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let eras = try index.activeEraByArtist()
        // The median of 1974 and 1976, with 2019 left out of the reckoning.
        #expect(eras["ruby wells"] == 1975)
    }

    @Test("An artist who only guests on compilations still gets an era, from their own tracks")
    func compilationOnlyArtistGetsEraFromTracks() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(
                id: id("al-comp"), name: "Dance Floor Classics", artistName: "Various Artists",
                year: 2015, isCompilation: true
            ),
        ], generation: 1)
        try index.upsertTracks([
            // Every appearance of this artist in the library is a guest spot on somebody else's
            // compilation — no album is ever credited to them, so the album-only pass above has
            // nothing to measure them by at all.
            Track(id: id("t1"), title: "Dance Around", albumID: id("al-comp"),
                  artistName: "Wavelength", year: 2015, originalYear: 1998),
            Track(id: id("t2"), title: "Neon Nights", albumID: id("al-comp"),
                  artistName: "Wavelength", year: 2015, originalYear: 1999),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let eras = try index.activeEraByArtist()
        #expect(eras["wavelength"] == 1998)
    }

    @Test("An artist's own albums are trusted over a stray compilation credit, not averaged with it")
    func ownAlbumsTakePrecedenceOverCompilationTracks() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: id("ar"), name: "Ruby Wells")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "Morning Light", artistName: "Ruby Wells", year: 1974),
            Album(id: id("a2"), name: "Coming Home", artistName: "Ruby Wells", year: 1976),
            Album(
                id: id("al-comp"), name: "Party Anthems", artistName: "Various Artists",
                year: 2015, isCompilation: true
            ),
        ], generation: 1)
        try index.upsertTracks([
            // A single guest spot on a modern compilation, decades after her
            // own records — this must not drag her era forward, the way it
            // would if this were simply averaged in with the album years.
            Track(id: id("t-comp"), title: "Remix Cut", albumID: id("al-comp"),
                  artistName: "Ruby Wells", year: 2015, originalYear: 2015),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let eras = try index.activeEraByArtist()
        #expect(eras["ruby wells"] == 1975)
    }
}

/// The rating floor, on both backends' scales.
@Suite("Radio rating floor")
struct RadioRatingFloorTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// Ratings as each backend would have produced them.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: id("ar"), name: "Ruby Wells")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al"), name: "Morning Light", artistName: "Ruby Wells", year: 1974),
        ], generation: 1)
        try index.upsertTracks([
            // Unrated — allowed.
            Track(id: id("t-none"), title: "Unrated", albumID: id("al"),
                  artistName: "Ruby Wells", year: 1974, genre: "Soul", rating: nil),
            // Exactly the line, as Plex's userRating 5 arrives.
            Track(id: id("t-plex-25"), title: "Plex Exactly", albumID: id("al"),
                  artistName: "Ruby Wells", year: 1974, genre: "Soul",
                  rating: StarRating(2.5)),
            // Just below, as Plex's userRating 4 arrives.
            Track(id: id("t-plex-20"), title: "Plex Below", albumID: id("al"),
                  artistName: "Ruby Wells", year: 1974, genre: "Soul",
                  rating: StarRating(2.0)),
            // Navidrome's whole stars: 3 is above the line, 2 is below.
            Track(id: id("t-nd-3"), title: "Navidrome Above", albumID: id("al"),
                  artistName: "Ruby Wells", year: 1974, genre: "Soul",
                  rating: StarRating(stars: 3)),
            Track(id: id("t-nd-2"), title: "Navidrome Below", albumID: id("al"),
                  artistName: "Ruby Wells", year: 1974, genre: "Soul",
                  rating: StarRating(stars: 2)),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Everything-station keeps the unrated and drops the badly rated")
    func everything() throws {
        let titles = Set(try seeded().stationTracks(.everything).map(\.title))
        #expect(titles == ["Unrated", "Plex Exactly", "Navidrome Above"])
    }

    @Test("Genre radios apply the same floor")
    func genres() throws {
        let titles = Set(try seeded().stationTracks(.genres(["Soul"])).map(\.title))
        #expect(titles == ["Unrated", "Plex Exactly", "Navidrome Above"])
    }

    @Test("Decade radios apply the same floor")
    func decades() throws {
        let titles = Set(try seeded().stationTracks(.decades([1970])).map(\.title))
        #expect(titles == ["Unrated", "Plex Exactly", "Navidrome Above"])
    }

    @Test("A genre within a decade applies it too")
    func genreInDecade() throws {
        let station = LibraryIndex.Station.genresInDecade(genres: ["Soul"], decade: 1970)
        let titles = Set(try seeded().stationTracks(station).map(\.title))
        #expect(titles == ["Unrated", "Plex Exactly", "Navidrome Above"])
    }

    @Test("Exactly 2.5 is in and anything under it is out")
    func theLineItself() throws {
        let titles = Set(try seeded().stationTracks(.everything).map(\.title))
        #expect(titles.contains("Plex Exactly"))
        #expect(!titles.contains("Plex Below"))
        #expect(!titles.contains("Navidrome Below"))
    }
}
