import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The artist twin of `SongListCacheTests`.
@Suite("Keeping the artist list between visits")
struct ArtistListCacheTests {
    private let library = ServerID()
    private let other = ServerID()

    private func key(
        library: ServerID? = nil,
        version: Int = 1,
        offline: Bool = false,
        filter: LibraryFilter = LibraryFilter(subject: .artists)
    ) -> ArtistListCache.Key {
        ArtistListCache.Key(library: library ?? self.library, version: version, offline: offline, filter: filter)
    }

    private func entry(_ key: ArtistListCache.Key, names: [String] = ["Aurora", "Nightfall"]) -> ArtistListCache.Entry {
        let artists = names.enumerated().map { i, name in
            Artist(id: MediaID(server: key.library, rawValue: "ar\(i)"), name: name)
        }
        let (ordered, runs) = AlphabetIndex.filed(artists) { $0.name }
        return ArtistListCache.Entry(key: key, artists: ordered, runs: runs)
    }

    @Test("The same question is answered from what is held")
    func hit() {
        let cache = ArtistListCache()
        let k = key()
        cache.store(entry(k))
        #expect(cache.entry(for: k)?.artists.count == 2)
    }

    @Test("Nothing is held to begin with")
    func emptyToStart() {
        #expect(ArtistListCache().entry(for: key()) == nil)
        #expect(ArtistListCache().isEmpty)
    }

    @Test("A different library is a different question")
    func missOnLibrary() {
        let cache = ArtistListCache()
        cache.store(entry(key()))
        #expect(cache.entry(for: key(library: other)) == nil)
    }

    @Test("A sync, a rating or a favourite is a different question")
    func missOnVersion() {
        let cache = ArtistListCache()
        cache.store(entry(key()))
        #expect(cache.entry(for: key(version: 2)) == nil)
    }

    @Test("Going offline is a different question")
    func missOnOffline() {
        let cache = ArtistListCache()
        cache.store(entry(key()))
        #expect(cache.entry(for: key(offline: true)) == nil)
    }

    @Test("A different filter is a different question")
    func missOnFilter() {
        let cache = ArtistListCache()
        cache.store(entry(key()))
        var filtered = LibraryFilter(subject: .artists)
        filtered.root.children = [.rule(FilterRule(field: .rating, op: .isSet))]
        #expect(cache.entry(for: key(filter: filtered)) == nil)
    }

    @Test("Letting go leaves nothing behind")
    func clearing() {
        let cache = ArtistListCache()
        let k = key()
        cache.store(entry(k))
        cache.clear()
        #expect(cache.entry(for: k) == nil)
        #expect(cache.isEmpty)
    }

    @Test("What is held always covers the rows it was filed from")
    func runsCoverTheirRows() {
        let cache = ArtistListCache()
        let k = key()
        cache.store(entry(k, names: ["Apple", "Ærø", "banana", "9 Lives", "Zebra"]))
        let held = try! #require(cache.entry(for: k))
        #expect(held.runs?.count == held.artists.count)
    }
}
