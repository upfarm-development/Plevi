import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The record a downloaded playlist is kept as, and the columns the refresh added to it.
@Suite("A downloaded playlist's record")
struct DownloadedPlaylistSyncTests {
    private let server = ServerID()

    private func index() throws -> LibraryIndex {
        try LibraryIndex(inMemoryFor: server)
    }

    @Test("A playlist written without sync details reads back as never checked")
    func defaultsForOlderRows() throws {
        let index = try index()
        try index.saveDownloadedPlaylist(
            DownloadedPlaylistRecord(id: "88", name: "Sunday Morning", trackIds: ["1", "2", "3"])
        )

        let read = try #require(try index.downloadedPlaylist(
            id: MediaID(server: server, rawValue: "88")
        ))
        #expect(read.name == "Sunday Morning")
        #expect(read.tracks == ["1", "2", "3"])
        // Never compared with the server, and not known to be missing — which
        // is what a playlist downloaded before any of this existed is.
        #expect(read.checkedAt == nil)
        #expect(read.missingFromServer == false)
    }

    @Test("A refresh writes back the new membership, name and check time")
    func refreshedRow() throws {
        let index = try index()
        let id = MediaID(server: server, rawValue: "88")
        try index.saveDownloadedPlaylist(
            DownloadedPlaylistRecord(id: "88", name: "Sunday Morning", trackIds: ["1", "2", "3"])
        )

        let checked = Date(timeIntervalSince1970: 1_770_000_000)
        try index.saveDownloadedPlaylist(
            DownloadedPlaylistRecord(
                id: "88",
                name: "Sunday Mornings",
                trackIds: ["2", "3", "4"],
                checkedAt: checked
            )
        )

        let read = try #require(try index.downloadedPlaylist(id: id))
        #expect(read.name == "Sunday Mornings")
        // Order is part of what is stored: a playlist reordered on the server
        // is reordered on the phone.
        #expect(read.tracks == ["2", "3", "4"])
        #expect(read.checkedAt == checked)
        #expect(read.missingFromServer == false)
    }

    @Test("A playlist gone from the server is marked, not deleted")
    func markedMissing() throws {
        let index = try index()
        let id = MediaID(server: server, rawValue: "88")
        try index.saveDownloadedPlaylist(
            DownloadedPlaylistRecord(
                id: "88",
                name: "Sunday Morning",
                trackIds: ["1", "2"],
                missingFromServer: true
            )
        )

        let read = try #require(try index.downloadedPlaylist(id: id))
        #expect(read.missingFromServer)
        // Still every song it had. Losing somebody's last copy is the one
        // outcome this must never produce.
        #expect(read.tracks == ["1", "2"])
        #expect(try index.downloadedPlaylists().count == 1)
    }

    @Test("An empty playlist reads back as empty rather than as one blank song")
    func emptyMembership() throws {
        let index = try index()
        try index.saveDownloadedPlaylist(
            DownloadedPlaylistRecord(id: "88", name: "Emptied", trackIds: [])
        )

        let read = try #require(try index.downloadedPlaylist(
            id: MediaID(server: server, rawValue: "88")
        ))
        #expect(read.tracks.isEmpty)
    }
}
