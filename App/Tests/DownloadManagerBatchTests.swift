import Foundation
import Testing
import PleviAudio
import PleviDomain
import PleviTransport
import PleviLibraryIndex
@testable import Plevi

/// Stop and Remove on a batch that is still being got ready, songs found in
/// another library, songs the index does not hold, and requests that overlap
/// (D-05, D-06, D-10, D-19, O-01).
@MainActor
@Suite("Stress: batches, sibling libraries and overlapping requests", .serialized)
struct DownloadManagerBatchTests {

    private func playlist(_ rig: DownloadRig) -> MediaID { MediaID(server: rig.server, rawValue: "pl") }

    /// One song at a time, each taking `delay` to get ready.
    private func slowPreparation(_ rig: DownloadRig, milliseconds: Int = 120) async {
        rig.settings.downloadTranscode = TranscodePolicy(threshold: .always, codec: "opus", targetBitRateKbps: 128)
        await rig.provider.setDownloadBehaviour(error: nil, delay: .milliseconds(milliseconds))
    }

    // MARK: D-06

    @Test("D-06: Stop reaches the songs of a batch that have not started being prepared")
    func stopMidBatch() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        await slowPreparation(rig)
        await rig.manager.start()
        let batch = Array(rig.tracks)
        let run = Task { await rig.manager.download(batch, reason: .playlist(playlist(rig))) }
        try await Task.sleep(for: .milliseconds(300))

        rig.manager.stopDownloading()
        await run.value

