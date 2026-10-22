import Foundation
import Testing
import GRDB
import PleviDomain
@testable import PleviLibraryIndex

/// That an index built by an older build can still be written to.
@Suite("Schema upgrades")
struct SchemaUpgradeTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// A database file in a directory that cleans itself up.
    private func temporaryDatabase() throws -> (url: URL, cleanUp: () -> Void) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory.appendingPathComponent("library.sqlite"),
            { try? FileManager.default.removeItem(at: directory) }
        )
    }

    /// Writing one is the real test: the insert is what failed, not the read.
    private func acceptsAnAlbum(_ index: LibraryIndex) throws -> Bool {
        try index.upsertAlbums([
            Album(id: id("a"), name: "A Record", artistName: "Someone", year: 1974),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return try index.albums(ids: [id("a")]).count == 1
    }

    @Test("A fresh index takes an album")
    func freshIndex() throws {
        #expect(try acceptsAnAlbum(LibraryIndex(inMemoryFor: server)))
    }

    /// Cached artist pages from before Plex could answer "who sounds like
    /// this" are emptied, so the shelf is asked again — but only the ones
    /// that are actually empty.
    @Test("An artist page cached with no neighbours is asked again; a full one is not")
    func emptySimilarArtistsAreRefetched() throws {
        let (url, cleanUp) = try temporaryDatabase()
        defer { cleanUp() }

        let queue = try DatabaseQueue(path: url.path)
        try LibraryIndex.migrator.migrate(queue, upTo: "v21-songBrowsingIndexes")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artistInfo (artistId, biography, similarArtistIds, topTrackIds, fetchedAt)
                    VALUES ('empty', 'A life in music.', '', 't1', ?), ('full', 'Another.', 'ar2\u{1}ar3', 't2', ?)
                    """,
                arguments: [Date(), Date()]
            )
        }
        try queue.close()

        let index = try LibraryIndex(databaseURL: url, serverID: server)
        // The one with nothing to say is gone, and will be asked afresh the
        // next time its page is opened.
        #expect(try index.cachedArtistPage(for: id("empty")) == nil)
        // The one that had an answer keeps it, and its biography with it.
        let kept = try #require(try index.cachedArtistPage(for: id("full")))
        #expect(kept.biography == "Another.")
    }

    /// The exact shape of the bug: a database that already recorded
    /// `v18-trackOriginalYear` as applied, from the build where that
    /// migration did not create `album.isCollection`.
    @Test("An index left by the build that shipped v18 still takes an album")
    func databaseFromTheShippedV18() throws {
        let (url, cleanUp) = try temporaryDatabase()
        defer { cleanUp() }

        let queue = try DatabaseQueue(path: url.path)
        try LibraryIndex.migrator.migrate(queue, upTo: "v18-trackOriginalYear")
        // Proof the test is testing something: the column genuinely is not
        // there yet at that point in history.
        let before = try queue.read { try $0.columns(in: "album").map(\.name) }
        #expect(!before.contains("isCollection"))
        try queue.close()

        // Opening it with today's code is all a launch does.
        #expect(try acceptsAnAlbum(LibraryIndex(databaseURL: url, serverID: server)))
    }

    /// A device that installed the one build in which v18 *did* create the
    /// column already has it, and v20 must step over that rather than
    /// failing on a duplicate.
    @Test("An index that already has the column migrates without complaint")
    func databaseThatAlreadyHasTheColumn() throws {
        let (url, cleanUp) = try temporaryDatabase()
        defer { cleanUp() }

        let queue = try DatabaseQueue(path: url.path)
        try LibraryIndex.migrator.migrate(queue, upTo: "v18-trackOriginalYear")
        try queue.write { db in
            try db.alter(table: "album") { table in
                table.add(column: "isCollection", .boolean).notNull().defaults(to: false)
            }
        }
        try queue.close()

        #expect(try acceptsAnAlbum(LibraryIndex(databaseURL: url, serverID: server)))
    }

    /// A library that has been syncing for months has to come out of v24 looking like one that was
    /// walked, not one that never has been — the gate that skips a sync refuses to skip anything
    /// until a whole walk is on record, and an unfilled column…
    @Test("An index from before the change token knows when it was last walked")
    func theChangeTokenArrivesWithHistoryIntact() throws {
        let (url, cleanUp) = try temporaryDatabase()
        defer { cleanUp() }

        let synced = Date(timeIntervalSince1970: 1_700_000_000)
        let queue = try DatabaseQueue(path: url.path)
        try LibraryIndex.migrator.migrate(queue, upTo: "v23-playlistIndex")
        let before = try queue.read { try $0.columns(in: "syncState").map(\.name) }
        #expect(!before.contains("changeToken"))
        // A database as a shipped build left it: one sync behind it.
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO syncState (id, generation, lastSyncAt) VALUES (1, 7, ?)",
                arguments: [synced]
            )
        }
        try queue.close()

        _ = try LibraryIndex(databaseURL: url, serverID: server)
        let after = try DatabaseQueue(path: url.path)
        let columns = try after.read { try $0.columns(in: "syncState").map(\.name) }
        #expect(columns.contains("changeToken"))
        #expect(columns.contains("lastFullSyncAt"))
        let walked = try after.read {
            try Date.fetchOne($0, sql: "SELECT lastFullSyncAt FROM syncState WHERE id = 1")
        }
        #expect(walked == synced)
    }

    /// Every column `AlbumRecord` writes has to exist after a full migrate,
    /// whichever build the database started life under.
    @Test("Nothing an album is written with is missing from a migrated index")
    func noColumnIsMissing() throws {
        let (url, cleanUp) = try temporaryDatabase()
        defer { cleanUp() }

        let queue = try DatabaseQueue(path: url.path)
        try LibraryIndex.migrator.migrate(queue, upTo: "v18-trackOriginalYear")
        try queue.close()

        _ = try LibraryIndex(databaseURL: url, serverID: server)
        let after = try DatabaseQueue(path: url.path).read {
            try $0.columns(in: "album").map(\.name)
        }
        for column in ["isCollection", "criticRating", "review", "isCompilation", "releaseDate"] {
            #expect(after.contains(column), "album is missing \(column)")
        }
    }

    @Test("An index from before track popularity still takes a track")
    func trackPopularityArrivesOnAnOldDatabase() throws {
        let (url, cleanUp) = try temporaryDatabase()
        defer { cleanUp() }

        let queue = try DatabaseQueue(path: url.path)
        try LibraryIndex.migrator.migrate(queue, upTo: "v25-searchPhrases")
        let before = try queue.read { try $0.columns(in: "track").map(\.name) }
        #expect(!before.contains("popularity"))
        try queue.close()

        let index = try LibraryIndex(databaseURL: url, serverID: server)
        let after = try DatabaseQueue(path: url.path).read {
            try $0.columns(in: "track").map(\.name)
        }
        #expect(after.contains("popularity"))

        // And the column actually holds what is written to it, on an index
        // that started life without it.
        let generation = try index.beginSyncGeneration()
        try index.upsertArtists(
            [Artist(id: id("ar1"), name: "Someone")], generation: generation
        )
        try index.upsertAlbums(
            [Album(id: id("al1"), name: "A Record", artistName: "Someone", artistID: id("ar1"))],
            generation: generation
        )
        try index.upsertTracks(
            [Track(
                id: id("t1"), title: "A Song",
                albumName: "A Record", albumID: id("al1"),
                artistName: "Someone", artistID: id("ar1"),
                popularity: 42
            )],
            generation: generation
        )
        try index.finishSync(generation: generation)
        #expect(try index.track(id: id("t1"))?.popularity == 42)
    }

    /// A library indexed before anyone thought to ask the server for tempo gains the column without
    /// losing a thing.
    @Test("An index from before tempo takes a track, and keeps the BPM the server sends")
    func trackBpmArrivesOnAnOldDatabase() throws {
        let (url, cleanUp) = try temporaryDatabase()
        defer { cleanUp() }

        let queue = try DatabaseQueue(path: url.path)
        try LibraryIndex.migrator.migrate(queue, upTo: "v29-downloadQueueOrder")
        let before = try queue.read { try $0.columns(in: "track").map(\.name) }
        #expect(!before.contains("bpm"))
        try queue.close()

        let index = try LibraryIndex(databaseURL: url, serverID: server)
        let after = try DatabaseQueue(path: url.path).read {
            try $0.columns(in: "track").map(\.name)
        }
        #expect(after.contains("bpm"))

        let generation = try index.beginSyncGeneration()
        try index.upsertArtists(
            [Artist(id: id("ar1"), name: "Someone")], generation: generation
        )
        try index.upsertAlbums(
            [Album(id: id("al1"), name: "A Record", artistName: "Someone", artistID: id("ar1"))],
            generation: generation
        )
        try index.upsertTracks(
            [
                Track(
                    id: id("t1"), title: "A Tagged Song",
                    albumName: "A Record", albumID: id("al1"),
                    artistName: "Someone", artistID: id("ar1"),
                    bpm: 128
                ),
                Track(
                    id: id("t2"), title: "An Untagged Song",
                    albumName: "A Record", albumID: id("al1"),
                    artistName: "Someone", artistID: id("ar1")
                ),
            ],
            generation: generation
        )
        try index.finishSync(generation: generation)

        #expect(try index.track(id: id("t1"))?.bpm == 128)
        // And a song the server said nothing about reads as nil rather than
        // as a tempo of zero, which is the whole point of the optional.
        #expect(try index.track(id: id("t2"))?.bpm == nil)
    }

    /// A watch or phone that has been keeping music since before there was a
    /// queue gains the column without losing what it holds — and the songs
    /// already on it read as "not owed", which is what a null means here.
    @Test("An index from before the download queue gains the column, keeping what it holds")
    func queueOrderArrivesOnAnOldDatabase() throws {
        let (url, cleanUp) = try temporaryDatabase()
        defer { cleanUp() }

        let queue = try DatabaseQueue(path: url.path)
        try LibraryIndex.migrator.migrate(queue, upTo: "v28-searchColumns")
        let before = try queue.read { try $0.columns(in: "download").map(\.name) }
        #expect(!before.contains("queueOrder"))
        // A database as a shipped build left it: one song already kept.
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO download (trackId, state, fileName, variant, addedAt, requestedBy, title)"
                    + " VALUES ('t1', 'done', 'abc-orig.flac', 'orig', ?, 'album:al1', 'First')",
                arguments: [Date()]
            )
        }
        try queue.close()

        let index = try LibraryIndex(databaseURL: url, serverID: server)
        let after = try DatabaseQueue(path: url.path).read {
            try $0.columns(in: "download").map(\.name)
        }
        #expect(after.contains("queueOrder"))

        // The song it was already keeping is still there, still done, and is
        // not owed.
        let kept = try #require(try index.download(forTrack: id("t1")))
        #expect(kept.state == .done)
        #expect(kept.title == "First")
        #expect(kept.queueOrder == nil)
        #expect(try index.downloads().count == 1)
        // And nothing is queued, because nothing is.
        #expect(try index.queuedDownloads().isEmpty)
        #expect(try index.highestQueueOrder() == nil)
    }

    /// The queue reads in the order songs were asked for, which is the one
    /// thing `addedAt` could not be made to say.
    @Test("The queue lists what is owed, oldest first, and forgets it on demand")
    func queueOrderIsTheQueue() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        // Asked for third, second, first — so that an accidental fallback to
        // insertion order, or to `addedAt`, shows up as the wrong answer.
        for (track, place) in [("t3", 3), ("t2", 2), ("t1", 1)] {
            try index.saveDownload(DownloadRecord(
                trackId: track, state: .queued, variant: "c-mp3-128",
                title: track.uppercased(), queueOrder: place
            ))
        }
        // One already here, which is not owed and must stay out of the queue.
        try index.saveDownload(DownloadRecord(
            trackId: "t0", state: .done, fileName: "t0-orig.flac", title: "T0"
        ))

        #expect(try index.queuedDownloads().map(\.trackId) == ["t1", "t2", "t3"])
        #expect(try index.highestQueueOrder() == 3)
        #expect(try index.downloads().count == 4)

        try index.clearQueueOrder()
        #expect(try index.queuedDownloads().isEmpty)
        #expect(try index.highestQueueOrder() == nil)
        // Clearing the order is not deleting anything: every song is still on
        // the device, and the one that was done is still done.
        #expect(try index.downloads().count == 4)
        #expect(try index.download(forTrack: id("t0"))?.state == .done)
    }
}
