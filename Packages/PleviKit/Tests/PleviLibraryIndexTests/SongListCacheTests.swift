import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// When a kept songs list stops being true.
@Suite("Keeping the songs list between visits")
struct SongListCacheTests {
    private let library = ServerID()
    private let other = ServerID()

    private func key(
        library: ServerID? = nil,
        version: Int = 1,
        offline: Bool = false,
        order: LibraryIndex.SongOrder = .alphabeticalByTitle,
        filter: LibraryFilter = LibraryFilter(subject: .songs)
    ) -> SongListCache.Key {
        SongListCache.Key(
            library: library ?? self.library,
            version: version,
            offline: offline,
            order: order,
            filter: filter
        )
    }

    private func entry(_ key: SongListCache.Key, titles: [String] = ["Apple", "Banana"]) -> SongListCache.Entry {
        let tracks = titles.enumerated().map { i, title in
            Track(id: MediaID(server: key.library, rawValue: "t\(i)"), title: title)
        }
        let (ordered, runs) = AlphabetIndex.filed(tracks) { $0.displayTitle }
        return SongListCache.Entry(key: key, tracks: ordered, runs: runs)
    }

    @Test("The same question is answered from what is held")
    func hit() {
        let cache = SongListCache()
        let k = key()
        cache.store(entry(k))
        #expect(cache.entry(for: k)?.tracks.count == 2)
    }

    @Test("Nothing is held to begin with")
    func emptyToStart() {
        #expect(SongListCache().entry(for: key()) == nil)
        #expect(SongListCache().isEmpty)
    }

    @Test("A different library is a different question")
    func missOnLibrary() {
        let cache = SongListCache()
        cache.store(entry(key()))
        // Reconnecting builds a new index without bumping the version, so
        // this is the only thing that tells the two libraries apart.
        #expect(cache.entry(for: key(library: other)) == nil)
    }

    @Test("A sync, a rating or a favourite is a different question")
    func missOnVersion() {
        let cache = SongListCache()
        cache.store(entry(key()))
        #expect(cache.entry(for: key(version: 2)) == nil)
    }

    @Test("Going offline is a different question")
    func missOnOffline() {
        let cache = SongListCache()
        cache.store(entry(key()))
        // A failed connection flips this without bumping the version, and it
        // changes which songs may be listed at all.
        #expect(cache.entry(for: key(offline: true)) == nil)
    }

    @Test("A different sort is a different question")
    func missOnOrder() {
        let cache = SongListCache()
        cache.store(entry(key()))
        #expect(cache.entry(for: key(order: .alphabeticalByArtist)) == nil)
    }

    @Test("A different filter is a different question")
    func missOnFilter() {
        let cache = SongListCache()
        cache.store(entry(key()))
        var filtered = LibraryFilter(subject: .songs)
        filtered.subject = .albums
        #expect(cache.entry(for: key(filter: filtered)) == nil)
    }

    @Test("Letting go leaves nothing behind")
    func clearing() {
        let cache = SongListCache()
        let k = key()
        cache.store(entry(k))
        cache.clear()
        #expect(cache.entry(for: k) == nil)
        #expect(cache.isEmpty)
    }

    @Test("What is held always covers the rows it was filed from")
    func runsCoverTheirRows() {
        let cache = SongListCache()
        let k = key()
        cache.store(entry(k, titles: ["Apple", "Ærø", "banana", "9 Lives", "Zebra"]))
        let held = try! #require(cache.entry(for: k))
        #expect(held.runs.count == held.tracks.count)
        // Ranges that do not partition the array exactly are a crash waiting
        // for a jump-bar tap, not a mislabelled letter.
        var expected = 0
        for range in held.runs.ranges {
            #expect(range.lowerBound == expected)
            expected = range.upperBound
        }
        #expect(expected == held.tracks.count)
    }
}
