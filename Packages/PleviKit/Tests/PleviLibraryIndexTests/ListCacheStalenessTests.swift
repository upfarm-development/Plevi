import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// What the list caches refuse to keep, and which way a kept page ran.
@Suite("List caches: direction and play-derived answers")
struct ListCacheStalenessTests {
    private let library = ServerID()

    private func rule(_ field: FilterField, _ op: FilterOperator, _ value: FilterValue) -> FilterRule {
        FilterRule(field: field, op: op, value: value)
    }

    private func filter(_ subject: LibraryFilter.Subject, _ rules: FilterRule...) -> LibraryFilter {
        LibraryFilter(subject: subject, root: FilterGroup(children: rules.map { .rule($0) }))
    }

    // MARK: Album direction

    @Test("Forward and reverse of the same album page are different questions")
    func albumDirection() {
        let page = AlbumListCache.Page(filter: .alphabeticalByName, limit: 100_000)
        // One filter value: every `FilterGroup()` carries a fresh id.
        let none = LibraryFilter(subject: .albums)
        func key(_ direction: LibraryIndex.SortDirection) -> AlbumListCache.Key {
            AlbumListCache.Key(
                library: library, version: 1, offline: false, page: page,
                query: .alphabeticalByName, direction: direction,
                filter: none
            )
        }
        let albums = (0..<AlbumListCache.minimumRows).map {
            Album(id: MediaID(server: library, rawValue: "al\($0)"), name: "A\($0)")
        }
        let cache = AlbumListCache()
        cache.store(.init(key: key(.reverse), albums: albums, runs: nil))
        #expect(cache.entry(for: key(.forward)) == nil)
        #expect(cache.entry(for: key(.reverse)) != nil)
        // A lookup by page restores the direction it was held under.
        let held = cache.entry(forPage: page, library: library, version: 1, offline: false)
        #expect(held?.key.direction == .reverse)
        // Storing forward does not overwrite reverse in the same slot.
        cache.store(.init(key: key(.forward), albums: albums, runs: nil))
        #expect(cache.entry(for: key(.reverse)) != nil)
        #expect(cache.entry(for: key(.forward)) != nil)
    }

    // MARK: Filters

    @Test("Filters about plays, downloads, playlists or a span of days are not cacheable")
    func filterCacheability() {
        #expect(LibraryFilter(subject: .songs).isCacheable)
        #expect(filter(.songs, rule(.rating, .atLeast, .number(4))).isCacheable)
        #expect(filter(.songs, rule(.dateAdded, .before, .date(Date()))).isCacheable)
        #expect(!filter(.songs, rule(.lastPlayed, .isNotSet, .none)).isCacheable)
        #expect(!filter(.songs, rule(.playCount, .equals, .number(0))).isCacheable)
        #expect(!filter(.albums, rule(.albumPlayCount, .atLeast, .number(1))).isCacheable)
        #expect(!filter(.songs, rule(.downloaded, .isTrue, .none)).isCacheable)
        #expect(!filter(.songs, rule(.playlistName, .contains, .text("x"))).isCacheable)
        #expect(!filter(.songs, rule(.dateAdded, .inTheLast, .days(30))).isCacheable)
        // Inside a nested group too.
        let nested = LibraryFilter(subject: .songs, root: FilterGroup(children: [
            .group(FilterGroup(match: .any, children: [.rule(rule(.lastPlayed, .notInTheLast, .days(90)))]))
        ]))
        #expect(!nested.isCacheable)
    }

    @Test("A songs list sorted by plays, or filtered on them, is not kept")
    func songListRefuses() {
        let cache = SongListCache()
        func store(_ order: LibraryIndex.SongOrder, _ filter: LibraryFilter) {
            let key = SongListCache.Key(library: library, version: 1, offline: false, order: order, filter: filter)
            cache.store(.init(key: key, tracks: [], runs: .init()))
        }
        store(.lastPlayed, LibraryFilter(subject: .songs))
        #expect(cache.isEmpty)
        store(.mostPlayed, LibraryFilter(subject: .songs))
        #expect(cache.isEmpty)
        store(.alphabeticalByTitle, filter(.songs, rule(.playCount, .equals, .number(0))))
        #expect(cache.isEmpty)
        store(.alphabeticalByTitle, LibraryFilter(subject: .songs))
        #expect(!cache.isEmpty)
        // A refused entry does not evict the good one already held.
        store(.lastPlayed, LibraryFilter(subject: .songs))
        #expect(cache.anything()?.key.order == .alphabeticalByTitle)
    }

    @Test("An artist list sorted by plays, or filtered on them, is not kept")
    func artistListRefuses() {
        let cache = ArtistListCache()
        func store(_ order: LibraryIndex.ArtistOrder, _ filter: LibraryFilter) {
            let key = ArtistListCache.Key(
                library: library, version: 1, offline: false, filter: filter, order: order
            )
            cache.store(.init(key: key, artists: [], runs: nil))
        }
        store(.lastPlayed, LibraryFilter(subject: .artists))
        store(.mostPlayed, LibraryFilter(subject: .artists))
        store(.alphabetical, filter(.artists, rule(.lastPlayed, .notInTheLast, .days(365))))
        #expect(cache.isEmpty)
        store(.albumCount, LibraryFilter(subject: .artists))
        #expect(!cache.isEmpty)
    }

    @Test("A big album page filtered on plays is not kept")
    func albumListRefusesPlayFilter() {
        let cache = AlbumListCache()
        let page = AlbumListCache.Page(filter: .alphabeticalByName, limit: 100_000)
        let albums = (0..<AlbumListCache.minimumRows).map {
            Album(id: MediaID(server: library, rawValue: "al\($0)"), name: "A\($0)")
        }
        let key = AlbumListCache.Key(
            library: library, version: 1, offline: false, page: page,
            query: .alphabeticalByName,
            filter: filter(.albums, rule(.lastPlayed, .isNotSet, .none))
        )
        cache.store(.init(key: key, albums: albums, runs: nil))
        #expect(cache.isEmpty)
    }
}
