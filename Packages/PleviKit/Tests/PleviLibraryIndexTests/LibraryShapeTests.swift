import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// What the library is made of, and what has lately been played out of it.
@Suite("Library shape")
struct LibraryShapeTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertAlbums([
            Album(id: id("a1"), name: "Kind of Blue", year: 1959, genre: "Jazz"),
            Album(id: id("a2"), name: "Swingin'", year: 1955, genre: "Swing"),
            Album(id: id("a3"), name: "Parachutes", year: 2000, genre: "Pop/Rock"),
            Album(id: id("a4"), name: "Kids Songs", year: 2015, genre: "Barnesanger"),
        ], generation: 1)

        var tracks: [Track] = []
        func add(_ prefix: String, album: String, count: Int, playedFrom: Int? = nil) {
            for index in 0..<count {
                tracks.append(Track(
                    id: id("\(prefix)\(index)"),
                    title: "\(prefix) \(index)",
                    albumID: self.id(album),
                    artistName: "Artist \(prefix)",
                    // Deliberately nothing: the record carries both.
                    year: nil,
                    genre: nil,
                    playedAt: playedFrom.map { Date(timeIntervalSince1970: Double($0 + index)) }
                ))
            }
        }
        add("jazz", album: "a1", count: 30, playedFrom: 1000)
        add("swing", album: "a2", count: 12, playedFrom: 2000)
        add("rock", album: "a3", count: 20)
        add("kids", album: "a4", count: 5)

        try index.upsertTracks(tracks, generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    /// The query behind this once named its own columns `genre` and `year`, which are also the
    /// names of real columns on both joined tables.
    @Test("The shape is not empty")
    func theShapeIsRead() throws {
        let shape = try seeded().libraryShape()
        #expect(shape.totalTracks == 67)
        #expect(!shape.families.isEmpty)
        #expect(!shape.decadeCounts.isEmpty)
    }

    /// Both facts are borrowed from the record when the song has neither,
    /// which is the ordinary case rather than the exception.
    @Test("Genre and year come from the record when the song has none")
    func borrowedFromTheAlbum() throws {
        let shape = try seeded().libraryShape()
        // Swing folds into Jazz: 30 + 12.
        #expect(shape.depth(genre: "Jazz", decade: nil) == 42)
        #expect(shape.depth(genre: "Jazz", decade: 1950) == 42)
        #expect(shape.depth(genre: "Pop/Rock", decade: 2000) == 20)
        #expect(shape.depth(genre: "Jazz", decade: 1990) == 0)
    }

    /// The families are gathered on the way out, so one genre under two names
    /// is one genre — and a Norwegian children's genre is a children's genre.
    @Test("Genres are gathered into families")
    func familiesAreGathered() throws {
        let shape = try seeded().libraryShape()
        let jazz = try #require(shape.family(named: "Jazz"))
        #expect(Set(jazz.members) == ["Jazz", "Swing"])
        #expect(shape.family(matching: "Swing")?.name == "Jazz")
        #expect(shape.family(matching: "Barnesanger")?.name == "Children's")
    }

    /// The evidence the mixes are chosen from has to carry the same borrowed
    /// facts, or everything asking what decade someone listens to has nothing
    /// to read.
    @Test("Recently played songs carry the record's genre and year")
    func historyCarriesTheBorrowedFacts() throws {
        let played = try seeded().recentlyPlayedTracks(limit: 100)
        #expect(played.count == 42)
        #expect(played.allSatisfy { $0.genre != nil })
        #expect(played.allSatisfy { $0.year != nil })
        // Newest first.
        #expect(played.first?.genre == "Swing")
        #expect(played.first?.year == 1955)
    }

    /// A genre mix draws on every name the library files it under, not just
    /// the one the family is called by.
    @Test("A genre mix draws on the whole family")
    func mixDrawsOnEveryMemberOfTheFamily() throws {
        let index = try seeded()
        let songs = try index.mixTracks(
            .genresInDecade(genres: ["Jazz", "Swing"], decade: 1950),
            limit: 60,
            perArtist: 60
        )
        #expect(songs.count == 42)
    }

    /// And keeps to the decade it was asked for.
    @Test("A decade mix keeps to its decade")
    func mixKeepsToItsDecade() throws {
        let index = try seeded()
        let songs = try index.mixTracks(
            .genresInDecade(genres: ["Pop/Rock"], decade: 1950),
            limit: 60,
            perArtist: 60
        )
        #expect(songs.isEmpty)
    }

    /// No artist crowds the front of a mix.
    @Test("A mix is thinned so one artist cannot fill it")
    func oneArtistCannotFillAMix() throws {
        let index = try seeded()
        let songs = try index.mixTracks(
            .genresInDecade(genres: ["Jazz"], decade: 1950),
            limit: 6,
            perArtist: 2
        )
        // Only one artist has 1950s Jazz here, so the cap runs out and the
        // rest are topped up rather than the mix coming back short.
        #expect(songs.count == 6)
    }
}
