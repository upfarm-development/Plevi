import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

@Suite("Spotlight's raw material: an artist's own best-rated albums")
struct SpotlightCandidatesTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    @Test("Each artist's albums are capped and ranked best first")
    func capsAndRanksPerArtist() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "First", artistName: "Wide Artist", year: 2001, criticRating: 6),
            Album(id: id("a2"), name: "Second", artistName: "Wide Artist", year: 2002, criticRating: 9),
            Album(id: id("a3"), name: "Third", artistName: "Wide Artist", year: 2003, criticRating: 8),
            Album(id: id("a4"), name: "Fourth", artistName: "Wide Artist", year: 2004, criticRating: 7),
            Album(id: id("a5"), name: "Fifth", artistName: "Wide Artist", year: 2005, criticRating: 10),
            Album(id: id("a6"), name: "Sixth", artistName: "Wide Artist", year: 2006, criticRating: 5),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let ranked = try index.topRatedAlbumsByArtist(usingCriticRating: true, capped: 5)
        let names = ranked["wide artist"]?.map(\.displayName)
        #expect(names == ["Fifth", "Second", "Third", "Fourth", "First"])
    }

    @Test("A tie in rating breaks toward the older record")
    func tiesBreakOlderFirst() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "Newer", artistName: "Tied Artist", year: 2010, criticRating: 8),
            Album(id: id("a2"), name: "Older", artistName: "Tied Artist", year: 1990, criticRating: 8),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let ranked = try index.topRatedAlbumsByArtist(usingCriticRating: true)
        #expect(ranked["tied artist"]?.map(\.displayName) == ["Older", "Newer"])
    }

    @Test("An unrated album never appears, and never breaks the ranking of the rest")
    func excludesUnratedAlbums() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "Rated", artistName: "Mixed Artist", year: 2001, criticRating: 8),
            Album(id: id("a2"), name: "Unrated", artistName: "Mixed Artist", year: 2002),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let ranked = try index.topRatedAlbumsByArtist(usingCriticRating: true)
        #expect(ranked["mixed artist"]?.map(\.displayName) == ["Rated"])
    }

    @Test("Various Artists never gets a spotlight of its own")
    func excludesVariousArtists() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "A Compilation", artistName: "Various Artists", year: 2001, criticRating: 9),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let ranked = try index.topRatedAlbumsByArtist(usingCriticRating: true)
        #expect(ranked["various artists"] == nil)
    }

    @Test("Each artist is kept apart from every other")
    func keepsArtistsSeparate() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "One Artist's Record", artistName: "Artist One", year: 2001, criticRating: 9),
            Album(id: id("a2"), name: "Another's Record", artistName: "Artist Two", year: 2001, criticRating: 6),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let ranked = try index.topRatedAlbumsByArtist(usingCriticRating: true)
        #expect(ranked["artist one"]?.map(\.displayName) == ["One Artist's Record"])
        #expect(ranked["artist two"]?.map(\.displayName) == ["Another's Record"])
    }

    @Test("The star-rating column is used instead when asked, on its own 0-5 scale")
    func usesStarRatingWhenAskedTo() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "Five Stars", artistName: "Starred Artist", year: 2001, rating: StarRating(5)),
            Album(id: id("a2"), name: "Also Critically Rated", artistName: "Starred Artist", year: 2002, criticRating: 9),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let byStars = try index.topRatedAlbumsByArtist(usingCriticRating: false)
        // The critic-rated-only album carries no star rating, so on the
        // star-rating column it is exactly as unrated as an album with
        // neither — left out, the same as `excludesUnratedAlbums` above.
        #expect(byStars["starred artist"]?.map(\.displayName) == ["Five Stars"])
    }
}
