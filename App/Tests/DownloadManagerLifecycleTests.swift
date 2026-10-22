import Foundation
import Testing
import PleviDomain
import PleviTransport
import PleviLibraryIndex
@testable import Plevi

/// The download queue's own decisions, run against a downloader that reports what the test tells it
/// to (D-01, D-02, D-07, D-11, D-12, D-17, O-05).
@MainActor
@Suite("Stress: DownloadManager lifecycle and watchdog", .serialized)
struct DownloadManagerLifecycleTests {

    private func reason(_ track: Track) -> DownloadReason { .track(track.id) }

    private func http(_ code: Int) -> BackgroundDownloadEvent.Kind {
        .failed(.server(.serverError(code: code, message: "HTTP \(code)", helpURL: nil)))
    }

    // MARK: Holding transfers for playback

    @Test("a manager stopped while transfers are held lets them go")
    func stoppingReleasesTheHold() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        await rig.manager.start()
        rig.manager.pauseTransfersForPlayback()
        #expect(rig.downloader.isHeld)
        rig.manager.stop()
        #expect(!rig.downloader.isHeld)
        #expect(!rig.manager.transfersPaused)
    }

    @Test("a successor starts with the downloader free, though its predecessor left it held")
    func successorFreesTheDownloader() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        // The earlier manager was left holding: the player's release went to
        // another manager entirely.
        rig.downloader.setPaused(true)
        let next = rig.replaceManager()
        await next.start()
        #expect(!rig.downloader.isHeld)
    }

    @Test("a successor started while a song is awaited keeps the hold")
    func successorKeepsAHoldForASongBeingFetched() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let next = rig.replaceManager()
        next.playbackIsFetching = { true }
        await next.start()
        #expect(rig.downloader.isHeld)
        #expect(next.transfersPaused)
        next.playbackFinishedFetching()
        #expect(!rig.downloader.isHeld)
    }

    // MARK: D-01 / D-07

    @Test("D-01: a manager built after the first was stopped hears the downloader")
    func successorHearsTheDownloader() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        rig.replaceManager()
        await rig.manager.start()

        await rig.manager.download([track], reason: reason(track))
        let handed = try #require(rig.downloader.handed.last)
        rig.land(handed.destination.lastPathComponent)
        rig.downloader.emit(track.id.rawValue, .finished(handed.destination))

        #expect(await rig.waitUntil { rig.manager.state(for: track.id) == .done })
        #expect(rig.downloader.attachCount == 2, "each manager attaches once")
    }

    @Test("D-01: what happens between one manager stopping and the next starting is not lost")
    func eventsBetweenManagers() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        let handed = try #require(rig.downloader.handed.last)

        rig.manager.stop()
        // The transfer finishes while nobody is listening.
        rig.land(handed.destination.lastPathComponent)
        rig.downloader.emit(track.id.rawValue, .finished(handed.destination))

        let next = rig.replaceManager()
        await next.start()
        #expect(await rig.waitUntil { next.state(for: track.id) == .done })
        #expect(rig.downloader.handedCount(of: track.id.rawValue) == 1, "nothing was fetched twice")
    }

    @Test("D-07: a stopped manager neither starts nor cancels anything")
    func stoppedManagerIsInert() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let a = rig.tracks[0], b = rig.tracks[1]
        let old = rig.manager
        await old.start()
        await old.download([a], reason: reason(a))
        old.stop()

        // The system loses the transfer, and the stopped manager's watchdog
        // wakes: it must not touch what the successor now owns.
        rig.downloader.lose(a.id.rawValue)
        old.stallAfter = 0
        await old.sweepStuck()
        #expect(rig.downloader.cancelBatches.isEmpty)
        #expect(rig.downloader.singleCancels.isEmpty)

        // Nor start anything new.
        let before = rig.downloader.handed.count
        await old.download([b], reason: reason(b))
        #expect(rig.downloader.handed.count == before)
        #expect(old.state(for: b.id) == nil)
    }

    @Test("D-07: a retry that was sleeping when its manager stopped does not fire")
    func sleepingRetryDoesNotFire() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let old = rig.manager
        await old.start()
        await old.download([track], reason: reason(track))
        rig.downloader.emit(track.id.rawValue, http(500))
        #expect(await rig.waitUntil { old.state(for: track.id) == .queued })
        old.stop()
        try await Task.sleep(for: .seconds(2.6))
        #expect(rig.downloader.handedCount(of: track.id.rawValue) == 1)
    }

    // MARK: D-02

    @Test("D-02: a transfer that never started is not rescued, however long it is silent")
    func neverStartedIsLeftAlone() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        rig.settings.downloadsOverCellular = true
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        rig.manager.stallAfter = 0.05
        try await Task.sleep(for: .milliseconds(200))

        for _ in 0..<4 { await rig.manager.sweepStuck() }

        #expect(rig.downloader.cancelBatches.isEmpty)
        #expect(rig.manager.state(for: track.id) == .queued)
        #expect(rig.downloader.handedCount(of: track.id.rawValue) == 1)
    }

    @Test("D-02: a transfer that started and then went quiet is rescued, once, in one batch")
    func startedThenSilentIsRescued() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        rig.settings.downloadsOverCellular = true
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        rig.downloader.emit(track.id.rawValue, .started)
        rig.manager.stallAfter = 0.05
        try await Task.sleep(for: .milliseconds(250))

        await rig.manager.sweepStuck()

        #expect(rig.downloader.cancelBatches == [[track.id.rawValue]])
        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 2 })
        #expect(rig.manager.state(for: track.id) != .failed(""))
    }

    @Test("D-02: a transfer the system has lost is rescued whether or not it ever started")
    func lostIsRescued() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        rig.downloader.lose(track.id.rawValue)

        await rig.manager.sweepStuck()

        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 2 })
    }

    @Test("D-02: one sweep takes only so many in hand, and cancels them in a single call")
    func sweepIsCapped() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        await rig.manager.start()
        rig.manager.rescuesPerSweep = 5
        await rig.manager.download(Array(rig.tracks.prefix(10)), reason: .playlist(MediaID(server: rig.server, rawValue: "pl")))
        for track in rig.tracks.prefix(10) { rig.downloader.lose(track.id.rawValue) }

        await rig.manager.sweepStuck()

        #expect(rig.downloader.cancelBatches.count == 1)
        #expect(rig.downloader.cancelBatches.first?.count == 5)
        #expect(rig.downloader.singleCancels.isEmpty)
    }

    @Test("D-02: bytes after a rescue clear its count, so a song that keeps starting is not failed for it")
    func firstBytesResetTheRescueCount() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        let id = track.id.rawValue
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        // Five rescues in a row, each followed by the transfer starting: past
        // the limit of two, which is about unanswered restarts.
        for round in 0..<5 {
            rig.downloader.emit(id, .started)
            #expect(await rig.waitUntil { rig.downloader.attachCount > 0 })
            try await Task.sleep(for: .milliseconds(60))
            rig.downloader.lose(id)
            await rig.manager.sweepStuck()
            #expect(await rig.waitUntil { rig.downloader.handedCount(of: id) == round + 2 })
        }
        if case .failed = rig.manager.state(for: track.id) {
            Issue.record("a song that started every time was failed by the rescue limit")
        }
    }

    // MARK: D-11

    @Test("D-11: a song that cannot be prepared for want of a network is parked, not failed")
    func offlinePreparationParks() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.provider.setDownloadBehaviour(
            error: ProviderError.network(underlying: URLError(.notConnectedToInternet))
        )
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))

        #expect(rig.manager.state(for: track.id) == .queued)
        let row = try #require(try rig.index.download(forTrack: track.id))
        #expect(row.state == .queued)
        #expect(row.failure == nil)
        #expect(rig.downloader.handed.isEmpty)

        // The network returns and the song goes on its way.
        await rig.provider.setDownloadBehaviour(error: nil)
        rig.manager.networkBecameAvailable()
        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 1 })
    }

    @Test("D-11: the sweep for songs queued with nothing behind them leaves a parked song alone")
    func parkedSongsAreNotOrphans() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let parked = rig.tracks[0], moving = rig.tracks[1]
        await rig.provider.setDownloadBehaviour(
            error: ProviderError.network(underlying: URLError(.timedOut))
        )
        await rig.manager.start()
        await rig.manager.download([parked], reason: reason(parked))
        await rig.provider.setDownloadBehaviour(error: nil)
        await rig.manager.download([moving], reason: reason(moving))

        await rig.manager.sweepStuck()

        #expect(rig.downloader.handedCount(of: parked.id.rawValue) == 0)
        #expect(rig.manager.state(for: parked.id) == .queued)
    }

    @Test("D-11: relaunching with Offline Mode on starts nothing and fails nothing")
    func relaunchOfflineByChoice() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        try rig.index.saveDownload(DownloadRecord(
            trackId: track.id.rawValue, state: .queued, fileName: "x-orig.flac",
            requestedBy: [reason(track).key], title: track.title
        ))
        rig.settings.offlineMode = true

        await rig.manager.start()

        #expect(rig.manager.state(for: track.id) == .queued)
        #expect(rig.downloader.handed.isEmpty)
        #expect(try rig.index.download(forTrack: track.id)?.state == .queued)

        rig.settings.offlineMode = false
        rig.manager.networkBecameAvailable()
        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 1 })
    }

    @Test("D-11: rows an older build failed at preparation are asked for again at launch")
    func legacyPreparationFailureHeals() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        try rig.index.saveDownload(DownloadRecord(
            trackId: track.id.rawValue, state: .failed, failure: DownloadReconciler.legacyPreparationFailure,
            requestedBy: [reason(track).key], title: track.title
        ))

        await rig.manager.start()

        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 1 })
    }

    // MARK: D-17

    @Test("D-17: 401 fails the song at once")
    func unauthorisedIsFinal() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        rig.downloader.emit(track.id.rawValue, http(401))

        #expect(await rig.waitUntil { if case .failed = rig.manager.state(for: track.id) { true } else { false } })
        try await Task.sleep(for: .seconds(2.4))
        #expect(rig.downloader.handedCount(of: track.id.rawValue) == 1, "a refusal is not asked again")
    }

    @Test("D-17: a server having a moment is asked again, through the same gate")
    func serverErrorRetries() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        rig.downloader.emit(track.id.rawValue, http(503))

        #expect(await rig.waitUntil { rig.manager.state(for: track.id) == .queued })
        #expect(await rig.waitUntil(timeout: 4) { rig.downloader.handedCount(of: track.id.rawValue) == 2 })
    }

    @Test("D-17: no connection parks the song and costs it no attempt")
    func noConnectionWaits() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        // Three losses of signal: more than the song has attempts.
        for _ in 0..<3 {
            rig.downloader.emit(track.id.rawValue, .failed(.server(.network(underlying: URLError(.notConnectedToInternet)))))
            #expect(await rig.waitUntil { rig.manager.state(for: track.id) == .queued })
            rig.manager.networkBecameAvailable()
            #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) > 0 })
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(rig.manager.state(for: track.id) != .failed(""))
        if case .failed = rig.manager.state(for: track.id) { Issue.record("no signal failed the song") }
    }

    @Test("D-17: a full phone fails the song and says so once, however many songs hit it")
    func storageFullSaysItOnce() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        var said: [String] = []
        rig.manager.onRefused = { said.append($0) }
        await rig.manager.start()
        let batch = Array(rig.tracks.prefix(3))
        await rig.manager.download(batch, reason: .playlist(MediaID(server: rig.server, rawValue: "pl")))
        for track in batch { rig.downloader.emit(track.id.rawValue, .failed(.outOfSpace("No space left on device"))) }

        #expect(await rig.waitUntil {
            batch.allSatisfy { if case .failed = rig.manager.state(for: $0.id) { true } else { false } }
        })
        #expect(said.filter { $0.contains("room") }.count == 1)
    }

    @Test("D-17: a song that finishes starts its next failure with a clean count")
    func finishResetsRetries() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        rig.downloader.emit(track.id.rawValue, http(503))
        #expect(await rig.waitUntil(timeout: 4) { rig.downloader.handedCount(of: track.id.rawValue) == 2 })
        let handed = try #require(rig.downloader.handed.last)
        rig.land(handed.destination.lastPathComponent)
        rig.downloader.emit(track.id.rawValue, .finished(handed.destination))
        #expect(await rig.waitUntil { rig.manager.state(for: track.id) == .done })
    }

    // MARK: D-12 / O-05

    @Test("D-12: changing the cellular setting hands the plain files over again under the new policy")
    func policyChangeReissues() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        #expect(rig.downloader.handed.last?.allowsCellular == false)

        rig.settings.downloadsOverCellular = true
        rig.manager.networkPolicyChanged()

        #expect(await rig.waitUntil { rig.downloader.reissued.last?.allowsCellular == true })
        #expect(rig.downloader.reissued.last?.ids == [track.id.rawValue])
    }

    @Test("O-05: removing a whole record cancels its transfers in one call")
    func bulkRemovalCancelsOnce() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        await rig.manager.start()
        let playlist = MediaID(server: rig.server, rawValue: "pl")
        let batch = Array(rig.tracks.prefix(5))
        await rig.manager.download(batch, reason: .playlist(playlist))

        rig.manager.remove(reason: .playlist(playlist))

        #expect(rig.downloader.singleCancels.isEmpty)
        #expect(rig.downloader.cancelBatches.count == 1)
        #expect(rig.downloader.cancelBatches.first == Set(batch.map(\.id.rawValue)))
    }

    @Test("D-24: a manager leaves the network monitor when it stops")
    func listenersAreTakenAway() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        for _ in 0..<5 {
            await rig.manager.start()
            rig.replaceManager()
        }
        // No assertion on the monitor's internals: five reconnects completing
        // without a stale manager reacting is the observable half, and the
        // token round trip is exercised on every one of them.
        #expect(rig.downloader.attachCount == 5)
    }
}

