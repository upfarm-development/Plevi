import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The artist twin of `WholeTrackReadTests`/`WholeAlbumReadTests`.
@Suite("A whole artist, read by column position")
struct WholeArtistReadTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    @Test("Every column arrives where it belongs")
    func everyColumn() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let original = Artist(
            id: id("ar1"),
            name: "The Artist",
            sortName: "Artist, The",
            albumCount: 6,
            artwork: ArtworkID(server: server, rawValue: "art1"),
            isFavorite: true,
            rating: StarRating(4)
        )
        try index.upsertArtists([original], generation: 1)
        try index.finishSync(generation: 1)

        let read = try #require(try index.artists().first)

        #expect(read.id == original.id)
        #expect(read.name == original.name)
        #expect(read.sortName == original.sortName)
        #expect(read.albumCount == original.albumCount)
        #expect(read.artwork == original.artwork)
        #expect(read.isFavorite == true)
        #expect(read.rating == original.rating)
    }

    @Test("An artist with nothing filled in stays empty rather than picking up a neighbour's value")
    func emptyColumns() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([Artist(id: id("ar1"), name: "Bare")], generation: 1)
        try index.finishSync(generation: 1)

        let read = try #require(try index.artists().first)
        #expect(read.name == "Bare")
        #expect(read.sortName == nil)
        #expect(read.albumCount == nil)
        #expect(read.artwork == nil)
        #expect(read.isFavorite == false)
        #expect(read.rating == nil)
    }

    @Test("The same fields come back through the filtered path too")
    func filteredPathAgrees() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("ar1"), name: "Filtered Artist", isFavorite: true, rating: StarRating(5)),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let filter = LibraryFilter(
            subject: .artists,
            root: FilterGroup(children: [.rule(FilterRule(field: .rating, op: .isSet))])
        )
        let read = try #require(try index.artists(matching: filter).first)
        #expect(read.name == "Filtered Artist")
        #expect(read.isFavorite == true)
    }

    @Test("Two artists that sort identically still come back in a total order")
    func tiesAreTotal() throws {
        let server = ServerID()
        let straight = (0..<200).map { i in
            Artist(id: MediaID(server: server, rawValue: "ar\(i)"), name: "Same Name")
        }
        let shuffled = Array(straight.reversed())

        let a = try LibraryIndex(inMemoryFor: server)
        try a.upsertArtists(straight, generation: 1)
        try a.finishSync(generation: 1)

        let b = try LibraryIndex(inMemoryFor: server)
        try b.upsertArtists(shuffled, generation: 1)
        try b.finishSync(generation: 1)

        let fromA = try a.artists().map(\.id)
        let fromB = try b.artists().map(\.id)
        #expect(fromA == fromB, "same-named artists moved between write orders")
    }
}
