import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// SQLite's sort is not stable, and a resync rewrites table order every time, so an album order
/// with real ties has to end on something unique or the same albums quietly reshuffle between one
/// visit and the next — the same bug the songs list…
@Suite("Every album order is total")
struct AlbumOrderTests {
    private let names = ["Aurora", "Nightfall", "Daybreak", "Echoes", "Halcyon", "Interlude", "Wayfarer", "Zenith", "Undertow", "Coastline"]

    private func albums(seed: Int) -> [Album] {
        let server = ServerID()
        return (0..<2_000).map { i in
            Album(
                id: MediaID(server: server, rawValue: "al\(i)"),
                name: names[i % names.count],
                artistName: "Artist \(i % 40)",
                year: 1960 + (i % 60),
                addedAt: Date(timeIntervalSince1970: Double(1_500_000_000 + (i % 30) * 86_400)),
                playCount: i % 5,
                isFavorite: i % 3 == 0,
                rating: i % 4 == 0 ? StarRating(4) : nil
            )
        }
    }

    /// Two indexes, the same albums, written in different orders — a stand-in
    /// for what a resync actually does to table order.
    private func twoIndexes() throws -> (LibraryIndex, LibraryIndex) {
        let server = ServerID()
        let straight = albums(seed: 1).map { a -> Album in
            Album(id: MediaID(server: server, rawValue: a.id.rawValue), name: a.name,
                  artistName: a.artistName, year: a.year, addedAt: a.addedAt,
                  playCount: a.playCount, isFavorite: a.isFavorite, rating: a.rating)
        }
        let shuffled = Array(straight.reversed())

        let a = try LibraryIndex(inMemoryFor: server)
        try a.upsertAlbums(straight, generation: 1)
        try a.finishSync(generation: 1)

        let b = try LibraryIndex(inMemoryFor: server)
        try b.upsertAlbums(shuffled, generation: 1)
        try b.finishSync(generation: 1)

        return (a, b)
    }

    private static let deterministic: [AlbumFilter] = [
        .alphabeticalByName, .alphabeticalByArtist, .recentlyAdded,
        .mostPlayed, .highestRated, .favorites,
    ]

    @Test("Every deterministic order returns the same sequence whatever order the table was written in", arguments: deterministic)
    func stableAcrossWriteOrder(_ order: AlbumFilter) throws {
        let (a, b) = try twoIndexes()
        let fromA = try a.albums(filter: order, offset: 0, limit: 2_000).map(\.id)
        let fromB = try b.albums(filter: order, offset: 0, limit: 2_000).map(\.id)
        #expect(fromA == fromB, "order \(order) is not total: the same albums moved between write orders")
    }

    @Test(".random and .rediscover are excluded from the stability guarantee, not asserted stable")
    func randomIsNotClaimedStable() throws {
        // Nothing to assert here beyond compiling `.random`/`.rediscover` out of `deterministic`
        // above — their whole point is not to answer the same way twice, and
        // `AlbumListCache.isCacheable` is what enforces that they are never kept.
        #expect(!AlbumFilter.random.isCacheable)
        #expect(!AlbumFilter.rediscover.isCacheable)
    }
}
