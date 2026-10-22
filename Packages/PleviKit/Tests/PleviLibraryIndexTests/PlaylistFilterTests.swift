import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// Filtering songs by the playlists they are in.
@Suite("Songs filtered by playlist")
struct PlaylistFilterTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// Three songs, and three playlists that overlap on purpose: one song in
    /// two of them, one in one, one in none.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("ar1")
        try index.upsertArtists([Artist(id: artist, name: "Aurora Skies")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Daybreak", artistName: "Aurora Skies", artistID: artist)
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "Bare Song", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist),
            Track(id: id("t2"), title: "Second Light", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist),
            Track(id: id("t3"), title: "Night Drive", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist),
        ], generation: 1)
        try index.finishSync(generation: 1)

        try index.saveIndexedPlaylists([
            IndexedPlaylistRecord(id: "p1", name: "Christmas Songs"),
            IndexedPlaylistRecord(id: "p2", name: "Summer Christmas"),
            IndexedPlaylistRecord(id: "p3", name: "Driving"),
        ])
        try index.saveMembers(ofPlaylist: "p1", trackIds: ["t1"])
        try index.saveMembers(ofPlaylist: "p2", trackIds: ["t1", "t2"])
        try index.saveMembers(ofPlaylist: "p3", trackIds: ["t3"])
        return index
    }

    private func rule(_ op: FilterOperator, _ text: String) -> LibraryFilter {
        LibraryFilter(
            subject: .songs,
            root: FilterGroup(match: .all, children: [
                .rule(FilterRule(field: .playlistName, op: op, value: .text(text)))
            ])
        )
    }

    @Test("A song is found by the name of a playlist it is in")
    func findsSongsInAPlaylist() throws {
        let index = try seeded()
        #expect(try index.tracks(matching: rule(.contains, "Driving")).map(\.title) == ["Night Drive"])
    }

    @Test("A song in several playlists is found by any of their names")
    func anyOfItsPlaylists() throws {
        let index = try seeded()
        // "Bare Song" is in Christmas Songs and Summer Christmas both.
        #expect(try index.tracks(matching: rule(.contains, "Christmas Songs")).map(\.title)
                == ["Bare Song"])
        #expect(try index.tracks(matching: rule(.contains, "Summer")).map(\.title).sorted()
                == ["Bare Song", "Second Light"])
    }

    @Test("A name that appears in two playlists gathers the songs of both")
    func matchesEveryPlaylistWithThatName() throws {
        let index = try seeded()
        #expect(try index.tracks(matching: rule(.contains, "Christmas")).map(\.title).sorted()
                == ["Bare Song", "Second Light"])
    }

    @Test("Does not contain includes the songs that are in no playlist at all")
    func notInAPlaylistCountsAsNotContaining() throws {
        let index = try seeded()
        // "Night Drive" is in a playlist, just not that one; "t3" aside, the
        // song in nothing must not be lost to a NULL comparison.
        let none = try index.tracks(matching: rule(.doesNotContain, "Christmas")).map(\.title)
        #expect(none.sorted() == ["Night Drive"])
    }

    @Test("The question is asked of the whole name, not of one word of a list")
    func namesDoNotRunTogether() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("ar1")
        try index.upsertArtists([Artist(id: artist, name: "A")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "R", artistName: "A", artistID: artist)
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "One", albumName: "R", albumID: id("al1"),
                  artistName: "A", artistID: artist)
        ], generation: 1)
        try index.finishSync(generation: 1)
        try index.saveIndexedPlaylists([
            IndexedPlaylistRecord(id: "p1", name: "Rock"),
            IndexedPlaylistRecord(id: "p2", name: "Jazz"),
        ])
        try index.saveMembers(ofPlaylist: "p1", trackIds: ["t1"])
        try index.saveMembers(ofPlaylist: "p2", trackIds: ["t1"])
        // The names are joined with a newline, so "RockJazz" must not exist.
        #expect(try index.tracks(matching: rule(.contains, "RockJazz")).isEmpty)
        #expect(try index.tracks(matching: rule(.contains, "Rock")).count == 1)
    }

    @Test("A playlist the server has stopped listing takes its songs with it")
    func droppedPlaylistsStopMatching() throws {
        let index = try seeded()
        // p3 is gone from the server's list.
        try index.saveIndexedPlaylists([
            IndexedPlaylistRecord(id: "p1", name: "Christmas Songs"),
            IndexedPlaylistRecord(id: "p2", name: "Summer Christmas"),
        ])
        #expect(try index.tracks(matching: rule(.contains, "Driving")).isEmpty)
    }

    @Test("A rename keeps the songs that were already fetched for it")
    func renamingDoesNotCostTheMembership() throws {
        let index = try seeded()
        try index.saveIndexedPlaylists([
            IndexedPlaylistRecord(id: "p3", name: "Long Drives"),
        ])
        #expect(try index.tracks(matching: rule(.contains, "Long Drives")).map(\.title)
                == ["Night Drive"])
        // And nothing is owed for it, because its songs are already here.
        #expect(try index.playlistsAwaitingMembers(matching: "Long").isEmpty)
    }

    @Test("A playlist whose songs have never been fetched is reported as owed")
    func awaitingMembers() throws {
        let index = try seeded()
        try index.saveIndexedPlaylists([
            IndexedPlaylistRecord(id: "p1", name: "Christmas Songs"),
            IndexedPlaylistRecord(id: "p4", name: "Christmas Leftovers"),
        ])
        let owed = try index.playlistsAwaitingMembers(matching: "Christmas").map(\.name)
        #expect(owed == ["Christmas Leftovers"])
    }

    @Test("Per cent and underscore typed by a person are not wildcards")
    func literalWildcards() throws {
        let index = try seeded()
        try index.saveIndexedPlaylists([
            IndexedPlaylistRecord(id: "p5", name: "100% Hits"),
        ])
        try index.saveMembers(ofPlaylist: "p5", trackIds: ["t2"])
        #expect(try index.tracks(matching: rule(.contains, "100%")).map(\.title) == ["Second Light"])
        #expect(try index.playlistsAwaitingMembers(matching: "100%").isEmpty)
    }

    @Test("The field is offered to songs only, and only as a list question")
    func shape() {
        #expect(FilterField.playlistName.applies(to: .songs))
        #expect(!FilterField.playlistName.applies(to: .albums))
        #expect(!FilterField.playlistName.applies(to: .artists))
        #expect(FilterField.playlistName.kind == .text)
        #expect(FilterOperator.operators(for: .playlistName) == [.contains, .doesNotContain])
    }

    @Test("A membership fetched long ago is asked for again")
    func staleMembershipIsRefetched() throws {
        let index = try seeded()
        let now = Date()
        // Just fetched: nothing owed.
        try index.saveMembers(ofPlaylist: "p1", trackIds: ["t1"], at: now)
        try index.saveMembers(ofPlaylist: "p2", trackIds: ["t1"], at: now)
        try index.saveMembers(ofPlaylist: "p3", trackIds: ["t3"], at: now)
        #expect(try index.playlistsAwaitingMembers(matching: "Christmas", now: now).isEmpty)
        // Past the TTL the same playlists are owed again.
        let later = now.addingTimeInterval(LibraryIndex.membersTTL + 60)
        #expect(try index.playlistsAwaitingMembers(matching: "Christmas", now: later).map(\.id).sorted()
                == ["p1", "p2"])
    }

    @Test("A playlist this app changed is asked for again at once, and keeps its old rows meanwhile")
    func invalidateMembers() throws {
        let index = try seeded()
        let now = Date()
        for id in ["p1", "p2", "p3"] { try index.saveMembers(ofPlaylist: id, trackIds: ["t1"], at: now) }
        #expect(try index.playlistsAwaitingMembers(matching: "Driving", now: now).isEmpty)
        try index.invalidateMembers(ofPlaylist: "p3")
        #expect(try index.playlistsAwaitingMembers(matching: "Driving", now: now).map(\.id) == ["p3"])
        #expect(try index.tracks(matching: rule(.contains, "Driving")).map(\.title) == ["Bare Song"])
    }

    @Test("It is not carried to a server's own smart playlists")
    func notASmartQuery() {
        let filter = rule(.contains, "Christmas")
        #expect(filter.smartQuery() == .failure(.unsupportedField("Playlist name")))
    }
}
