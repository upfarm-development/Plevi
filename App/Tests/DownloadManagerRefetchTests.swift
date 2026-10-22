import Foundation
import Testing
import PleviAudio
import PleviDomain
import PleviTransport
import PleviLibraryIndex
@testable import Plevi

/// Fetching a song again at another quality, and the launch reconciliation
/// (D-04, D-15, downloads-16 / persistence-15 / persistence-21).
@MainActor
@Suite("Stress: refetch safety and launch reconciliation", .serialized)
struct DownloadManagerRefetchTests {

    private func reason(_ track: Track) -> String { DownloadReason.track(track.id).key }

    private func originalName(_ track: Track) -> String {
        DownloadStore.fileName(for: track.id, variant: .original, fileExtension: "flac")
    }

    /// A finished original download of `track`, on disk and in the index.
    private func keep(_ track: Track, in rig: DownloadRig) throws -> String {
        let name = originalName(track)
        rig.land(name)
        try rig.index.saveDownload(DownloadRecord(
            trackId: track.id.rawValue, state: .done, fileName: name, bytes: 4096,
            variant: MediaVariant.original.tag, requestedBy: [reason(track)], title: track.title,
            duration: track.duration
        ))
        return name
    }

    private func convertEverything(_ rig: DownloadRig) {
        rig.settings.downloadTranscode = TranscodePolicy(threshold: .always, codec: "opus", targetBitRateKbps: 128)
    }

    private func startedRefetch(_ rig: DownloadRig, _ track: Track) async throws -> (old: String, oldURL: URL) {
        let old = try keep(track, in: rig)
        await rig.manager.start()
        #expect(rig.manager.state(for: track.id) == .done)
        let oldURL = try #require(rig.manager.fileURL(for: track.id))
        convertEverything(rig)
        await rig.manager.refetchAtCurrentQuality()
        return (old, oldURL)
    }

    // MARK: D-04

    @Test("D-04: the old copy keeps playing while its replacement is on the way")
    func oldCopyPlaysDuringRefetch() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let (old, oldURL) = try await startedRefetch(rig, track)