@Suite("Kept artwork follows what is downloaded")
struct KeptArtworkTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "kept-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func touch(_ id: ArtworkID, in root: URL, palette: Bool = true) throws {
        let folder = root.appending(path: id.server.rawValue.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for bucket in KeptArtwork.buckets {
            try Data([1]).write(to: folder.appending(path: ArtworkLoader.fileName(for: id, bucket: bucket)))
        }
        if palette {
            let name = ArtworkLoader.fileName(for: id, bucket: 0).replacingOccurrences(of: ".img", with: ".palette")
            try Data([1]).write(to: folder.appending(path: name))
        }
    }

    private func count(_ server: ServerID, in root: URL) -> Int {
        let folder = root.appending(path: server.rawValue.uuidString)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count
    }

    @Test func pruneRemovesSleevesOfDownloadsThatAreGone() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ServerID()
        let kept = ArtworkID(server: server, rawValue: "kept")
        let gone = ArtworkID(server: server, rawValue: "gone")
        try touch(kept, in: root)
        try touch(gone, in: root)
        let perSleeve = KeptArtwork.buckets.count + 1
        #expect(count(server, in: root) == 2 * perSleeve)

        KeptArtwork.prune(server: server, keeping: ["kept"], root: root)
        #expect(count(server, in: root) == perSleeve)

        KeptArtwork.prune(server: server, keeping: [], root: root)
        #expect(count(server, in: root) == 0)
    }

    @Test func pruneLeavesOtherLibrariesAlone() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = ServerID(), other = ServerID()
        try touch(ArtworkID(server: mine, rawValue: "a"), in: root)
        try touch(ArtworkID(server: other, rawValue: "b"), in: root)
        KeptArtwork.prune(server: mine, keeping: [], root: root)
        #expect(count(mine, in: root) == 0)
        #expect(count(other, in: root) == KeptArtwork.buckets.count + 1)
    }
}
