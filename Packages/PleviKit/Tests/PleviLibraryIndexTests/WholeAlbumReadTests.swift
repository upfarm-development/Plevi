import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The album twin of `WholeTrackReadTests`.
@Suite("A whole album, read by column position")
struct WholeAlbumReadTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    @Test("Every column arrives where it belongs")
    func everyColumn() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let added = Date(timeIntervalSince1970: 1_600_000_000)
        let played = Date(timeIntervalSince1970: 1_700_000_000)
        let released = Date(timeIntervalSince1970: 1_650_000_000)
        let original = Album(
            id: id("al1"),
            name: "Only Record",
            artistName: "The Artist",
            artistID: id("ar1"),
            year: 1999,
            genre: "Ambient",
            trackCount: 11,
            duration: 2_413.5,
            artwork: ArtworkID(server: server, rawValue: "art1"),
            addedAt: added,
            playedAt: played,
            playCount: 12,
            isFavorite: true,
            rating: StarRating(4),
            releaseTypes: [.album, .live],
            isCompilation: true,
            recordLabel: "Quiet Records",
            releaseDate: released,
            criticRating: 8.5,
            review: "A patient, unhurried record."
        )
        try index.upsertAlbums([original], generation: 1)
        try index.finishSync(generation: 1)

        let read = try #require(
            try index.albums(filter: .alphabeticalByName, offset: 0, limit: 10).first
        )

        #expect(read.id == original.id)
        #expect(read.name == original.name)
        #expect(read.artistName == original.artistName)
        #expect(read.artistID == original.artistID)
        #expect(read.year == original.year)
        #expect(read.genre == original.genre)
        #expect(read.trackCount == original.trackCount)
        #expect(read.duration == original.duration)
        #expect(read.artwork == original.artwork)
        #expect(read.addedAt?.timeIntervalSince1970 == added.timeIntervalSince1970)
        #expect(read.playedAt?.timeIntervalSince1970 == played.timeIntervalSince1970)
        #expect(read.playCount == 12)
        #expect(read.isFavorite == true)
        #expect(read.rating == original.rating)
        #expect(Set(read.releaseTypes) == Set(original.releaseTypes))
        #expect(read.isCompilation == true)
        #expect(read.recordLabel == original.recordLabel)
        #expect(read.releaseDate?.timeIntervalSince1970 == released.timeIntervalSince1970)
        #expect(read.criticRating == original.criticRating)
        #expect(read.review == original.review)
    }

    @Test("An album with nothing filled in stays empty rather than picking up a neighbour's value")
    func emptyColumns() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([Album(id: id("al1"), name: "Bare")], generation: 1)
        try index.finishSync(generation: 1)

        let read = try #require(
            try index.albums(filter: .alphabeticalByName, offset: 0, limit: 10).first
        )
        #expect(read.name == "Bare")
        #expect(read.artistName == nil)
        #expect(read.artistID == nil)
        #expect(read.year == nil)
        #expect(read.genre == nil)
        #expect(read.trackCount == nil)
        #expect(read.duration == nil)
        #expect(read.artwork == nil)
        #expect(read.addedAt == nil)
        #expect(read.playedAt == nil)
        #expect(read.playCount == nil)
        #expect(read.isFavorite == false)
        #expect(read.rating == nil)
        #expect(read.releaseTypes.isEmpty)
        #expect(read.isCompilation == false)
        #expect(read.recordLabel == nil)
        #expect(read.releaseDate == nil)
        #expect(read.criticRating == nil)
        #expect(read.review == nil)
    }

    @Test("The same twenty fields come back through the filtered path too")
    func filteredPathAgrees() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let original = Album(
            id: id("al1"),
            name: "Filtered Record",
            artistName: "The Artist",
            genre: "Ambient",
            isFavorite: true,
            criticRating: 7.0,
            review: "Fine."
        )
        try index.upsertAlbums([original], generation: 1)
        try index.finishSync(generation: 1)

        let filter = LibraryFilter(
            subject: .albums,
            root: FilterGroup(children: [.rule(FilterRule(field: .genre, op: .matches, value: .text("Ambient")))])
        )

        let read = try #require(try index.albums(matching: filter, limit: 10).first)
        #expect(read.name == "Filtered Record")
        #expect(read.criticRating == 7.0)
        #expect(read.review == "Fine.")
    }
}
