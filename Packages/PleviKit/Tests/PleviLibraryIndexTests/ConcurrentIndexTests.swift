import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The index on a real file, which is the only place it is a pool.
@Suite("A real index file")
struct ConcurrentIndexTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "index-test-\(UUID().uuidString).sqlite")
    }

    private func tracks(_ count: Int, server: ServerID, artist: MediaID) -> [Track] {
        (0..<count).map { i in
            Track(
                id: MediaID(server: server, rawValue: "t\(i)"),
                title: "Song \(i)",
                artistName: "Television", artistID: artist,
                duration: 200
            )
        }
    }

    @Test("Writes go to the write-ahead log, which is what lets readers past")
    func runsInWALMode() throws {
        let url = temporaryURL()
        defer { for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        } }
        let server = ServerID()
        let index = try LibraryIndex(databaseURL: url, serverID: server)
        try index.upsertArtists([Artist(id: MediaID(server: server, rawValue: "ar1"), name: "Television")], generation: 1)

        // The sidecar is the observable half of "this is a pool, not a
        // queue": a rollback-journal database never grows one.
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    @Test("A read gets an answer while a long write is still open")
    func readsDoNotWaitForTheWriter() async throws {
        let url = temporaryURL()
        defer { for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        } }
        let server = ServerID()
        let artist = MediaID(server: server, rawValue: "ar1")
        let index = try LibraryIndex(databaseURL: url, serverID: server)
        try index.upsertArtists([Artist(id: artist, name: "Television")], generation: 1)
        try index.upsertTracks(tracks(50, server: server, artist: artist), generation: 1)
        try index.finishSync(generation: 1)

        // A sync-sized write, running while the reads below happen. On one
        // connection every one of them would queue behind it.
        let writing = Task.detached {
            let generation = try index.beginSyncGeneration()
            try index.upsertTracks(
                (0..<20_000).map { i in
                    Track(
                        id: MediaID(server: server, rawValue: "n\(i)"),
                        title: "New \(i)", artistName: "Television", artistID: artist,
                        duration: 200
                    )
                },
                generation: generation
            )
            try index.finishSync(generation: generation)
        }

        // The library as it was before the write opened.
        let started = Date()
        for _ in 0..<20 {
            _ = try index.stats()
        }
        let elapsed = Date().timeIntervalSince(started)

        try await writing.value
        #expect(elapsed < 5.0, "twenty reads took \(elapsed)s alongside one write")
        // And the write did land.
        #expect(try index.stats().trackCount == 20_000)
    }

    @Test("It is the same library after a reopen")
    func survivesAReopen() throws {
        let url = temporaryURL()
        defer { for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        } }
        let server = ServerID()
        let artist = MediaID(server: server, rawValue: "ar1")
        do {
            let index = try LibraryIndex(databaseURL: url, serverID: server)
            try index.upsertArtists([Artist(id: artist, name: "Television")], generation: 1)
            try index.upsertTracks(tracks(10, server: server, artist: artist), generation: 1)
            try index.finishSync(generation: 1)
            #expect(try index.lastSyncAt() != nil)
        }
        let reopened = try LibraryIndex(databaseURL: url, serverID: server)
        #expect(try reopened.stats().trackCount == 10)
        #expect(try reopened.lastSyncAt() != nil)
    }

    @Test("A library that has never synced has no date to go on")
    func neverSyncedHasNoDate() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        #expect(try index.lastSyncAt() == nil)
    }
}