        #expect(rig.downloader.handedCount(of: track.id.rawValue) == 1, "the replacement was asked for")
        #expect(rig.manager.state(for: track.id) == .queued)
        #expect(rig.manager.fileURL(for: track.id) == oldURL, "the song still plays from its old file")
        #expect(rig.manager.isDownloaded(track.id))
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        let row = try #require(try rig.index.download(forTrack: track.id))
        #expect(row.previousFileName == old)
        #expect(row.fileName != old)
    }

    @Test("D-04: the old copy goes only once the new one has landed")
    func oldCopyGoesWhenReplaced() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let (old, oldURL) = try await startedRefetch(rig, track)
        let handed = try #require(rig.downloader.handed.last)

        // Near what the conversion should come to, or it would be taken for a
        // fragment and asked for again.
        let expected = estimatedConversionBytes(kbps: 128, duration: track.duration) ?? 4_000_000
        rig.land(handed.destination.lastPathComponent, bytes: Int(expected))
        rig.downloader.emit(track.id.rawValue, .finished(handed.destination))

        #expect(await rig.waitUntil { rig.manager.state(for: track.id) == .done })
        #expect(rig.manager.fileURL(for: track.id)?.lastPathComponent == handed.destination.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path), "the replaced copy is deleted")
        let row = try #require(try rig.index.download(forTrack: track.id))
        #expect(row.previousFileName == nil)
        #expect(row.fileName != old)
    }

    @Test("D-04: a replacement that fails for good puts the old copy back")
    func failedRefetchRestores() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let (old, oldURL) = try await startedRefetch(rig, track)

        rig.downloader.emit(
            track.id.rawValue,
            .failed(.server(.serverError(code: 401, message: "HTTP 401", helpURL: nil)))
        )

        #expect(await rig.waitUntil { rig.manager.state(for: track.id) == .done })
        #expect(rig.manager.fileURL(for: track.id) == oldURL)
        let row = try #require(try rig.index.download(forTrack: track.id))
        #expect(row.state == .done)
        #expect(row.fileName == old)
        #expect(row.previousFileName == nil)
        #expect(row.variant == MediaVariant.original.tag)
    }

    @Test("D-04: quitting mid-replacement does not cost the song its old file at the next launch")
    func launchSweepSparesThePreviousCopy() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let (_, oldURL) = try await startedRefetch(rig, track)

        // The app goes away with the replacement not yet arrived.
        let next = rig.replaceManager()
        await next.start()

        #expect(FileManager.default.fileExists(atPath: oldURL.path), "the sweep must not delete the copy being replaced")
        #expect(next.fileURL(for: track.id) == oldURL)
    }

    @Test("D-04: calling the batch off puts the song back as it was")
    func stopRestores() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let (old, oldURL) = try await startedRefetch(rig, track)

        rig.manager.stopDownloading()

        #expect(rig.manager.state(for: track.id) == .done)
        #expect(rig.manager.fileURL(for: track.id) == oldURL)
        let row = try #require(try rig.index.download(forTrack: track.id))
        #expect(row.fileName == old)
        #expect(row.state == .done)
    }

    @Test("D-04: a replacement that cannot even be asked for leaves the song alone")
    func unpreparedRefetchLeavesTheSongDone() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let old = try keep(track, in: rig)
        await rig.manager.start()
        convertEverything(rig)
        await rig.provider.setDownloadBehaviour(error: ProviderError.serverError(code: 500, message: nil, helpURL: nil))

        await rig.manager.refetchAtCurrentQuality()

        // Marking it failed would have stopped a perfectly good file playing.
        #expect(rig.manager.state(for: track.id) == .done)
        #expect(rig.manager.fileURL(for: track.id) != nil)
        #expect(try rig.index.download(forTrack: track.id)?.fileName == old)
    }

    // MARK: downloads-16 / D-15

    @Test("downloads-16: a table that cannot be read does not cost the phone its downloads")
    func unreadableTableKeepsTheFiles() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let name = try keep(track, in: rig)
        rig.manager.recordLoader = { throw URLError(.cannotOpenFile) }

        await rig.manager.start()

        #expect(FileManager.default.fileExists(atPath: rig.store.url(named: name).path))
        // And the manager is still listening: a transfer that ends is heard.
        #expect(rig.downloader.attachCount == 1)
    }

    @Test("persistence-14: files next to an empty table are left alone, as after the index was rebuilt")
    func emptyTableIsNotASweep() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let survivor = rig.land("survivor-orig.flac")

        await rig.manager.start()

        #expect(FileManager.default.fileExists(atPath: survivor.path))
    }

    @Test("D-15: a file with no row is swept, and one a row names is not, whether or not the row is done")
    func sweepKeepsWhatRowsName() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let kept = rig.tracks[0], arriving = rig.tracks[1]
        let keptName = try keep(kept, in: rig)
        // A row that is still waiting and whose file has just landed.
        let arrivingName = originalName(arriving)
        try rig.index.saveDownload(DownloadRecord(
            trackId: arriving.id.rawValue, state: .running, fileName: arrivingName,
            requestedBy: [reason(arriving)], title: arriving.title
        ))
        rig.land(arrivingName)
        let stray = rig.land("stray-orig.flac")

        await rig.manager.start()

        #expect(FileManager.default.fileExists(atPath: rig.store.url(named: keptName).path))
        #expect(FileManager.default.fileExists(atPath: rig.store.url(named: arrivingName).path))
        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }

    @Test("A zero-byte file marked done is asked for again")
    func emptyFileHeals() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let name = originalName(track)
        rig.land(name, bytes: 0)
        try rig.index.saveDownload(DownloadRecord(
            trackId: track.id.rawValue, state: .done, fileName: name,
            requestedBy: [reason(track)], title: track.title
        ))

        await rig.manager.start()

        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 1 })
        #expect(rig.manager.state(for: track.id) != .done)
    }

    @Test("D-16: the conversion clean-up runs to the end and is remembered, not repeated at every launch")
    func conversionSweepIsRemembered() async throws {
        let rig = try await DownloadRig()
        let key = "downloads.conversionSweepDone.\(rig.store.directory.lastPathComponent)"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            rig.finish()
        }
        let track = rig.tracks[0]
        let variant = MediaVariant.converted(codec: "opus", kbps: 128)
        let name = DownloadStore.fileName(for: track.id, variant: variant, fileExtension: "opus")
        rig.land(name)
        try rig.index.saveDownload(DownloadRecord(
            trackId: track.id.rawValue, state: .done, fileName: name, variant: variant.tag,
            requestedBy: [reason(track)], title: track.title
        ))
        #expect(!UserDefaults.standard.bool(forKey: key))

        await rig.manager.start()

        #expect(await rig.waitUntil { UserDefaults.standard.bool(forKey: key) })
        #expect(rig.downloader.handed.isEmpty, "a finished download is not fetched again to be cleaned up")
    }
}
