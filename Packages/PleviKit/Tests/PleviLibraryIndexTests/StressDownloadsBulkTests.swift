import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The bulk download writes (O-01): correct, and one transaction each.
@Suite("Stress: bulk download writes")
struct StressDownloadsBulkTests {
    private let server = ServerID()

    private func record(_ id: Int) -> DownloadRecord {
        DownloadRecord(trackId: "t\(id)", state: .queued, requestedBy: ["playlist:p"], title: "Song \(id)")
    }

    @Test("Several records are saved together and read back")
    func saveMany() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.saveDownloads((0..<50).map(record))
        #expect(try index.downloads().count == 50)
        try index.saveDownloads([])
        #expect(try index.downloads().count == 50)
    }

    @Test("Deleting a list of tracks removes just those")
    func deleteSome() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.saveDownloads((0..<10).map(record))
        try index.deleteDownloads(forTracks: (0..<4).map { MediaID(server: server, rawValue: "t\($0)") })
        let left = Set(try index.downloads().map(\.trackId))
        #expect(left == Set((4..<10).map { "t\($0)" }))
        try index.deleteDownloads(forTracks: [])
        #expect(try index.downloads().count == 6)
    }

    @Test("Deleting every download leaves the playlists that were kept, and nothing else of the table")
    func deleteAll() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.saveDownloads((0..<10).map(record))
        try index.saveDownloadedPlaylist(DownloadedPlaylistRecord(id: "p", name: "Sunday", artworkId: nil, trackIds: []))
        try index.deleteAllDownloads()
        #expect(try index.downloads().isEmpty)
        #expect(try index.downloadedPlaylists().count == 1)
    }

    @Test("A large removal is not a transaction per song")
    func largeRemovalIsFast() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.saveDownloads((0..<5_000).map(record))
        let ids = (0..<5_000).map { MediaID(server: server, rawValue: "t\($0)") }
        let clock = ContinuousClock()
        let took = try clock.measure { try index.deleteDownloads(forTracks: ids) }
        #expect(try index.downloads().isEmpty)
        // Generous: the point is that it is not thousands of commits.
        #expect(took < .seconds(2), "took \(took)")
    }
}
