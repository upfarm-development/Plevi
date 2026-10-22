import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

@Suite("What a mixer selection reaches in the library")
struct MixerTracksTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// One artist with two albums, a compilation carrying one of their songs,
    /// and a second artist — the shape every rule here is about.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("ar1"), name: "The Artist"),
            Artist(id: id("ar2"), name: "Another Artist"),
        ], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "First", artistName: "The Artist", artistID: id("ar1")),
            Album(id: id("al2"), name: "Second", artistName: "The Artist", artistID: id("ar1")),
            Album(id: id("al3"), name: "Other", artistName: "Another Artist", artistID: id("ar2")),
            Album(id: id("comp"), name: "A Compilation", artistName: "Various Artists"),
        ], generation: 1)
        try index.upsertTracks([
            track("t1", album: "al1", artist: "The Artist"),
            track("t2", album: "al1", artist: "The Artist"),
            track("t3", album: "al2", artist: "The Artist"),
            track("t4", album: "al3", artist: "Another Artist"),
            // The same artist, but on somebody else's record.
            track("t5", album: "comp", artist: "The Artist"),
            track("t6", album: "comp", artist: "Someone Else"),
            // Actively disliked, on an album that is otherwise wanted.
            track("t7", album: "al1", artist: "The Artist", stars: 1),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func track(
        _ raw: String, album: String, artist: String, stars: Double? = nil
    ) -> Track {
        Track(
            id: id(raw),
            title: raw,
            albumID: id(album),
            artistName: artist,
            rating: stars.flatMap(StarRating.init)
        )
    }

    @Test("An artist brings their own records, and not their guest spots")
    func artistMeansTheirOwnAlbums() throws {
        let index = try seeded()
        let tracks = try index.mixerTracks(artistIDs: [id("ar1")], albumIDs: [])
        // t5 is by this artist but sits on a compilation credited to Various
        // Artists — it is reachable by picking that album, not this one.
        #expect(Set(tracks.map(\.title)) == ["t1", "t2", "t3"])
    }

    @Test("An album brings its own songs, whoever they are by")
    func albumMeansItsOwnTracks() throws {
        let index = try seeded()
        let tracks = try index.mixerTracks(artistIDs: [], albumIDs: [id("comp")])
        #expect(Set(tracks.map(\.title)) == ["t5", "t6"])
    }

    @Test("An artist and one of their own albums together counts each song once")
    func overlappingSelectionDeduplicates() throws {
        let index = try seeded()
        let tracks = try index.mixerTracks(artistIDs: [id("ar1")], albumIDs: [id("al1")])
        #expect(tracks.count == 3)
        #expect(Set(tracks.map(\.title)) == ["t1", "t2", "t3"])
    }

    @Test("A song rated below the floor is left out of the selection entirely")
    func ratingFloorApplies() throws {
        let index = try seeded()
        let tracks = try index.mixerTracks(artistIDs: [id("ar1")], albumIDs: [id("al1")])
        #expect(tracks.contains { $0.title == "t7" } == false)
    }

    @Test("Artists and albums by different people combine")
    func selectionsCombine() throws {
        let index = try seeded()
        let tracks = try index.mixerTracks(artistIDs: [id("ar1")], albumIDs: [id("al3")])
        #expect(Set(tracks.map(\.title)) == ["t1", "t2", "t3", "t4"])
    }

    @Test("An empty selection asks the database nothing and reaches nothing")
    func emptySelectionIsEmpty() throws {
        let index = try seeded()
        #expect(try index.mixerTracks(artistIDs: [], albumIDs: []).isEmpty)
    }
}

@Suite("What the mixer grid offers")
struct MixerGridTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("rock1"), name: "Rock One"),
            Artist(id: id("rock2"), name: "Rock Two"),
            Artist(id: id("jazz1"), name: "Jazz One"),
        ], generation: 1)
        try index.upsertAlbums([
            Album(id: id("r1"), name: "Rock Record", artistName: "Rock One", artistID: id("rock1"),
                  genre: "Rock", playedAt: Date(timeIntervalSince1970: 300)),
            Album(id: id("r2"), name: "Another Rock", artistName: "Rock Two", artistID: id("rock2"),
                  genre: "Rock", playedAt: Date(timeIntervalSince1970: 200)),
            Album(id: id("j1"), name: "Jazz Record", artistName: "Jazz One", artistID: id("jazz1"),
                  genre: "Jazz", playedAt: Date(timeIntervalSince1970: 100)),
            // Never played, so it cannot appear among recently played.
            Album(id: id("r3"), name: "Unplayed Rock", artistName: "Rock Two", artistID: id("rock2"),
                  genre: "Rock"),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Recently played comes back newest first, with the artists behind it")
    func recentlyPlayed() throws {
        let index = try seeded()
        let found = try index.mixerRecentlyPlayed(limit: 9)
        #expect(found.albums.map(\.displayName) == ["Rock Record", "Another Rock", "Jazz Record"])
        #expect(found.artists.map(\.name) == ["Rock One", "Rock Two", "Jazz One"])
    }

    @Test("An artist with two recently played albums appears once, not twice")
    func recentlyPlayedDedupesAnArtist() throws {
        // A fixture of its own: every album here belongs to the one artist
        // whose two plays are meant to collide, plus a single decoy to prove
        // the dedup is per-artist and not just "keep the first album".
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("prolific"), name: "Prolific"),
            Artist(id: id("other"), name: "Other"),
        ], generation: 1)
        try index.upsertAlbums([
            Album(id: id("p1"), name: "First Play", artistName: "Prolific", artistID: id("prolific"),
                  playedAt: Date(timeIntervalSince1970: 300)),
            Album(id: id("o1"), name: "Other Play", artistName: "Other", artistID: id("other"),
                  playedAt: Date(timeIntervalSince1970: 200)),
            Album(id: id("p2"), name: "Second Play", artistName: "Prolific", artistID: id("prolific"),
                  playedAt: Date(timeIntervalSince1970: 100)),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let found = try index.mixerRecentlyPlayed(limit: 9)
        // Both of Prolific's albums are still here — dedup is an artist-list
        // concern, not a reason to drop a played record.
        #expect(found.albums.map(\.displayName) == ["First Play", "Other Play", "Second Play"])
        // But the artist behind them is named once, at the position their
        // most recent play earns — not once per album. Without the dedup in
        // `mixerRecentlyPlayed`, this would read ["Prolific", "Other", "Prolific"].
        #expect(found.artists.map(\.name) == ["Prolific", "Other"])
    }

    @Test("Neighbours share a genre with the selection")
    func neighboursShareGenre() throws {
        let index = try seeded()
        let found = try index.mixerNeighbours(artistIDs: [id("rock1")], albumIDs: [], limit: 9)
        // Jazz is nothing to do with the selection.
        #expect(found.albums.contains { $0.displayName == "Jazz Record" } == false)
        #expect(found.artists.contains { $0.name == "Jazz One" } == false)
        #expect(found.artists.map(\.name) == ["Rock Two"])
        // A positive check on the albums too, not only what they exclude —
        // an album query that regressed to always returning nothing would
        // still satisfy every `contains == false` assertion above.
        #expect(found.albums.map(\.displayName) == ["Another Rock", "Unplayed Rock"])
    }

    @Test("Nothing already picked is offered back as a suggestion")
    func neighboursExcludeTheSelection() throws {
        let index = try seeded()
        let found = try index.mixerNeighbours(artistIDs: [id("rock1")], albumIDs: [], limit: 9)
        // The picked artist's own records are not neighbours of themselves.
        // An equality check, not only a negative one: an empty result would
        // also satisfy "does not contain Rock Record".
        #expect(found.albums.map(\.displayName) == ["Another Rock", "Unplayed Rock"])
        #expect(found.artists.contains { $0.name == "Rock One" } == false)

        let byAlbum = try index.mixerNeighbours(artistIDs: [], albumIDs: [id("r1")], limit: 9)
        #expect(byAlbum.albums.map(\.displayName) == ["Another Rock", "Unplayed Rock"])
    }

    @Test("An empty selection has no neighbours to offer")
    func emptySelectionHasNoNeighbours() throws {
        let index = try seeded()
        let found = try index.mixerNeighbours(artistIDs: [], albumIDs: [], limit: 9)
        #expect(found.artists.isEmpty && found.albums.isEmpty)
    }
}
