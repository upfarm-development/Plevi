import Foundation
import Testing
import GRDB
import PleviDomain
@testable import PleviLibraryIndex

/// The copy of a library that goes to another device.
@Suite("Snapshots of a library")
struct SnapshotTests {
    private let server = ServerID()

    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// An on-disk index, because a snapshot is a file operation and the
    /// in-memory initialiser has no file to vacuum out of.
    private func seeded() throws -> (index: LibraryIndex, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = try LibraryIndex(
            databaseURL: directory.appending(path: "index.sqlite"),
            serverID: server
        )
        let artist = id("ar1")
        try index.upsertArtists([Artist(id: artist, name: "Aurora Skies")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Daybreak", artistName: "Aurora Skies", artistID: artist),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "First", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist, trackNumber: 1, discNumber: 1),
            Track(id: id("t2"), title: "Second", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist, trackNumber: 2, discNumber: 1),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return (index, directory)
    }

    @Test("The catalogue arrives whole")
    func carriesTheCatalogue() throws {
        let (index, directory) = try seeded()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "snapshot.sqlite")
        try index.snapshot(to: file)

        let copy = try LibraryIndex(databaseURL: file, serverID: server)
        let stats = try copy.stats()
        #expect(stats.artistCount == 1)
        #expect(stats.albumCount == 1)
        #expect(stats.trackCount == 2)
        // Not merely the counts: a track read back whole, since that is what
        // a receiving device actually draws.
        #expect(try copy.track(id: id("t1"))?.title == "First")
        #expect(try copy.tracks(inAlbum: id("al1")).map(\.title) == ["First", "Second"])
    }

    @Test("What belonged to this device stays behind")
    func leavesDeviceLocalRowsBehind() throws {
        let (index, directory) = try seeded()
        defer { try? FileManager.default.removeItem(at: directory) }

        try index.saveDownload(DownloadRecord(
            trackId: "t1", state: .done, fileName: "abc-orig.flac",
            addedAt: Date(timeIntervalSince1970: 100), requestedBy: ["album:al1"]
        ))
        try index.saveDownloadedPlaylist(DownloadedPlaylistRecord(
            id: "pl1", name: "Sunday Morning", trackIds: ["t1", "t2"]
        ))
        try index.storeWaveform([0.1, 0.2, 0.3], forTrack: id("t1"))
        try index.enqueueChange(OutboxRecord(kind: .favorite, itemId: "t1", mediaKind: "track", flag: true))

        let file = directory.appending(path: "snapshot.sqlite")
        try index.snapshot(to: file)

        let copy = try LibraryIndex(databaseURL: file, serverID: server)
        #expect(try copy.downloads().isEmpty)
        #expect(try copy.downloadedPlaylists().isEmpty)
        #expect(try copy.waveform(forTrack: id("t1")) == nil)
        #expect(try copy.pendingChangeCount() == 0)
        // And the originals are untouched: a snapshot reads, it does not
        // move anything out of the library it copies.
        #expect(try index.downloads().count == 1)
        #expect(try index.pendingChangeCount() == 1)
    }

    @Test("A playlist the copy has no songs for knows it has no songs for it")
    func forgetsThatMembersWereFetched() throws {
        let (index, directory) = try seeded()
        defer { try? FileManager.default.removeItem(at: directory) }

        try index.saveIndexedPlaylists([
            IndexedPlaylistRecord(id: "pl1", name: "Løpe"),
        ])
        try index.saveMembers(ofPlaylist: "pl1", trackIds: ["t1", "t2"])
        // Fetched here, so this device would not ask again.
        #expect(try index.playlistsAwaitingMembers(matching: "løpe").isEmpty)

        let file = directory.appending(path: "snapshot.sqlite")
        try index.snapshot(to: file)

        // The members themselves are device-local and stay behind.
        let copy = try LibraryIndex(databaseURL: file, serverID: server)
        #expect(try copy.playlistsAwaitingMembers(matching: "løpe").map(\.name) == ["Løpe"])
        // And the device that made the copy has not forgotten anything.
        #expect(try index.playlistsAwaitingMembers(matching: "løpe").isEmpty)
    }

    @Test("The copy is a whole database, search table and all")
    func staysAWholeDatabase() throws {
        let (index, directory) = try seeded()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "snapshot.sqlite")
        try index.snapshot(to: file)

        // Opening it with the ordinary initialiser is the real assertion:
        // that runs the migrator, which would fail or re-run migrations if
        // the trimming had left the schema inconsistent.
        let copy = try LibraryIndex(databaseURL: file, serverID: server)
        // The search table is emptied, not removed — so a receiver that
        // decides to search can fill it rather than migrate around a hole.
        #expect(try copy.search("First", limit: 10).tracks.isEmpty)
        // And it still works as a search table, which a dropped-and-not-
        // recreated one would not.
        try copy.upsertTracks([
            Track(id: id("t3"), title: "Third", albumName: "Daybreak", albumID: id("al1")),
        ], generation: 2)
        try copy.finishSync(generation: 2)
        #expect(try copy.search("Third", limit: 10).tracks.count == 1)
    }

    /// Measured against a plain copy rather than against the source file.
    @Test("Dropping the search table is most of the saving")
    func isSmallerThanAnUntrimmedCopy() throws {
        let (index, directory) = try seeded()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Enough tracks that the search table is a real fraction of the file
        // rather than a rounding error on a page or two.
        let many = (0..<2000).map { i in
            Track(
                id: id("m\(i)"),
                title: "A song with a reasonably long title number \(i)",
                albumName: "Daybreak", albumID: id("al1"),
                artistName: "Aurora Skies", artistID: id("ar1")
            )
        }
        try index.upsertTracks(many, generation: 2)
        try index.finishSync(generation: 2)

        let plain = directory.appending(path: "plain.sqlite")
        let source = try DatabaseQueue(path: directory.appending(path: "index.sqlite").path)
        try source.vacuum(into: plain.path)
        try source.close()

        let trimmed = directory.appending(path: "snapshot.sqlite")
        try index.snapshot(to: trimmed)

        let whole = Self.size(of: plain)
        let small = Self.size(of: trimmed)
        #expect(small > 0)
        #expect(small < whole)
        // Not a marginal saving: on the real library it is 73 MB against 29.
        #expect(Double(small) < Double(whole) * 0.75)
    }

    @Test("Snapshotting twice over the same path works")
    func overwritesAPreviousSnapshot() throws {
        let (index, directory) = try seeded()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "snapshot.sqlite")
        try index.snapshot(to: file)
        // VACUUM INTO refuses an existing file, so a second send to the same
        // path is the case that would break if the cleanup were dropped.
        try index.snapshot(to: file)

        // Asserted before the file is opened: opening it puts a database in
        // WAL mode and writes its own -wal and -shm, so this is only a
        // question about what the *transfer* carries.
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: file.path + "-shm"))

        let copy = try LibraryIndex(databaseURL: file, serverID: server)
        #expect(try copy.stats().trackCount == 2)
    }

    private static func size(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}
