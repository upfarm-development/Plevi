import Foundation
import GRDB
import Testing
import PleviDomain
@testable import PleviLibraryIndex

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "persistence-safety-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct IndexOpeningTests {
    @Test func aCleanFileOpensAndIsLeftAlone() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "index.sqlite")

        guard case .opened = try LibraryIndexOpening.open(databaseURL: url, serverID: ServerID()) else {
            Issue.record("a new file should just open")
            return
        }
        guard case .opened = try LibraryIndexOpening.open(databaseURL: url, serverID: ServerID()) else {
            Issue.record("an existing good file should just open")
            return
        }
    }

    @Test func aDamagedFileIsSetAsideAndReplacedNotDeleted() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "index.sqlite")
        let garbage = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: url)
        // Sidecars of the bad file must not be read as the new file's.
        try Data("wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))

        let outcome = try LibraryIndexOpening.open(databaseURL: url, serverID: ServerID())
        guard case .rebuilt(let index, let quarantined) = outcome else {
            Issue.record("a file that is not a database should be rebuilt")
            return
        }
        // Usable: a sync can start.
        let generation = try index.beginSyncGeneration()
        try index.finishSync(generation: generation)
        // Kept, byte for byte, where it can still be looked at.
        #expect(try Data(contentsOf: quarantined) == garbage)
        #expect(FileManager.default.fileExists(atPath: quarantined.path + "-wal"))
    }

    @Test func classifiesDamageApartFromBadMoments() {
        struct Other: Error {}
        func migration(_ code: ResultCode) -> LibraryIndex.MigrationFailure {
            .init(underlying: DatabaseError(resultCode: code))
        }
        #expect(!LibraryIndexOpening.isDamage(Other()))
        #expect(!LibraryIndexOpening.isDamage(LibraryIndex.MigrationFailure(underlying: Other())))
        #expect(LibraryIndexOpening.isDamage(DatabaseError(resultCode: .SQLITE_NOTADB)))
        #expect(LibraryIndexOpening.isDamage(DatabaseError(resultCode: .SQLITE_CORRUPT)))
        // A busy, full or locked-away file opens fine a moment later.
        #expect(!LibraryIndexOpening.isDamage(DatabaseError(resultCode: .SQLITE_BUSY)))
        #expect(!LibraryIndexOpening.isDamage(DatabaseError(resultCode: .SQLITE_CANTOPEN)))
        #expect(!LibraryIndexOpening.isDamage(migration(.SQLITE_FULL)))
        #expect(LibraryIndexOpening.isDamage(migration(.SQLITE_ERROR)))
    }
}

@Suite struct SyncGenerationTests {
    private func track(_ id: String, server: ServerID) -> Track {
        Track(
            id: MediaID(server: server, rawValue: id), title: id,
            albumName: "A", albumID: MediaID(server: server, rawValue: "al"),
            artistName: "B", artistID: MediaID(server: server, rawValue: "ar"),
            trackNumber: 1, discNumber: 1, genre: nil, codec: "flac"
        )
    }

    @Test func aWalkCutOffPartWayDoesNotHandItsGenerationToTheNextOne() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)

        // A complete first sync.
        let first = try index.beginSyncGeneration()
        try index.upsertTracks([track("gone", server: server), track("kept", server: server)], generation: first)
        try index.finishSync(generation: first)

        // A second walk that writes some rows and is cut off before finishing.
        let second = try index.beginSyncGeneration()
        try index.upsertTracks([track("gone", server: server), track("kept", server: server)], generation: second)

        // "gone" is deleted on the server meanwhile; the next walk must not
        // be handed the interrupted walk's number.
        let third = try index.beginSyncGeneration()
        #expect(third > second)
        try index.upsertTracks([track("kept", server: server)], generation: third)
        try index.finishSync(generation: third)

        let ids = try index.tracks(ids: [
            MediaID(server: server, rawValue: "gone"), MediaID(server: server, rawValue: "kept"),
        ]).compactMap { $0 }.map(\.title)
        #expect(ids == ["kept"])
    }

    @Test func searchStillFindsRowsAfterEveryRebuild() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        for round in 1...3 {
            let generation = try index.beginSyncGeneration()
            try index.upsertTracks([track("song\(round)", server: server)], generation: generation)
            try index.finishSync(generation: generation)
        }
        let hits = try index.search("song3", limit: 10)
        #expect(!hits.tracks.isEmpty)
    }
}