        #expect(rig.manager.states.isEmpty, "songs after the Stop were queued again")
        #expect(try rig.index.downloads().isEmpty)
        #expect(!rig.manager.isDownloading)
    }

    @Test("D-06: removing a playlist reaches the songs of its own batch that are still to come")
    func removeMidBatch() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        await slowPreparation(rig)
        await rig.manager.start()
        let pl = playlist(rig)
        let run = Task { await rig.manager.download(Array(rig.tracks), reason: .playlist(pl)) }
        try await Task.sleep(for: .milliseconds(300))

        rig.manager.remove(reason: .playlist(pl))
        await run.value

        #expect(try rig.index.downloads().isEmpty, "the rest of the batch put the playlist's songs back")
        #expect(!rig.manager.isRequested(.playlist(pl)))
    }

    @Test("D-06: removing one album does not stop an unrelated batch running beside it")
    func removeIsPerReason() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        await slowPreparation(rig, milliseconds: 60)
        await rig.manager.start()
        let mine = Array(rig.tracks.prefix(5)), other = MediaID(server: rig.server, rawValue: "other")
        let run = Task { await rig.manager.download(mine, reason: .playlist(playlist(rig))) }
        try await Task.sleep(for: .milliseconds(100))

        rig.manager.remove(reason: .album(other))
        await run.value

        #expect(try rig.index.downloads().count == 5)
    }

    // MARK: D-19

    @Test("D-19: two requests for one song that overlap both leave their reason behind")
    func overlappingRequestsKeepBothReasons() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        await rig.provider.setDownloadBehaviour(error: nil, delay: .milliseconds(300))
        await rig.manager.start()
        let track = rig.tracks[0]
        let album = MediaID(server: rig.server, rawValue: "al")
        let list = playlist(rig)

        async let first: Void = rig.manager.download([track], reason: .album(album))
        try await Task.sleep(for: .milliseconds(80))
        async let second: Void = rig.manager.download([track], reason: .playlist(list))
        _ = await (first, second)

        let row = try #require(try rig.index.download(forTrack: track.id))
        #expect(row.reasons == [DownloadReason.album(album).key, DownloadReason.playlist(list).key])
        #expect(rig.downloader.handedCount(of: track.id.rawValue) == 1, "one file, one transfer")
    }

    // MARK: D-05

    @Test("D-05: a song found in a sibling library is tracked under this library's key from start to finish")
    func siblingResultIsKeyedLocally() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let foreign = rig.tracks[0].rekeyed(to: ServerID())
        await rig.manager.start()

        await rig.manager.download([foreign], reason: .track(foreign.id))
        let handed = try #require(rig.downloader.handed.last)
        rig.land(handed.destination.lastPathComponent)
        rig.downloader.emit(foreign.id.rawValue, .finished(handed.destination))

        let local = MediaID(server: rig.server, rawValue: foreign.id.rawValue)
        #expect(await rig.waitUntil { rig.manager.state(for: local) == .done })
        // Asked about by either key, it is the same song.
        #expect(rig.manager.state(for: foreign.id) == .done)
        #expect(rig.manager.isDownloaded(foreign.id))
        #expect(rig.manager.fileURL(for: foreign.id) != nil)
        #expect(try rig.index.download(forTrack: local)?.state == .done)
    }

    @Test("D-05: a sibling-library song is not deleted when the watchdog rescues it")
    func siblingResultSurvivesARescue() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let foreign = rig.tracks[0].rekeyed(to: ServerID())
        await rig.manager.start()
        await rig.manager.download([foreign], reason: .track(foreign.id))
        rig.downloader.lose(foreign.id.rawValue)

        await rig.manager.sweepStuck()

        #expect(await rig.waitUntil { rig.downloader.handedCount(of: foreign.id.rawValue) == 2 })
        let local = MediaID(server: rig.server, rawValue: foreign.id.rawValue)
        #expect(try rig.index.download(forTrack: local) != nil, "the row survived the resume")
    }

    // MARK: D-10

    @Test("D-10: a queued song the index does not hold is asked for again from what was written down, not deleted")
    func resumeUsesTheRememberedTrack() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let outsider = try #require(rig.unindexed.first)
        #expect(try rig.index.track(id: outsider.id) == nil)
        try rig.index.saveDownload(DownloadRecord(
            trackId: outsider.id.rawValue, state: .queued, fileName: "x-orig.audio",
            requestedBy: ["playlist:p"], title: outsider.title
        ))

        await rig.manager.start()

        #expect(await rig.waitUntil { rig.downloader.handedCount(of: outsider.id.rawValue) == 1 })
        #expect(try rig.index.download(forTrack: outsider.id) != nil, "the row must not be discarded")
    }

    @Test("D-10: an old row with no title is described by the server, and asked for again")
    func resumeAsksTheServer() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let outsider = try #require(rig.unindexed.first)
        try rig.index.saveDownload(DownloadRecord(
            trackId: outsider.id.rawValue, state: .queued, requestedBy: ["playlist:p"]
        ))

        await rig.manager.start()

        #expect(await rig.waitUntil { rig.downloader.handedCount(of: outsider.id.rawValue) == 1 })
    }

    @Test("D-10: a queued song nobody knows is failed with a reason, and its row stays")
    func resumeNeverDeletes() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let ghost = MediaID(server: rig.server, rawValue: "no-such-song")
        try rig.index.saveDownload(DownloadRecord(
            trackId: ghost.rawValue, state: .queued, requestedBy: ["playlist:p"]
        ))

        await rig.manager.start()

        #expect(await rig.waitUntil { if case .failed = rig.manager.state(for: ghost) { true } else { false } })
        let row = try #require(try rig.index.download(forTrack: ghost))
        #expect(row.failure == "This song is no longer on the server.")
        #expect(row.state == .failed)
    }

    @Test("D-10: with the server out of reach the song waits, and is asked again when it is back")
    func unknownSongWaitsWhenOffline() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let ghost = MediaID(server: rig.server, rawValue: "no-such-song")
        try rig.index.saveDownload(DownloadRecord(
            trackId: ghost.rawValue, state: .queued, requestedBy: ["playlist:p"]
        ))
        rig.settings.offlineMode = true

        await rig.manager.start()

        #expect(rig.manager.state(for: ghost) == .queued)
        #expect(try rig.index.download(forTrack: ghost)?.state == .queued)
    }

    // MARK: downloads-03

    @Test("downloads-03: failed songs are neither kept nor on their way")
    func partitionSeparatesFailures() {
        let server = ServerID()
        func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }
        let partition = DownloadManager.partition([
            id("a"): .done, id("b"): .queued, id("c"): .running, id("d"): .failed("HTTP 401"),
        ])
        #expect(Set(partition.kept) == [id("a")])
        #expect(Set(partition.active) == [id("b"), id("c")])
        #expect(Set(partition.failed) == [id("d")])
    }

    @Test("downloads-03: a failed song can be tried again, with its attempts forgotten")
    func retryFailedStartsOver() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: .track(track.id))
        rig.downloader.emit(
            track.id.rawValue,
            .failed(.server(.serverError(code: 401, message: "HTTP 401", helpURL: nil)))
        )
        #expect(await rig.waitUntil { if case .failed = rig.manager.state(for: track.id) { true } else { false } })
        #expect(rig.manager.activeCount == 0, "a failed song is not counted as coming")

        await rig.manager.retryFailed([track.id])

        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 2 })
        #expect(rig.manager.state(for: track.id) != nil)
        if case .failed = rig.manager.state(for: track.id) { Issue.record("still failed after Try Again") }
    }

    // MARK: O-01

    @Test("O-01: removing everything and stopping leave no rows behind, however many there are")
    func bulkWrites() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        await rig.manager.start()
        await rig.manager.download(Array(rig.tracks), reason: .playlist(playlist(rig)))
        #expect(try rig.index.downloads().count == rig.tracks.count)

        rig.manager.stopDownloading()
        #expect(try rig.index.downloads().isEmpty)

        await rig.manager.download(Array(rig.tracks), reason: .playlist(playlist(rig)))
        rig.manager.removeEverything()
        #expect(try rig.index.downloads().isEmpty)
        #expect(rig.manager.states.isEmpty)
    }
}
