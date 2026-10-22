import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// Records that share today's date, whatever year they came out.
@Suite("Released on this day")
struct OnThisDayTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)!
    }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "Nineties", year: 1994, releaseDate: date("1994-08-21")),
            Album(id: id("a2"), name: "Noughties", year: 2003, releaseDate: date("2003-08-21")),
            Album(id: id("a3"), name: "Day After", year: 2010, releaseDate: date("2010-08-22")),
            Album(id: id("a4"), name: "Month Before", year: 2010, releaseDate: date("2010-07-21")),
            // A year but no date: it cannot name a day, so it never matches.
            Album(id: id("a5"), name: "Year Only", year: 1994),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Every anniversary of the day, newest first")
    func matchesTheDayInAnyYear() throws {
        let index = try seeded()
        #expect(try index.albumsReleased(month: 8, day: 21).map(\.name) == ["Noughties", "Nineties"])
    }

    @Test("A day either side is a different day")
    func neighbouringDays() throws {
        let index = try seeded()
        #expect(try index.albumsReleased(month: 8, day: 22).map(\.name) == ["Day After"])
        #expect(try index.albumsReleased(month: 7, day: 21).map(\.name) == ["Month Before"])
    }

    @Test("A single-digit month and day still match")
    func padsTheDate() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "New Year", year: 2001, releaseDate: date("2001-01-05")),
        ], generation: 1)
        try index.finishSync(generation: 1)
        // Written as 1 and 5, stored as "01-05": without padding this finds
        // nothing, which is how a January shelf would quietly stay empty.
        #expect(try index.albumsReleased(month: 1, day: 5).map(\.name) == ["New Year"])
    }

    @Test("A day nothing came out on is empty, not everything")
    func emptyDay() throws {
        let index = try seeded()
        #expect(try index.albumsReleased(month: 2, day: 30).isEmpty)
    }

    @Test("The limit is honoured")
    func limit() throws {
        let index = try seeded()
        #expect(try index.albumsReleased(month: 8, day: 21, limit: 1).map(\.name) == ["Noughties"])
    }
}

/// Telling a real date from the one a server writes when it does not know.
@Suite("Placeholder release dates")
struct PlaceholderDayTests {
    private let server = ServerID()

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)!
    }

    /// A library shaped like a real one: a heap filed on 1 January because
    /// only the year was known, and ordinary days either side.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        var albums: [Album] = []
        for n in 0..<300 {
            albums.append(Album(
                id: MediaID(server: server, rawValue: "j\(n)"),
                name: "Year Only \(n)",
                releaseDate: date("19\(70 + n % 30)-01-01")
            ))
        }
        // Twenty other days with ten records each.
        for day in 1...20 {
            for n in 0..<10 {
                albums.append(Album(
                    id: MediaID(server: server, rawValue: "m\(day)-\(n)"),
                    name: "March \(day) #\(n)",
                    releaseDate: date(String(format: "2001-03-%02d", day))
                ))
            }
        }
        try index.upsertAlbums(albums, generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("The day everything unknown is filed on is recognised")
    func januaryFirstIsAPlaceholder() throws {
        let index = try seeded()
        let day = try index.releaseDay(month: 1, day: 1)
        #expect(day.matches == 300)
        #expect(day.isPlaceholder)
    }

    @Test("An ordinary day is not")
    func ordinaryDay() throws {
        let index = try seeded()
        let day = try index.releaseDay(month: 3, day: 5)
        #expect(day.matches == 10)
        #expect(!day.isPlaceholder)
    }

    @Test("A busy but believable day stays")
    func busyRealDay() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        var albums: [Album] = []
        // Forty on one day against an average of twenty: busy, not absurd —
        // the first of a month collects some genuine releases too.
        for n in 0..<40 {
            albums.append(Album(id: MediaID(server: server, rawValue: "a\(n)"),
                                name: "Big Day \(n)", releaseDate: date("2001-03-01")))
        }
        for day in 2...10 {
            for n in 0..<20 {
                albums.append(Album(id: MediaID(server: server, rawValue: "b\(day)-\(n)"),
                                    name: "Day \(day) #\(n)",
                                    releaseDate: date(String(format: "2001-03-%02d", day))))
            }
        }
        try index.upsertAlbums(albums, generation: 1)
        try index.finishSync(generation: 1)
        #expect(!(try index.releaseDay(month: 3, day: 1).isPlaceholder))
    }

    @Test("A small library is judged against its own average, not a fixed number")
    func smallLibrary() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        var albums: [Album] = []
        // Thirty on one day is most of this library, but thirty records is
        // not evidence of anything: below the floor, so it is left alone.
        for n in 0..<30 {
            albums.append(Album(id: MediaID(server: server, rawValue: "s\(n)"),
                                name: "Small \(n)", releaseDate: date("2001-01-01")))
        }
        albums.append(Album(id: MediaID(server: server, rawValue: "other"),
                            name: "Other", releaseDate: date("2001-06-06")))
        try index.upsertAlbums(albums, generation: 1)
        try index.finishSync(generation: 1)
        #expect(!(try index.releaseDay(month: 1, day: 1).isPlaceholder))
    }
}

/// Which records get the front of the shelf.
@Suite("Records before collections")
struct OnThisDayRankingTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)!
    }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            // Newest of the lot, but a collection.
            Album(id: id("a1"), name: "Greatest Hits", artistName: "America",
                  releaseTypes: [.album, .compilation], releaseDate: date("2020-08-21")),
            // Older, and a record.
            Album(id: id("a2"), name: "Real Record", artistName: "Bright Eyes",
                  releaseTypes: [.album], releaseDate: date("2015-08-21")),
            // Newer than the record, but somebody's sampler.
            Album(id: id("a3"), name: "Sampler", artistName: "Various Artists",
                  releaseTypes: [.album], releaseDate: date("2019-08-21")),
            // Flagged rather than typed.
            Album(id: id("a4"), name: "Flagged Collection", artistName: "Someone",
                  releaseTypes: [.album], isCompilation: true,
                  releaseDate: date("2018-08-21")),
            // Not an album at all: after records, before collections.
            Album(id: id("a5"), name: "A Single", artistName: "Lost Frequencies",
                  releaseTypes: [.single], releaseDate: date("2014-08-21")),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Records first, then other releases, then collections")
    func ordering() throws {
        let index = try seeded()
        #expect(try index.albumsReleased(month: 8, day: 21).map(\.name) == [
            "Real Record",        // an album, whatever its date
            "A Single",           // not an album, but not a collection either
            "Greatest Hits",      // typed as a compilation
            "Sampler",            // various artists
            "Flagged Collection", // flagged as a compilation
        ])
    }

    @Test("A short shelf is records, not collections")
    func limitTakesRecordsFirst() throws {
        let index = try seeded()
        // The three newest by date would be two collections and a sampler.
        #expect(try index.albumsReleased(month: 8, day: 21, limit: 2).map(\.name)
                == ["Real Record", "A Single"])
    }

    @Test("Among records, the newest still comes first")
    func dateStillOrdersWithinARank() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("b1"), name: "Older", artistName: "A",
                  releaseTypes: [.album], releaseDate: date("1994-08-21")),
            Album(id: id("b2"), name: "Newer", artistName: "B",
                  releaseTypes: [.album], releaseDate: date("2004-08-21")),
        ], generation: 1)
        try index.finishSync(generation: 1)
        #expect(try index.albumsReleased(month: 8, day: 21).map(\.name) == ["Newer", "Older"])
    }
}
