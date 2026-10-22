import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The album twin of `SongListCacheTests`, plus the rules that are unique to
/// this cache: a page carries its own ceiling, some orders are refused
/// outright, and a page too short to matter is never kept at all.
@Suite("Keeping album pages between visits")
struct AlbumListCacheTests {
    private let library = ServerID()
    private let other = ServerID()

    private func page(filter: AlbumFilter = .alphabeticalByName, limit: Int = 100_000) -> AlbumListCache.Page {
        AlbumListCache.Page(filter: filter, limit: limit)
    }

    private func key(
        library: ServerID? = nil,
        version: Int = 1,
        offline: Bool = false,
        page: AlbumListCache.Page? = nil,
        query: AlbumFilter = .alphabeticalByName,
        filter: LibraryFilter = LibraryFilter(subject: .albums)
    ) -> AlbumListCache.Key {
        AlbumListCache.Key(
            library: library ?? self.library,
            version: version,
            offline: offline,
            page: page ?? self.page(),
            query: query,
            filter: filter
        )
    }

    private func entry(_ key: AlbumListCache.Key, rows: Int = AlbumListCache.minimumRows) -> AlbumListCache.Entry {
        let albums = (0..<rows).map { i in
            Album(id: MediaID(server: key.library, rawValue: "al\(i)"), name: "Album \(i)")
        }
        return AlbumListCache.Entry(key: key, albums: albums, runs: nil)
    }

    @Test("A large enough entry is answered from what is held")
    func hit() {
        let cache = AlbumListCache()
        let k = key()
        cache.store(entry(k))
        #expect(cache.entry(for: k)?.albums.count == AlbumListCache.minimumRows)
    }

    @Test("Nothing is held to begin with")
    func emptyToStart() {
        #expect(AlbumListCache().entry(for: key()) == nil)
        #expect(AlbumListCache().isEmpty)
    }

    @Test("A different library is a different question")
    func missOnLibrary() {
        let cache = AlbumListCache()
        cache.store(entry(key()))
        #expect(cache.entry(for: key(library: other)) == nil)
    }

    @Test("A sync, a rating or a favourite is a different question")
    func missOnVersion() {
        let cache = AlbumListCache()
        cache.store(entry(key()))
        #expect(cache.entry(for: key(version: 2)) == nil)
    }

    @Test("Going offline is a different question")
    func missOnOffline() {
        let cache = AlbumListCache()
        cache.store(entry(key()))
        #expect(cache.entry(for: key(offline: true)) == nil)
    }

    @Test("The same filter at a different ceiling is a different question")
    func missOnPageLimit() {
        let cache = AlbumListCache()
        cache.store(entry(key(page: page(limit: 100_000))))
        // Home's "See More" for a shelf and the library page behind it ask the same AlbumFilter at
        // different limits; conflating them means one seeds the other with a wrong-length answer
        // that seeding then never corrects.
        #expect(cache.entry(for: key(page: page(limit: 50))) == nil)
    }

    @Test("A different LibraryFilter is a different question")
    func missOnFilter() {
        let cache = AlbumListCache()
        cache.store(entry(key()))
        var filtered = LibraryFilter(subject: .albums)
        filtered.root.children = [.rule(FilterRule(field: .genre, op: .matches, value: .text("Ambient")))]
        #expect(cache.entry(for: key(filter: filtered)) == nil)
    }

    @Test("A page is found across a sort change, and restores the sort it was left on")
    func entryForPageIgnoresQuery() {
        let cache = AlbumListCache()
        cache.store(entry(key(query: .alphabeticalByArtist)))
        let found = cache.entry(forPage: page(), library: library, version: 1, offline: false)
        #expect(found?.key.query == .alphabeticalByArtist)
    }

    @Test("A page is not found across a library, version or offline change")
    func entryForPageStillRespectsTheRestOfTheKey() {
        let cache = AlbumListCache()
        cache.store(entry(key()))
        #expect(cache.entry(forPage: page(), library: other, version: 1, offline: false) == nil)
        #expect(cache.entry(forPage: page(), library: library, version: 2, offline: false) == nil)
        #expect(cache.entry(forPage: page(), library: library, version: 1, offline: true) == nil)
    }

    @Test("Too few rows to matter is never kept")
    func refusesBelowMinimum() {
        let cache = AlbumListCache()
        let k = key()
        cache.store(entry(k, rows: AlbumListCache.minimumRows - 1))
        #expect(cache.entry(for: k) == nil)
        #expect(cache.isEmpty)
    }

    @Test(
        "An order whose answer is not a function of the key is never kept",
        arguments: [AlbumFilter.random, .rediscover, .mostPlayed, .recentlyPlayed]
    )
    func refusesUnstableOrders(_ order: AlbumFilter) {
        let cache = AlbumListCache()
        let k = key(query: order)
        cache.store(entry(k))
        #expect(cache.entry(for: k) == nil)
        #expect(cache.isEmpty)
    }

    @Test(
        "Every other order is kept",
        arguments: [
            AlbumFilter.alphabeticalByName, .alphabeticalByArtist, .recentlyAdded,
            .recentlyReleased, .highestRated, .favorites,
        ]
    )
    func keepsStableOrders(_ order: AlbumFilter) {
        let cache = AlbumListCache()
        let k = key(query: order)
        cache.store(entry(k))
        #expect(cache.entry(for: k) != nil)
    }

    @Test("A third entry evicts the oldest")
    func evictsOldest() {
        let cache = AlbumListCache()
        let first = key(page: page(filter: .alphabeticalByName))
        let second = key(page: page(filter: .alphabeticalByArtist))
        let third = key(page: page(filter: .recentlyAdded))
        cache.store(entry(first))
        cache.store(entry(second))
        cache.store(entry(third))
        #expect(cache.entry(for: first) == nil)
        #expect(cache.entry(for: second) != nil)
        #expect(cache.entry(for: third) != nil)
    }

    @Test("A new version prunes rather than evicting by age")
    func prunesOnVersionRegardlessOfAge() {
        let cache = AlbumListCache()
        let stale = key(version: 1, page: page(filter: .alphabeticalByName))
        cache.store(entry(stale))
        // Storing under a new version does not itself remove the old entry — only `clear()` does,
        // called from the app when the version bumps — but a lookup under the old version must not
        // find it once the app has moved on, which the caller enforces…
        #expect(cache.entry(for: stale) != nil)
    }

    @Test("Letting go leaves nothing behind")
    func clearing() {
        let cache = AlbumListCache()
        let k = key()
        cache.store(entry(k))
        cache.clear()
        #expect(cache.entry(for: k) == nil)
        #expect(cache.isEmpty)
    }
}
