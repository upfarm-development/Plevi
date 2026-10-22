import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// Browsing a library one letter at a time.
@Suite("Browsing by letter")
struct LetterIndexTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func index(albums names: [String]) throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums(
            names.enumerated().map { position, name in
                Album(id: id("al\(position)"), name: name, artistName: "Someone")
            },
            generation: 1
        )
        try index.finishSync(generation: 1)
        return index
    }

    /// Groups the characters the index reports the way the watch's letter
    /// screen does.
    private func sections(_ counts: [String: Int]) -> [String: Int] {
        var totals: [String: Int] = [:]
        for (character, count) in counts {
            totals[AlphabetIndex.section(for: character), default: 0] += count
        }
        return totals
    }

    @Test("Every album is under exactly one letter, and they add up")
    func countsAddUp() throws {
        let names = ["Aurora", "aftermath", "Blue", "1999", "…Baby", "Zenith", "Ågot", "Éclair"]
        let counts = try index(albums: names).albumInitialCounts()
        let filed = sections(counts)

        #expect(filed.values.reduce(0, +) == names.count)
        #expect(filed["A"] == 2)
        #expect(filed["B"] == 1)
        #expect(filed["Z"] == 1)
        // Å is its own letter here, É folds onto E — AlphabetIndex's rule.
        #expect(filed["Å"] == 1)
        #expect(filed["E"] == 1)
        #expect(filed[AlphabetIndex.other] == 2)
    }

    @Test("A letter returns every record under it, in the list's own order")
    func aLetterIsWholeAndOrdered() throws {
        let index = try index(albums: ["Aurora", "aftermath", "Anchor", "Blue"])
        let counts = try index.albumInitialCounts()

        let aCharacters = Set(counts.keys.filter { AlphabetIndex.section(for: $0) == "A" })
        #expect(aCharacters == ["A", "a"])
        #expect(try index.albums(initials: aCharacters).map(\.name)
                == ["aftermath", "Anchor", "Aurora"])
    }

    /// The shape of the bug: a library far past the old four-hundred ceiling,
    /// where every letter after the cut had nothing behind it.
    @Test("A library past the old ceiling is still reachable letter by letter")
    func nothingIsCutOff() throws {
        var names = (0..<500).map { "A record \($0)" }
        names.append("Zenith")
        let index = try index(albums: names)
        let counts = try index.albumInitialCounts()

        func under(_ section: String) throws -> [Album] {
            try index.albums(initials: Set(counts.keys.filter {
                AlphabetIndex.section(for: $0) == section
            }))
        }
        #expect(try under("A").count == 500)
        #expect(try under("Z").map(\.name) == ["Zenith"])
    }

    /// `AlphabetIndex` files on the first character that is not whitespace,
    /// so the database has to group on the same one or a padded name lands in
    /// a bucket the letter screen will never ask for.
    @Test("A name with a space in front of it files under its first letter")
    func leadingSpaceIsIgnored() throws {
        let index = try index(albums: ["  Wanderer"])
        let counts = try index.albumInitialCounts()
        #expect(sections(counts)["W"] == 1)

        let ws = Set(counts.keys.filter { AlphabetIndex.section(for: $0) == "W" })
        #expect(try index.albums(initials: ws).count == 1)
    }

    @Test("Asking for no letters asks the database nothing")
    func emptyIsEmpty() throws {
        let index = try index(albums: ["Aurora"])
        #expect(try index.albums(initials: []).isEmpty)
        #expect(try index.artists(initials: []).isEmpty)
    }

    @Test("An artist files under the name the server sorts it by")
    func artistsUseTheirSortName() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists(
            [
                Artist(id: id("a1"), name: "The Beatles", sortName: "Beatles, The"),
                Artist(id: id("a2"), name: "Aretha Franklin"),
            ],
            generation: 1
        )
        try index.finishSync(generation: 1)

        let filed = sections(try index.artistInitialCounts())
        // Under B, not T — where the rest of the app already files it.
        #expect(filed["B"] == 1)
        #expect(filed["A"] == 1)
        #expect(filed["T"] == nil)
    }

    @Test("Downloads narrows the letters as well as the rows")
    func downloadedOnlyNarrows() throws {
        let index = try index(albums: ["Aurora", "Zenith"])
        // Nothing is downloaded, so every letter is empty.
        #expect(try index.albumInitialCounts(downloadedOnly: true).isEmpty)
        #expect(try index.artistInitialCounts(downloadedOnly: true).isEmpty)
    }
}
