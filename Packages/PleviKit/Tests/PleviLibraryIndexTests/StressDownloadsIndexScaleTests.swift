import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The download table at the scale Alice worries about — one artist of ten thousand tracks asked
/// for at once — and the two properties of the index that `DownloadManager` leans on without saying
/// so.
@Suite("Stress: downloads table at scale", .serialized)
struct StressDownloadsIndexScaleTests {
    private let server = ServerID()

    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func fileBackedIndex() throws -> (LibraryIndex, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StressDownloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "index.sqlite")
        return (try LibraryIndex(databaseURL: url, serverID: server), directory)
    }

    private func milliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try work()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    // MARK: Identity

    @Test("The index answers for a track whatever server the id claims — it is keyed by the raw id alone")
    func lookupsIgnoreTheServerOfTheID() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertTracks([Track(id: id("t1"), title: "One")], generation: 1)
        try index.finishSync(generation: 1)
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done, fileName: "x.flac"))

        let stranger = MediaID(server: ServerID(), rawValue: "t1")
        // The row comes back stamped with the index's own server, not the one asked about.
        let found = try #require(try index.track(id: stranger))
        #expect(found.id.server == server)
        #expect(found.id != stranger)
        #expect(try index.download(forTrack: stranger)?.trackId == "t1")

        // And a raw id the index has never seen is simply absent: the state
        // `DownloadManager.resume` reads as "the library no longer has it"
        // and answers by deleting the download and its file (D-10).
        #expect(try index.track(id: MediaID(server: server, rawValue: "t-from-another-library")) == nil)
    }

    @Test("A download record outlives its track being pruned from the library")
    func downloadsSurviveASyncThatDropsTheTrack() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertTracks([Track(id: id("t1"), title: "One"), Track(id: id("t2"), title: "Two")], generation: 1)
        try index.finishSync(generation: 1)
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done, fileName: "a.flac", title: "One"))
        try index.saveDownload(DownloadRecord(trackId: "t2", state: .queued, fileName: "b.flac", title: "Two"))

        // The next sync no longer sees t1 and t2 (a partial listing, a
        // library rescanned, the wrong section).
        try index.upsertTracks([Track(id: id("t3"), title: "Three")], generation: 2)
        try index.finishSync(generation: 2)

        #expect(try index.track(id: id("t1")) == nil)
        #expect(try index.download(forTrack: id("t1"))?.state == .done)
        // Which is why `resume(_:)` — reading `index.track` alone — is the
        // dangerous door: the queued one has a record and no track.
        #expect(try index.track(id: id("t2")) == nil)
        #expect(try index.download(forTrack: id("t2"))?.state == .queued)
        // The record can still describe itself, so a caller that used it
        // (as `DownloadManager.track(_:)` does) would have had what it needs.
        #expect(try index.download(forTrack: id("t2"))?.rememberedTrack(server: server)?.title == "Two")
    }

    // MARK: Scale

    @Test("Ten thousand songs: the per-song reads and writes DownloadManager makes on the main actor")
    func tenThousandRowsOneAtATime() throws {
        let (index, directory) = try fileBackedIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = 10_000

        // Prepared: `enqueue` reads the row, then writes it.
        var readMs = 0.0
        var writeMs = 0.0
        for n in 0..<count {
            let trackID = id("track-\(n)")
            var record = DownloadRecord(trackId: trackID.rawValue, state: .queued)
            readMs += try milliseconds { record = try index.download(forTrack: trackID) ?? record }
            record.title = "Song \(n)"
            record.state = .queued
            record.fileName = "\(n)-orig.flac"
            record.setReasons(["artist:ar1"])
            writeMs += try milliseconds { try index.saveDownload(record) }
        }
        let prepare = readMs + writeMs
        #expect(try index.downloads().count == count)

        // Landed: `handle(.finished)` reads the row, then writes it.
        let land = try milliseconds {
            for n in 0..<count {
                let trackID = id("track-\(n)")
                guard var record = try index.download(forTrack: trackID) else { continue }
                record.state = .done
                record.bytes = 30_000_000
                try index.saveDownload(record)
            }
        }

        // The Downloads screen's rebuild: every row, every time it is redrawn.
        let listing = try milliseconds { _ = try index.downloads() }

        // Remove All: one write transaction per song, from `removeEverything`.
        let remove = try milliseconds {
            for n in 0..<count { try index.deleteDownload(forTrack: id("track-\(n)")) }
        }
        #expect(try index.downloads().isEmpty)

        print(String(
            format: "STRESS-O01 %d songs, file-backed: prepare %.0f ms (%.2f ms/song; reads %.0f ms, writes %.0f ms), land %.0f ms (%.2f ms/song), downloads() %.0f ms, remove-all %.0f ms (%.2f ms/song)",
            count, prepare, prepare / Double(count), readMs, writeMs, land, land / Double(count), listing, remove, remove / Double(count)
        ))
    }

    @Test("Ten thousand songs: what the Downloads screen asks the index for on every rebuild")
    func downloadsScreenRebuild() throws {
        let (index, directory) = try fileBackedIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        let artists = 100, albumsPerArtist = 10, tracksPerAlbum = 10
        try index.upsertArtists((0..<artists).map { Artist(id: id("ar\($0)"), name: "Artist \($0)") }, generation: 1)
        var albums: [Album] = []
        var tracks: [Track] = []
        for artist in 0..<artists {
            for album in 0..<albumsPerArtist {
                let albumID = id("al\(artist)-\(album)")
                albums.append(Album(id: albumID, name: "Album \(album)", artistName: "Artist \(artist)", artistID: id("ar\(artist)")))
                for track in 0..<tracksPerAlbum {
                    tracks.append(Track(
                        id: id("t\(artist)-\(album)-\(track)"), title: "Song \(track)",
                        albumName: "Album \(album)", albumID: albumID,
                        artistName: "Artist \(artist)", artistID: id("ar\(artist)"),
                        trackNumber: track + 1, discNumber: 1
                    ))
                }
            }
        }
        try index.upsertAlbums(albums, generation: 1)
        try index.upsertTracks(tracks, generation: 1)
        try index.finishSync(generation: 1)
        for track in tracks {
            var record = DownloadRecord(trackId: track.id.rawValue, state: .done, fileName: "\(track.id.rawValue).flac")
            record.setReasons(["artist:\(track.artistID?.rawValue ?? "")"])
            try index.saveDownload(record)
        }

        // `deliberate()`: all the records, then one "albums of this artist
        // that arrived" query and one artist lookup per artist.
        var albumsFound = 0
        var artistIDs = Set<String>()
        let fetchAll = try milliseconds {
            for record in try index.downloads() {
                for reason in record.reasons where reason.hasPrefix("artist:") { artistIDs.insert(String(reason.dropFirst(7))) }
            }
        }
        let perArtistAlbums = try milliseconds {
            for raw in artistIDs {
                albumsFound += try index.albums(forArtist: id(raw), downloadedOnly: true).count
            }
        }
        let perArtistRow = try milliseconds {
            for raw in artistIDs { _ = try index.artist(id: id(raw)) }
        }
        let rebuild = fetchAll + perArtistAlbums + perArtistRow
        #expect(albumsFound == artists * albumsPerArtist)
        print(String(
            format: "STRESS-O02 Downloads rebuild at 10,000 songs / 1,000 albums / 100 artists: %.0f ms of synchronous index work per rebuild (downloads() %.0f, albums(forArtist:downloadedOnly:) x%d %.0f, artist(id:) x%d %.0f)",
            rebuild, fetchAll, artistIDs.count, perArtistAlbums, artistIDs.count, perArtistRow
        ))
    }
}
