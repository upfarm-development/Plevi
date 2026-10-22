import Foundation
import PleviDomain
import PleviAudio
import PleviLibraryIndex
import PleviTransport

/// The download queue: what has been asked for, what is on the phone, and how far along everything
/// else is.
@MainActor
@Observable
final class DownloadManager {
    enum State: Equatable, Sendable {
        case queued
        case running
        case done
        case failed(String)

        var isFinished: Bool { self == .done }
        /// Actually being fetched, as opposed to waiting its turn.
        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
        var isActive: Bool {
            switch self {
            case .queued, .running: true
            case .done, .failed: false
            }
        }
    }

    private(set) var states: [MediaID: State] = [:]

    /// How far each running transfer has got, kept apart from `states`.
    private(set) var fractions: [MediaID: Double] = [:]
    /// When each song was asked for, mirrored in memory.
    private var askedAt: [MediaID: Date] = [:]
    /// When each transfer's row was last written back, so a moving byte
    /// count is not a write to the database several times a second.
    private var lastProgressWrite: [MediaID: Date] = [:]
    /// When each running transfer last showed any sign of life, for the
    /// watchdog. Separate from `lastProgressWrite`, which is throttled to
    /// keep the database quiet and so cannot answer "is this still moving".
    private var lastActivity: [MediaID: Date] = [:]
    /// How many times a stuck transfer has been picked up and started again,
    /// so a song the server will never send does not restart forever.
    private var rescues: [MediaID: Int] = [:]
    private var watchdog: Task<Void, Never>?
    /// When the current run of transfers began, and how many it started
    /// with — so a setting that changes how many go at once can be judged by
    /// a clock rather than by how it felt.
    private var batchStarted: Date?
    private var batchSize = 0
    /// Songs already counted into this batch, so a transfer that is parked,
    /// resumed and retried is one song rather than three.
    private var counted: Set<MediaID> = []
    /// How many of `counted` are over, done or failed alike. Kept as a tally
    /// so `batchProgress` does not have to walk the batch — see there.
    private var finishedInBatch = 0
    /// Which of `counted` have already been tallied, so a song that reports
    /// done twice, or fails after finishing, counts once.
    private var tallied: Set<MediaID> = []
    /// Bytes landed during this batch, for a rate that does not depend on
    /// how long the songs happen to be.
    private var batchBytes: Int64 = 0
    /// Songs already looked up, so the Downloads screen does not go to the database once per row
    /// every time it rebuilds its lists.
    private var known: [MediaID: Track] = [:]
    /// What each kept file actually is, as it was fetched.
    private var variants: [MediaID: MediaVariant] = [:]
    /// The albums, playlists, artists and songs that were asked for, by
    /// reason key. What a menu reads to know whether it is offering to keep
    /// something or to let it go.
    private(set) var requested: Set<String> = []
    /// Bumped whenever anything changes, for views that summarise rather than
    /// watch one track.
    private(set) var version = 0
    /// True once the download table has been read into memory by `start()`.
    private(set) var hasReadRecords = false

    private let store: DownloadStore
    /// Pictures kept beside converted downloads, which lose theirs in the
    /// conversion. See `EmbeddedArtStore`.
    private let artStore: EmbeddedArtStore
    /// The library this manager was made for, kept beside the index it was
    /// handed so the two can be checked against each other — see `start()`.
    private let serverID: ServerID
    private let index: LibraryIndex
    private let provider: any MusicServerProvider
    private let downloader: any BackgroundDownloading
    /// For conversions the server will only give us as a playlist of
    /// segments: those are fetched and joined here rather than handed to the
    /// system, because a background transfer is one URL and one file.
    private let transport: any HTTPTransport
    /// Whether the connection costs money by the megabyte.
    private let network: NetworkPathMonitor
    private let settings: AppSettings
    /// Where the sign-in cookie for a server behind an SSO proxy comes from.
    /// A background transfer cannot ask for one itself, so every request is
    /// stamped with it on the way out.
    private let proxySessions: (any ProxySessionSource)?
    private var events: Task<Void, Never>?
    /// Set by `stop()` and never cleared: a replaced manager is finished, and must not act on the
    /// shared index or the shared downloader again.
    private var isStopped = false
    /// The listeners this manager has on the shared network monitor.
    private var networkListener: Int?
    private var pathListener: Int?

    /// Transfers whose first bytes have arrived.
    private var started: Set<MediaID> = []
    /// Songs that could not be got ready, or could not be fetched, for want of
    /// a network: parked as `.queued` with nothing behind them, and started
    /// again when a connection returns or Offline Mode goes off.
    private var heldForNetwork: Set<MediaID> = []
    /// How many times a song has been parked for want of a network since one
    /// last arrived, so a server that is down cannot park it for ever.
    private var preparationWaits: [MediaID: Int] = [:]
    private static let preparationWaitLimit = 6
    /// Said once per batch, like the Wi-Fi notice.
    private var saidStorageFull = false
    /// Set when a sign-in page has been met: every transfer that follows
    /// would meet the same one, so nothing more is handed over until the
    /// user has signed in (which reconnects, which builds a new manager).
    private var wallRaised = false
    /// Told once, with the page that was in the way when there is one.
    var onProxyWall: ((URL?) -> Void)?

    /// Room to get songs ready. Retries, rescues and a relaunch's re-requests
    /// all ask the server a question per song, and none of them used to share
    /// the six-wide limit a fresh batch keeps to.
    private var slotsInUse = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    /// Transfers to cancel together at the end of a bulk removal, instead of
    /// one full walk of the session's tasks per song.
    private var cancelBatch: Set<String>?
    /// Reasons per track, mirrored from the table so a removal does not need
    /// to go to disk for every song.
    private var reasons: [MediaID: Set<String>] = [:]
    private var fileNames: [MediaID: String] = [:]
    /// The copy a song had before a replacement was asked for, while the
    /// replacement is on its way — see `DownloadRecord.previousFileName`.
    /// Mirrored here so playback can fall back to it without the database.
    private var previousFileNames: [MediaID: String] = [:]
    /// The clean-up of conversions an older build left open on the server.
    private var conversionSweep: Task<Void, Never>?
    /// Tracks between "asked for" and "handed to the system".
    private var preparing: Set<MediaID> = []

    /// Bumped by `stopDownloading()` and `removeEverything()` — a Stop that only means it for the
    /// songs already in `states`.
    private var stopGeneration = 0

    /// Bumped whenever a reason is taken away, per reason: Remove Download on an album or a
    /// playlist while its own songs are still being got ready.
    private var reasonEpoch: [String: Int] = [:]

    /// What a batch noted when it began.
    private struct Batch {
        let generation: Int
        let reason: String?
        let epoch: Int
    }

    private func beginBatch(reason: String?) -> Batch {
        Batch(
            generation: stopGeneration,
            reason: reason,
            epoch: reason.map { reasonEpoch[$0, default: 0] } ?? 0
        )
    }

    private func isCurrent(_ batch: Batch) -> Bool {
        guard !isStopped, batch.generation == stopGeneration else { return false }
        guard let reason = batch.reason else { return true }
        return reasonEpoch[reason, default: 0] == batch.epoch
    }

    /// Everything handed over and not yet finished, and everything waiting for a turn.
    private var inFlight: Set<MediaID> = []
    private var waiting: [(id: MediaID, request: URLRequest, fileName: String, isConversion: Bool)] = []
    /// Conversions in flight.
    private var convertingNow: Set<MediaID> = []
    /// One at a time. Two was enough to make a server converting a playlist
    /// trip over itself: the first requests came back unparseable while it
    /// was still spinning up the others.
    private static let conversionsAtOnce = 1

    /// Whether there is room to start another.
    private func hasRoom(forConversion isConversion: Bool) -> Bool {
        guard isConversion else { return true }
        guard mayUseThisNetwork else { return false }
        // Not while somebody is waiting to hear a song.
        guard !(playbackIsFetching?() ?? false) else { return false }
        return convertingNow.count < Self.conversionsAtOnce
    }

    /// Whether the song being listened to is being converted right now. Set
    /// by the app; nil where there is no player, as on the first launch.
    var playbackIsFetching: (() -> Bool)?

    /// Conversions stopped part-way so the listener's song could have the
    /// server to itself. Started again the moment it does not need it.
    private var heldForPlayback: Set<MediaID> = []

    /// Gets out of the way of a song somebody is waiting to hear.
    private(set) var transfersPaused = false

    /// Holds the system's transfers while a song somebody is waiting for
    /// arrives. They are held, not cancelled, and carry on from where they
    /// were when `playbackFinishedFetching` lets them go.
    func pauseTransfersForPlayback() {
        guard !transfersPaused else { return }
        transfersPaused = true
        downloader.setPaused(true)
    }

    private func resumeTransfersAfterPlayback() {
        guard transfersPaused else { return }
        transfersPaused = false
        // Silence while held is not a stall.
        let now = Date()
        for id in inFlight { lastActivity[id] = now }
        downloader.setPaused(false)
    }

    func yieldToPlayback(cancellingConversions: Bool = true) async {
        pauseTransfersForPlayback()
        guard cancellingConversions else { return }
        // Taken once, up front.
        let converting = convertingNow
        guard !converting.isEmpty else { return }
        for id in converting {
            heldForPlayback.insert(id)
            downloader.cancel(id: id.rawValue)
            // The transfer and the work behind it.
            await provider.endConversion(for: id)
            inFlight.remove(id)
            convertingNow.remove(id)
            started.remove(id)
            lastActivity[id] = nil
            states[id] = .queued
            if var record = try? index.download(forTrack: id) {
                record.state = .queued
                record.failure = nil
                try? index.saveDownload(record)
            }
        }
        bump()
    }

    /// Starts whatever was held back. Called when the listener stops
    /// waiting on the server.
    func playbackFinishedFetching() {
        resumeTransfersAfterPlayback()
        let held = heldForPlayback
        heldForPlayback = []
        for id in held {
            guard let track = track(id) else { continue }
            let reason = (try? index.download(forTrack: id))?.reasons.first
                ?? DownloadReason.track(id).key
            // `retrying` so this does not count against the song's own
            // attempts: nothing went wrong with it, it was asked to wait.
            Task { [weak self] in await self?.enqueue(track, reason: reason, retrying: true) }
        }
        drain()
    }

    /// Whether this connection is one the listener has agreed to spend, for the one kind of
    /// transfer that has to ask before it starts: a conversion, fetched through the app's own
    /// transport rather than the system's.
    private var mayUseThisNetwork: Bool {
        settings.downloadsOverCellular || !network.isExpensive || spendingAnyway
    }

    /// Whether cellular access itself should be granted to a request or a system transfer,
    /// regardless of what network happens to be active right now.
    private var permitsCellular: Bool {
        settings.downloadsOverCellular || spendingAnyway
    }

    /// Whether the listener has said "go on then" for what is queued now.
    private(set) var spendingAnyway = false

    /// Starts what is being held, on this connection, this once.
    func downloadAnyway() {
        guard !spendingAnyway else { return }
        spendingAnyway = true
        drain()
        reissuePlainFiles()
        // If nothing was actually waiting, there is nothing to spend the permission on —
        // `forgetAnywayIfIdle` sees the queue already empty and takes it straight back, rather than
        // leaving it standing for a download that was never coming.
        forgetAnywayIfIdle()
    }

    /// Whether anything is being held back for a network it may not use —
    /// which is the only time there is anything to say yes to.
    var isWaitingForNetwork: Bool {
        guard !mayUseThisNetwork else { return false }
        // Parked conversions, or plain files the system was told not to start
        // on this connection and has not.
        return !waiting.isEmpty
            || inFlight.contains { !convertingNow.contains($0) && !started.contains($0) }
    }

    /// How many songs are on their way or waiting to be, for the badge on
    /// the Downloads tab. Counted rather than stored: `states` is the truth
    /// and a second number beside it is a number that goes wrong.
    var activeCount: Int {
        states.values.count { $0.isActive }
    }

    /// Starts a transfer, or puts it in the queue if there is no room.
    private func begin(
        _ id: MediaID,
        request: URLRequest,
        fileName: String,
        isConversion: Bool
    ) {
        guard !isStopped else { return }
        // A sign-in page is in the way. Held, not failed: signing in
        // reconnects, and the new manager starts what is queued.
        guard !wallRaised else {
            heldForNetwork.insert(id)
            return
        }
        // Counted here rather than where the songs were asked for.
        if !counted.contains(id) {
            counted.insert(id)
            if batchStarted == nil { batchStarted = Date() }
            batchSize += 1
        }
        guard hasRoom(forConversion: isConversion) else {
            if !waiting.contains(where: { $0.id == id }) {
                waiting.append((id, request, fileName, isConversion))
            }
            // Nothing appearing to happen is the one answer worse than
            // downloading it anyway. Said once for the batch.
            if !mayUseThisNetwork { sayWaitingForWiFi() }
            return
        }
        inFlight.insert(id)
        lastActivity[id] = Date()
        startWatchdogIfNeeded()
        if isConversion { convertingNow.insert(id) }
        hand(id, request: request, fileName: fileName)
        // A plain file handed over on a connection it may not use is held by
        // the system with nothing to report, and looked exactly like a
        // transfer that was working. Say so.
        if !isConversion, !mayUseThisNetwork { sayWaitingForWiFi() }
    }

    private func sayWaitingForWiFi() {
        guard !saidWaitingForWiFi else { return }
        saidWaitingForWiFi = true
        onRefused?("Waiting for Wi-Fi. Downloads has a Download Anyway if you need them now.")
    }


    /// Looks every so often for transfers that are being held but are not actually happening.
    private func startWatchdogIfNeeded() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while let self, await self.isBatchStillRunning {
                try? await Task.sleep(for: .seconds(Self.watchdogInterval))
                guard !Task.isCancelled else { return }
                await self.sweepStuck()
            }
            await self?.stopWatchdog()
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// One pass of the watchdog. Internal so a test can run it without waiting
    /// out the timer.
    func sweepStuck() async {
        guard !isStopped, !inFlight.isEmpty else { return }
        // Conversions are ours to run, in this process — the session has
        // never heard of them, so its answer says nothing about them.
        let carried = Set(await downloader.running().map {
            MediaID(server: index.server, rawValue: $0)
        })
        // Replaced while the session was being asked: what it said is about
        // transfers that now belong to the successor.
        guard !isStopped else { return }
        let now = Date()
        // Silence is only evidence when a transfer could have been talking: not in a lift, and not
        // on a connection it has been told it may not use.
        let mayJudgeSilence = network.isSatisfied && (permitsCellular || !network.isExpensive)
            && !transfersPaused

        var stuck: [MediaID] = []
        for id in inFlight where !convertingNow.contains(id) {
            // Definitive: the session does not know the transfer at all.
            let lost = !carried.contains(id)
            // A guess, and so limited to the one case it can be right about:
            // a transfer that started, and stopped.
            let silent = mayJudgeSilence
                && started.contains(id)
                && now.timeIntervalSince(lastActivity[id] ?? now) > stallAfter
            guard lost || silent else { continue }
            stuck.append(id)
            // A sweep that finds hundreds is the system misreporting, not
            // hundreds of failures. Deal with some now and look again.
            if stuck.count >= rescuesPerSweep { break }
        }
        rescue(stuck)
        // Just taken in hand above: their re-request is already on its way,
        // and asking again here put the same song on the system twice.
        let rescued = Set(stuck)

        // The other kind of stuck: a song that says it is queued while nothing anywhere is working
        // on it.
        var owed: [DownloadRecord] = []
        for (id, state) in states {
            guard case .queued = state else { continue }
            guard !inFlight.contains(id),
                  !preparing.contains(id),
                  !heldForNetwork.contains(id),
                  !rescued.contains(id),
                  !waiting.contains(where: { $0.id == id })
            else { continue }
            guard rescues[id, default: 0] < Self.rescueLimit else { continue }
            rescues[id] = rescues[id, default: 0] + 1
            guard let record = try? index.download(forTrack: id) else { continue }
            owed.append(record)
            if owed.count >= rescuesPerSweep { break }
        }
        await resumeAll(owed)
    }

    /// Gives stuck transfers' slots back, and asks for the songs again.
    private func rescue(_ ids: [MediaID]) {
        guard !isStopped, !ids.isEmpty else { return }
        var cancelled: Set<String> = []
        var again: [DownloadRecord] = []
        for id in ids {
            cancelled.insert(id.rawValue)
            let used = rescues[id, default: 0]
            // Frees the slot and lets whatever is waiting start.
            transferFinished(id)
            guard used < Self.rescueLimit else {
                // Tried enough. Freeing the slot is still worth doing — the
                // rest of the queue should not wait on a song that will not
                // come — but it is left failed rather than asked for again.
                if var record = try? index.download(forTrack: id) {
                    if restorePrevious(&record, id: id) {
                        try? index.saveDownload(record)
                        tallyIfFinished(id)
                        continue
                    }
                    record.state = .failed
                    record.failure = "This song stopped part way and would not start again."
                    try? index.saveDownload(record)
                    states[id] = .failed(record.failure ?? "")
                    tallyIfFinished(id)
                }
                continue
            }
            rescues[id] = used + 1
            guard let record = try? index.download(forTrack: id) else { continue }
            states[id] = .queued
            again.append(record)
        }
        downloader.cancel(ids: cancelled)
        bump()
        guard !again.isEmpty else { return }
        Task { [weak self] in await self?.resumeAll(again) }
    }

    /// Puts songs from the table back on their way, six preparations at a time.
    private func resumeAll(_ records: [DownloadRecord]) async {
        guard !isStopped, !records.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { [self] in await resumeInSlot(record) }
            }
        }
    }

    private func resumeInSlot(_ record: DownloadRecord) async {
        let id = MediaID(server: index.server, rawValue: record.trackId)
        await withPreparationSlot { await self.resume(record, id: id) }
    }

    private func withPreparationSlot(_ work: @MainActor () async -> Void) async {
        if slotsInUse >= Self.preparationsAtOnce {
            await withCheckedContinuation { slotWaiters.append($0) }
        } else {
            slotsInUse += 1
        }
        await work()
        // Handed straight to the next in line, so the count never dips and
        // lets two in.
        if slotWaiters.isEmpty {
            slotsInUse -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    /// A song asked for again after a failure, once its pause is up.
    private func scheduleRetry(_ track: Track, reason: String, after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.retry(track, reason: reason)
        }
    }

    private func retry(_ track: Track, reason: String) async {
        let id = track.id
        // Gone from the queue while it slept (removed, stopped), or already
        // handed over by something else — a relaunch's re-request, a rescue.
        guard !isStopped,
              states[id]?.isActive == true,
              !inFlight.contains(id),
              !preparing.contains(id),
              !heldForNetwork.contains(id),
              !waiting.contains(where: { $0.id == id })
        else { return }
        await withPreparationSlot { await enqueue(track, reason: reason, retrying: true) }
    }

    /// Whether a connection came back or Offline Mode went off: whatever was
    /// parked for want of a network is asked for again.
    func networkBecameAvailable() {
        guard !isStopped, !settings.offlineMode, !heldForNetwork.isEmpty else { return }
        let held = heldForNetwork
        heldForNetwork = []
        preparationWaits = [:]
        let records = held.compactMap { try? index.download(forTrack: $0) }
        Task { [weak self] in await self?.resumeAll(records) }
    }

    private func pathChanged(satisfied: Bool) {
        guard !isStopped, satisfied else { return }
        // Whatever silence there was, the outage was the reason.
        let now = Date()
        for id in inFlight { lastActivity[id] = now }
        networkBecameAvailable()
    }

    /// Starts as many waiting transfers as there is now room for.
    private func networkChanged() {
        if mayUseThisNetwork { saidWaitingForWiFi = false }
        drain()
    }

    /// Called wherever a transfer ends, so the one-off permission does not
    /// outlive the queue it was given for.
    private func forgetAnywayIfIdle() {
        guard spendingAnyway, waiting.isEmpty, inFlight.isEmpty else { return }
        spendingAnyway = false
        saidWaitingForWiFi = false
    }

    /// Saying yes to mobile data should start what was waiting for Wi-Fi,
    /// not leave it waiting for a change of network that may never come.
    func networkPolicyChanged() {
        networkChanged()
        reissuePlainFiles()
    }

    /// The cellular flag is fixed when a transfer is handed to the system, so a change of setting
    /// reaches transfers already handed over only by handing them over again.
    private func reissuePlainFiles() {
        let plain = Set(inFlight.subtracting(convertingNow).map(\.rawValue))
        guard !plain.isEmpty else { return }
        let allowed = permitsCellular
        Task { [weak self, downloader] in
            let replaced = await downloader.reissue(ids: plain, allowsCellular: allowed)
            guard let self, !replaced.isEmpty else { return }
            let now = Date()
            for raw in replaced {
                let id = MediaID(server: index.server, rawValue: raw)
                started.remove(id)
                lastActivity[id] = now
                fractions[id] = nil
            }
        }
    }

    private func drain() {
        guard !isStopped else { return }
        while let next = waiting.first, hasRoom(forConversion: next.isConversion) {
            waiting.removeFirst()
            // It may have been removed while it waited.
            guard states[next.id]?.isActive == true else { continue }
            inFlight.insert(next.id)
            lastActivity[next.id] = Date()
            startWatchdogIfNeeded()
            if next.isConversion { convertingNow.insert(next.id) }
            hand(next.id, request: next.request, fileName: next.fileName)
        }
    }

    /// How many songs are got ready at once. Enough to hide the latency of
    /// asking, few enough not to fall on a home server all at once.
    private static let preparationsAtOnce = 6

    /// How many times a download is quietly tried again before it is called a failure.
    private static let attempts = 3
    /// How long a transfer may show no sign of life before it is assumed stuck.
    var stallAfter: TimeInterval = 180
    /// How often to look. Cheap: a set difference and a dictionary walk.
    private static let watchdogInterval: TimeInterval = 30
    /// How many times one song may be rescued before it is left alone.
    private static let rescueLimit = 2
    /// The most a single sweep will take in hand. See `sweepStuck`.
    var rescuesPerSweep = 20
    private var retries: [MediaID: Int] = [:]

    init(
        serverID: ServerID,
        index: LibraryIndex,
        provider: any MusicServerProvider,
        downloader: any BackgroundDownloading,
        transport: any HTTPTransport,
        settings: AppSettings,
        network: NetworkPathMonitor,
        proxySessions: (any ProxySessionSource)? = nil,
        readsEmbeddedArtwork: Bool = false
    ) {
        self.readsEmbeddedArtwork = readsEmbeddedArtwork
        let defaults = UserDefaults.standard
        let library = serverID.rawValue.uuidString
        embeddedDiffers = Set(defaults.stringArray(forKey: "downloads.embeddedArt.differs.\(library)") ?? [])
        embeddedChecked = Set(defaults.stringArray(forKey: "downloads.embeddedArt.checked.\(library)") ?? [])
        self.proxySessions = proxySessions
        self.store = DownloadStore(serverID: serverID)
        self.artStore = EmbeddedArtStore(serverID: serverID)
        self.serverID = serverID
        self.index = index
        self.provider = provider
        self.downloader = downloader
        self.transport = transport
        self.settings = settings
        self.network = network
    }

    // MARK: Embedded artwork

    /// Whether to look inside kept files for their own picture. Set for Plex,
    /// which serves one cover for a whole album however many different
    /// pictures its files carry; Navidrome already serves each song its own.
    private let readsEmbeddedArtwork: Bool
    /// Songs whose file carries a picture that is not the album's, by track
    /// id. Kept across launches so the decision is made once per file.
    private var embeddedDiffers: Set<String>
    /// Songs already looked at, whatever came of it.
    private var embeddedChecked: Set<String>
    private var embeddedQueue: [MediaID] = []
    private var embeddedRunner: Task<Void, Never>?
    /// Where the album's own sleeve comes from, to compare a file's picture
    /// with. Set by `AppModel`, which is the one that owns the loader.
    var artworkLoader: (@MainActor () -> ArtworkLoader?)?

    /// The picture inside this song's kept file, when it is not the album's
    /// cover and the file is on the phone. Nil means: use the song's usual
    /// artwork.
    func embeddedArtwork(for track: MediaID) -> ArtworkID? {
        guard readsEmbeddedArtwork, embeddedDiffers.contains(track.rawValue),
              states[local(track)] == .done
        else { return nil }
        return .embedded(in: local(track))
    }

    /// Looks at the songs given, one after another and out of the way of
    /// everything else. A song is decided once: its file's picture, shrunk to
    /// a few colour samples, against the album's sleeve.
    private func inspectEmbeddedArtwork(of ids: [MediaID]) {
        guard readsEmbeddedArtwork, !isStopped else { return }
        for id in ids where !embeddedChecked.contains(id.rawValue) && !embeddedQueue.contains(id) {
            embeddedQueue.append(id)
        }
        guard embeddedRunner == nil, !embeddedQueue.isEmpty else { return }
        embeddedRunner = Task(priority: .utility) { [weak self] in
            var undecided: [MediaID] = []
            var rounds = 0
            while let self, !self.isStopped {
                guard let id = self.embeddedQueue.first else {
                    // The album's sleeve was not to be had — no connection
                    // yet, or the server not reached — so ask again shortly,
                    // a few times, and otherwise at the next launch.
                    guard !undecided.isEmpty, rounds < 3 else { break }
                    rounds += 1
                    try? await Task.sleep(for: .seconds(30))
                    self.embeddedQueue = undecided
                    undecided = []
                    continue
                }
                self.embeddedQueue.removeFirst()
                if await self.inspectEmbeddedArtwork(id) == false { undecided.append(id) }
            }
            self?.embeddedRunner = nil
        }
    }

    /// How far a look at the original file's head got.
    private enum OriginalHead {
        case found(Data)
        /// The head was read and holds no picture.
        case absent
        /// Not reached: offline, on a connection not to be spent, or the
        /// server said no.
        case unavailable
    }

    /// How much of an original file to ask for. A picture sits right after the
    /// tags, and a cover of a few megabytes is already unusual.
    private static let originalHeadBytes = 3 * 1024 * 1024

    /// The picture in the original file, for a download that was converted
    /// and so no longer has it. One range request for the file's first bytes.
    private func pictureFromOriginal(_ id: MediaID) async -> OriginalHead {
        guard !settings.offlineMode, network.isSatisfied, mayUseThisNetwork else { return .unavailable }
        do {
            var request = try await provider.downloadRequest(for: id, options: .original)
            request.setValue("bytes=0-\(Self.originalHeadBytes - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await transport.perform(request)
            guard (200..<300).contains(response.statusCode) else { return .unavailable }
            let head = Data(data.prefix(Self.originalHeadBytes))
            return EmbeddedPicture.read(fromHead: head).map(OriginalHead.found) ?? .absent
        } catch {
            return .unavailable
        }
    }

    /// Whether the song was settled: false only when something needed to
    /// decide was not to be had — the album's sleeve, or the original file —
    /// which is worth another go later.
    private func inspectEmbeddedArtwork(_ id: MediaID) async -> Bool {
        guard states[id] == .done, let url = fileURL(for: id) else { return true }
        var picture = await Task.detached(priority: .utility) { EmbeddedPicture.read(from: url) }.value
        var fromOriginal = false
        if picture == nil, variants[id]?.isOriginal == false {
            switch await pictureFromOriginal(id) {
            case .found(let data):
                picture = data
                fromOriginal = true
            case .absent: break
            case .unavailable: return false
            }
        }
        let embedded = await Task.detached(priority: .utility) { () -> ArtworkSignature? in
            picture.flatMap { ArtworkSignature(imageData: $0) }
        }.value
        guard let picture, let embedded else {
            settleEmbeddedArtwork(id, differs: false)
            return true
        }
        guard let track = try? index.track(id: id) else { return true }
        var differs = true
        if let album = track.artwork {
            guard let loader = artworkLoader?(), let sleeve = await loader.signature(of: album) else { return false }
            differs = embedded.isDifferent(from: sleeve)
        }
        if differs, fromOriginal {
            let small = EmbeddedPicture.downsized(picture, maxPixels: 1200) ?? picture
            artStore.write(small, for: id)
        }
        settleEmbeddedArtwork(id, differs: differs)
        return true
    }

    /// The file holding this song's own picture: the one kept beside a
    /// converted download, or the downloaded file itself.
    func embeddedArtworkFile(for id: MediaID) -> URL? {
        artStore.existing(for: local(id)) ?? fileURL(for: id)
    }

    /// A song whose picture was decided to be its own but whose kept copy is
    /// gone — a converted download — is looked at again.
    private func repairEmbeddedArtwork() {
        for raw in embeddedDiffers {
            let id = MediaID(server: index.server, rawValue: raw)
            if variants[id]?.isOriginal == false, artStore.existing(for: id) == nil {
                forgetEmbeddedArtwork(id)
            }
        }
    }

    private func settleEmbeddedArtwork(_ id: MediaID, differs: Bool) {
        embeddedChecked.insert(id.rawValue)
        let library = serverID.rawValue.uuidString
        UserDefaults.standard.set(Array(embeddedChecked), forKey: "downloads.embeddedArt.checked.\(library)")
        guard differs, embeddedDiffers.insert(id.rawValue).inserted else { return }
        UserDefaults.standard.set(Array(embeddedDiffers), forKey: "downloads.embeddedArt.differs.\(library)")
    }

    /// A file that has just arrived is a new file: whatever was decided about
    /// the one before it is not evidence about this one.
    private func forgetEmbeddedArtwork(_ id: MediaID) {
        artStore.remove(for: id)
        guard embeddedChecked.remove(id.rawValue) != nil || embeddedDiffers.remove(id.rawValue) != nil else { return }
        let library = serverID.rawValue.uuidString
        UserDefaults.standard.set(Array(embeddedChecked), forKey: "downloads.embeddedArt.checked.\(library)")
        UserDefaults.standard.set(Array(embeddedDiffers), forKey: "downloads.embeddedArt.differs.\(library)")
    }

    // MARK: Reading

    /// How far the run in progress has got, from nothing to one, or `nil` when there is no run.
    var batchProgress: Double? {
        guard batchSize > 0 else { return nil }
        // Counted rather than recounted.
        var landed = Double(finishedInBatch)
        // Over the fractions, not over everything handed to the system: a plain file is in flight
        // from the moment it is asked for, so `inFlight` holds the whole batch, and only the few
        // transfers that are actually moving have a fraction at all.
        for (id, fraction) in fractions where counted.contains(id) {
            if states[id]?.isRunning == true { landed += fraction }
        }
        return min(1, landed / Double(batchSize))
    }

    /// Records that a song is over, once. Called wherever a state becomes
    /// `.done` or `.failed`; see `finishedInBatch`.
    private func tallyIfFinished(_ id: MediaID) {
        guard counted.contains(id), !tallied.contains(id) else { return }
        switch states[id] {
        case .done, .failed:
            tallied.insert(id)
            finishedInBatch += 1
        default:
            break
        }
    }

    /// This library's key for a song, whichever library it was found in. See
    /// `download(_:reason:)`.
    private func local(_ id: MediaID) -> MediaID {
        id.server == index.server ? id : MediaID(server: index.server, rawValue: id.rawValue)
    }

    /// The file of a song downloaded while another of this server's libraries
    /// was open, which is in that library's table and folder rather than this
    /// one's. Set by `AppModel`.
    var foreignFile: (@MainActor (MediaID) -> URL?)?

    private func isForeign(_ id: MediaID) -> Bool { id.server != index.server }

    func state(for track: MediaID) -> State? {
        if let own = states[local(track)] { return own }
        return isForeign(track) && foreignFile?(track) != nil ? .done : nil
    }

    /// How far this song has got, where that is known at all.
    func fraction(for track: MediaID) -> Double? {
        let track = local(track)
        guard states[track]?.isRunning == true else { return nil }
        return fractions[track]
    }

    /// Whether there is a copy on the phone to play: a finished download, or
    /// the one a replacement is still on its way to replace.
    func isDownloaded(_ track: MediaID) -> Bool {
        let own = local(track)
        if states[own] == .done || previousFileNames[own] != nil { return true }
        return isForeign(track) && foreignFile?(track) != nil
    }

    func isRequested(_ reason: DownloadReason) -> Bool { requested.contains(reason.key) }

    /// The kept file, when there is one. Playback asks this first: a download
    /// is the best copy we have and it costs nothing to reach.
    func fileURL(for track: MediaID) -> URL? {
        let original = track
        let track = local(track)
        let own: URL?
        if states[track] == .done {
            own = store.existingFile(named: fileNames[track])
        } else {
            // Being fetched again at another quality: until the new copy has
            // landed, the old one is the song. It used to stop playing the
            // moment the replacement was asked for.
            own = store.existingFile(named: previousFileNames[track])
        }
        if let own { return own }
        return isForeign(original) ? foreignFile?(original) : nil
    }

    /// How a whole album, playlist or artist stands: done only when every one
    /// of its tracks is.
    func state(forGroup tracks: [MediaID]) -> State? {
        guard !tracks.isEmpty else { return nil }
        let known = tracks.compactMap { states[$0] }
        guard known.count == tracks.count else {
            return known.contains(where: \.isActive) ? .queued : nil
        }
        if known.allSatisfy({ $0 == .done }) { return .done }
        if let failure = known.first(where: { if case .failed = $0 { return true } else { return false } }),
           !known.contains(where: \.isActive) {
            return failure
        }
        return .running
    }

    func usage() -> Int64 { store.usage() }

    /// What a conversion of this song should come to, when the server will not say.
    private func estimatedBytes(for id: MediaID) -> Int64? {
        guard case .converted(_, let kbps)? = variants[id] else { return nil }
        return estimatedConversionBytes(kbps: kbps, duration: track(id)?.duration)
    }

    /// The same figure, without holding the main thread while it is counted.
    nonisolated func usageOffMainActor() async -> Int64 {
        let store = self.store
        return await Task.detached(priority: .utility) { store.usage() }.value
    }

    /// How many kept songs are at a quality the setting no longer asks for.
    func countAtOtherQuality() async -> Int {
        var count = 0
        for (offset, id) in downloadedTracks().enumerated() {
            if offset > 0, offset.isMultiple(of: 50) { await Task.yield() }
            guard let track = track(id), let kept = variants[id] else { continue }
            let wanted = PlayerModel.variant(
                for: PlayerModel.streamOptions(for: track, policy: settings.downloadTranscode)
            )
            if kept != wanted { count += 1 }
        }
        return count
    }

    func downloadedTracks() -> [MediaID] {
        states.filter { $0.value == .done }.map(\.key)
    }

    // MARK: Starting

    /// Reads the download table at launch. Replaceable so a test can make the
    /// read fail; nil in the app, which reads the index.
    var recordLoader: (() throws -> [DownloadRecord])?

    /// Set by the app so a refusal can be explained rather than ignored.
    var onRefused: ((String) -> Void)?

    /// Said once per batch rather than once per song: a record is forty
    /// songs, and forty notices saying the same thing is not a kinder answer
    /// than one.
    private var saidWaitingForWiFi = false

    /// A playlist is kept whole: its name, its picture and the order of its
    /// songs are written down here, because offline there is no server to ask
    /// what "Sunday Morning" was.
    func download(playlist: Playlist, tracks: [Track]) async {
        try? index.saveDownloadedPlaylist(DownloadedPlaylistRecord(
            id: playlist.id.rawValue,
            name: playlist.name,
            artworkId: playlist.artwork?.rawValue,
            trackIds: tracks.map(\.id.rawValue)
        ))
        await download(tracks, reason: .playlist(playlist.id))
        scheduleKeepingArtwork()
    }

    /// Copies the sleeves of everything downloaded into storage the artwork cache's settings do not
    /// touch, with the colours of each, so a page for something on the phone looks the same offline
    /// after a cold launch or a cleared cache.
    private var keepingArtwork: Task<Void, Never>?
    /// Something changed while a run was going: the run it asks for starts
    /// over from a fresh read of the table instead of finishing a stale one.
    private var keepArtworkAgain = false

    func scheduleKeepingArtwork() {
        guard !isStopped else { return }
        guard keepingArtwork == nil else {
            keepArtworkAgain = true
            return
        }
        keepingArtwork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while let self, !Task.isCancelled, !self.isStopped {
                self.keepArtworkAgain = false
                await self.keepArtworkOfDownloads()
                if !self.keepArtworkAgain { break }
            }
            self?.keepingArtwork = nil
        }
    }

    private func keepArtworkOfDownloads() async {
        // A table that cannot be read is not an empty one; see `start`.
        guard let records = try? index.downloads() else { return }
        var raw = Set(records.compactMap(\.artworkId))
        // The album's own cover too, as the library has it now: it can be a
        // different picture from the songs', and it is the one an album page
        // draws.
        raw.formUnion((try? index.artworkIDsOfDownloadedAlbums()) ?? [])
        for playlist in downloadedPlaylists() {
            if let id = playlist.artworkId { raw.insert(id) }
        }
        // What nothing downloaded refers to any more goes, so a removed
        // download, or every one of them, does not leave its sleeves behind.
        KeptArtwork.prune(server: index.server, keeping: raw)
        guard let loader = artworkLoader?() else { return }
        for id in raw.sorted() {
            if isStopped || Task.isCancelled || keepArtworkAgain { return }
            await loader.keep(ArtworkID(server: index.server, rawValue: id))
        }
    }

    /// The albums and artists that are on the phone *because you asked for them* — not the ones a
    /// playlist happens to touch.
    struct Deliberate {
        var albums: [Album] = []
        var artists: [Artist] = []
    }

    func deliberate() -> Deliberate {
        Self.deliberate(
            in: index,
            others: otherLibraries?() ?? [],
            isHere: { [self] in isDownloaded($0) }
        )
    }

    /// The other libraries' indexes, which can say what an album or an artist
    /// kept here is when this library has never heard of it. Set by `AppModel`.
    var otherLibraries: (@MainActor () -> [LibraryIndex])?

    /// The same, for any library's index: the Downloads screen's merged list reads the other
    /// libraries' tables through this.
    static func deliberate(
        in index: LibraryIndex,
        others: [LibraryIndex] = [],
        isHere: (MediaID) -> Bool = { _ in false }
    ) -> Deliberate {
        var albumIDs: Set<String> = []
        var artistIDs: Set<String> = []
        for record in (try? index.downloads()) ?? [] {
            for reason in record.reasons {
                if let raw = reason.dropPrefixIfPresent("album:") { albumIDs.insert(raw) }
                if let raw = reason.dropPrefixIfPresent("artist:") { artistIDs.insert(raw) }
            }
        }

        func elsewhere<T>(_ ask: (LibraryIndex, MediaID) -> T?, _ raw: String) -> T? {
            for other in others {
                if let found = ask(other, MediaID(server: other.server, rawValue: raw)) { return found }
            }
            return nil
        }

        var albums: [Album] = []
        var seenAlbums: Set<String> = []
        for raw in albumIDs {
            guard let album = (try? index.album(id: MediaID(server: index.server, rawValue: raw)))
                ?? elsewhere({ (try? $0.album(id: $1)) ?? nil }, raw)
            else { continue }
            if seenAlbums.insert(album.id.rawValue).inserted { albums.append(album) }
        }
        // An artist you downloaded brings whichever of their records actually
        // arrived.
        var foreignArtists: [Artist] = []
        for raw in artistIDs {
            let artistID = MediaID(server: index.server, rawValue: raw)
            let own = (try? index.albums(forArtist: artistID, downloadedOnly: true)) ?? []
            for album in own where seenAlbums.insert(album.id.rawValue).inserted { albums.append(album) }
            guard own.isEmpty, (try? index.artist(id: artistID)) == nil else { continue }
            // Not this library's artist: found in another's, whose records are
            // judged by whether any of their songs is here.
            for other in others {
                let theirID = MediaID(server: other.server, rawValue: raw)
                guard let artist = (try? other.artist(id: theirID)) ?? nil else { continue }
                foreignArtists.append(artist)
                for album in (try? other.albums(forArtist: theirID)) ?? [] {
                    let songs = (try? other.tracks(inAlbum: album.id)) ?? []
                    if songs.contains(where: { isHere($0.id) }),
                       seenAlbums.insert(album.id.rawValue).inserted {
                        albums.append(album)
                    }
                }
                break
            }
        }

        // Artists: the ones asked for, plus whoever made the albums asked
        // for — so a downloaded record can be reached from its maker.
        var artists: [Artist] = foreignArtists
        var seenArtists: Set<String> = Set(foreignArtists.map(\.id.rawValue))
        for raw in artistIDs.union(albums.compactMap { $0.artistID?.rawValue }) {
            guard let artist = (try? index.artist(id: MediaID(server: index.server, rawValue: raw)))
                ?? elsewhere({ (try? $0.artist(id: $1)) ?? nil }, raw)
            else { continue }
            if seenArtists.insert(artist.id.rawValue).inserted { artists.append(artist) }
        }

        return Deliberate(
            albums: albums.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            artists: artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }

    func downloadedPlaylists() -> [DownloadedPlaylistRecord] {
        (try? index.downloadedPlaylists()) ?? []
    }

    /// The songs of a downloaded playlist that are really on the phone, in
    /// the order the playlist had them.
    func tracks(inDownloadedPlaylist id: MediaID) -> [Track] {
        guard let record = try? index.downloadedPlaylist(id: id) else { return [] }
        return record.tracks.compactMap { raw in
            let trackID = MediaID(server: index.server, rawValue: raw)
            guard states[trackID] == .done else { return nil }
            return track(trackID)
        }
    }

    /// The library's copy of a song when it has one, otherwise the copy written down when it was
    /// downloaded.
    func requestedAt() -> [MediaID: Date] { askedAt }

    /// What the kept copy of a song is, when there is one and it is not simply the server's own
    /// file.
    func downloadedConversion(for id: MediaID) -> (codec: String, kbps: Int?)? {
        guard states[id] == .done, case .converted(let codec, let kbps) = variants[id] else {
            return nil
        }
        return (codec, kbps)
    }

    func track(_ id: MediaID) -> Track? {
        if let remembered = known[id] { return remembered }
        let found = (try? index.track(id: id))
            ?? (try? index.download(forTrack: id))?.rememberedTrack(server: index.server)
        if let found { known[id] = found }
        return found
    }

    /// Songs kept at a quality the download setting no longer asks for.
    func tracksAtOtherQuality() -> [Track] {
        downloadedTracks().compactMap { id in
            guard let track = track(id), let kept = variants[id] else { return nil }
            let wanted = PlayerModel.variant(
                for: PlayerModel.streamOptions(for: track, policy: settings.downloadTranscode)
            )
            return kept == wanted ? nil : track
        }
    }

    /// Fetches those again at what the setting asks for now.
    func refetchAtCurrentQuality() async {
        guard !settings.offlineMode else {
            onRefused?("Offline mode is on, so nothing new can be fetched. Turn it off to download.")
            return
        }
        let wanted = tracksAtOtherQuality()
        guard !wanted.isEmpty else { return }
        // Paired with their reasons here, on the actor, rather than looked up
        // inside the group: the tables these come from are this object's.
        let owed: [(track: Track, reason: String)] = wanted.map { track in
            let held = reasons[track.id]
                ?? Set((try? index.download(forTrack: track.id))?.reasons ?? [])
            return (track, held.first ?? DownloadReason.track(track.id).key)
        }
        let atOnce = settings.downloadTranscode.threshold == .always ? 1 : Self.preparationsAtOnce
        let batch = beginBatch(reason: nil)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(atOnce, owed.count) {
                let one = owed[next]
                group.addTask { [self] in
                    await enqueue(one.track, reason: one.reason, refetching: true, batch: batch)
                }
                next += 1
            }
            while await group.next() != nil {
                bump()
                guard next < owed.count, isCurrent(batch) else { continue }
                let one = owed[next]
                group.addTask { [self] in
                    await enqueue(one.track, reason: one.reason, refetching: true, batch: batch)
                }
                next += 1
            }
        }
        bump()
    }

    func download(_ tracks: [Track], reason: DownloadReason) async {
        // Offline by choice is a decision about the network, and starting a
        // fetch would go straight through it. Transfers already under way are
        // the system's and keep going: they were asked for before.
        guard !settings.offlineMode else {
            onRefused?("Offline mode is on, so nothing new can be fetched. Turn it off to download.")
            return
        }
        // Under this library's identity, whichever library the songs were found in.
        let tracks = tracks.map { $0.rekeyed(to: index.server) }
        // The albums' reviews, kept with the songs. Alongside the transfers
        // and not in front of them: it is a few small requests, and a review
        // that does not arrive is no reason to hold up a song.
        Task { await keepReviews(forAlbumsOf: tracks) }
        // Several at a time, not one after another.
        let atOnce = settings.downloadTranscode.threshold == .always ? 1 : Self.preparationsAtOnce
        let key = reason.key
        // Noted once, here: a Stop or a Remove that lands while the rest of
        // the batch is still being got ready must reach the songs that have
        // not started yet, not only the ones that have.
        let batch = beginBatch(reason: key)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(atOnce, tracks.count) {
                let track = tracks[next]
                group.addTask { [self] in await enqueue(track, reason: key, batch: batch) }
                next += 1
            }
            while await group.next() != nil {
                // As each song is made ready, not once they all are.
                bump()
                guard next < tracks.count, isCurrent(batch) else { continue }
                let track = tracks[next]
                group.addTask { [self] in await enqueue(track, reason: key, batch: batch) }
                next += 1
            }
        }
        bump()
    }

    /// Fetches and keeps the review of each album these songs belong to, so an album downloaded to
    /// listen to offline can also be read about offline.
    private func keepReviews(forAlbumsOf tracks: [Track]) async {
        guard !settings.offlineMode, provider.capabilities.contains(.albumInfo) else { return }
        var seen = Set<MediaID>()
        let albums = tracks.compactMap(\.albumID).filter { seen.insert($0).inserted }
        // Asked now, whatever an earlier "nothing there" said: someone who has
        // just chosen to download this album is the likeliest to want a review
        // that has since appeared.
        let due = (try? index.albumsLackingNotes(albums, checkedBefore: Date())) ?? albums
        await keepReviews(for: due)
    }

    /// Asks for each album's review and keeps what comes back.
    @discardableResult
    private func keepReviews(for albums: [MediaID]) async -> Int {
        var kept = 0
        var failures = 0
        for album in albums.prefix(Self.reviewsPerPass) {
            guard !isStopped, !Task.isCancelled else { break }
            switch await ReviewLedger.ask({ try await provider.albumInfo(id: album).notes }) {
            case .review(let text):
                try? index.storeAlbumNotes(text, forAlbum: album)
                kept += 1
                failures = 0
            case .unreviewed:
                try? index.noteAlbumHasNoNotes(forAlbum: album)
                failures = 0
            case .failed:
                failures += 1
                if failures >= Self.reviewFailureLimit { return kept }
            case .cancelled:
                return kept
            }
        }
        return kept
    }

    private static let reviewsPerPass = 100
    private static let reviewFailureLimit = 3
    /// How long an album the server had no review for is left before it is
    /// asked about again.
    private static let reviewRecheckInterval: TimeInterval = 7 * 24 * 60 * 60

    // MARK: Keeping downloaded details current

    /// Brings what is kept alongside the downloads up to date with the library, so a download is
    /// not frozen at the day it was made.
    @discardableResult
    func refreshDownloadedDetails(askingServer: Bool) async -> Int {
        guard !isStopped else { return 0 }
        let changed = (try? index.refreshDownloadDetailsFromLibrary()) ?? 0
        if changed > 0 { bump() }
        // Always: a cover that arrived with a changed row is kept by this, and
        // so is one whose download row was already right but whose file was
        // never kept. It does nothing for what is kept already.
        scheduleKeepingArtwork()
        if askingServer, !settings.offlineMode, provider.capabilities.contains(.albumInfo) {
            let cutoff = Date().addingTimeInterval(-Self.reviewRecheckInterval)
            let due = (try? index.downloadedAlbumsLackingNotes(checkedBefore: cutoff)) ?? []
            await keepReviews(for: due)
        }
        return changed
    }

    /// Puts everything still owed back on its way.
    func restartQueue() async {
        let carried = Set(await downloader.running())
        for record in (try? index.downloads()) ?? [] {
            guard record.state == .queued || record.state == .running else { continue }
            guard !carried.contains(record.trackId) else { continue }
            let id = MediaID(server: index.server, rawValue: record.trackId)
            guard !inFlight.contains(id),
                  !preparing.contains(id),
                  !waiting.contains(where: { $0.id == id })
            else { continue }
            heldForNetwork.remove(id)
            states[id] = .queued
            await resume(record, id: id)
        }
        preparationWaits = [:]
        bump()
    }

    /// Stops everything on its way without touching a note of what has already arrived.
    func stopDownloading() {
        stopGeneration += 1
        preparing = []
        retries = [:]
        started = []
        heldForNetwork = []
        preparationWaits = [:]
        convertingNow = []
        inFlight = []
        waiting = []
        // Neither of these routes through `transferFinished`, which is the only other place the
        // "Download Anyway" permission is taken back — so without this, calling everything off here
        // left it standing for the rest of the session, waving every…
        forgetAnywayIfIdle()
        // Or the next run is timed from this one's start.
        clearBatch()
        downloader.cancelAll()
        // One read for every song, and one transaction to delete the rows: a
        // read and a write per song, on the main actor, was seconds of frozen
        // screen for a large queue.
        var rows: [String: DownloadRecord] = [:]
        for row in (try? index.downloads()) ?? [] { rows[row.trackId] = row }
        var doomed: [MediaID] = []
        for (track, state) in states where state.isActive {
            if var record = rows[track.rawValue] {
                // A replacement called off leaves the song as it was: the
                // copy it was to replace is still the download.
                if record.previousFileName != nil {
                    let unfinished = record.fileName
                    if restorePrevious(&record, id: track) {
                        if let unfinished, unfinished != record.fileName { store.remove(named: unfinished) }
                        try? index.saveDownload(record)
                        continue
                    }
                }
                // The row goes with the transfer. A half-written file is not
                // a download, and leaving the record behind would show a song
                // as being on the phone when nothing of it is.
                if let name = record.fileName { store.remove(named: name) }
                if let old = record.previousFileName { store.remove(named: old) }
                if record.variant != MediaVariant.original.tag {
                    Task { [provider] in await provider.endConversion(for: track) }
                }
            }
            doomed.append(track)
            states[track] = nil
            reasons[track] = nil
            fileNames[track] = nil
        }
        try? index.deleteDownloads(forTracks: doomed)
        bump()
    }

    /// The three places a song can be for the Downloads screen: kept, on its
    /// way, or given up on. "Not finished" used to be read as "on its way",
    /// which listed failures under "Downloading N songs" for ever.
    struct Partition: Equatable {
        var kept: [MediaID] = []
        var active: [MediaID] = []
        var failed: [MediaID] = []
    }

    static func partition(_ states: [MediaID: State]) -> Partition {
        var result = Partition()
        for (id, state) in states {
            switch state {
            case .done: result.kept.append(id)
            case .queued, .running: result.active.append(id)
            case .failed: result.failed.append(id)
            }
        }
        return result
    }

    /// Asks again for songs that gave up — all of them, or the ones named —
    /// with their attempts and rescues forgotten, as if they had just been
    /// asked for. Each goes back to its first reason.
    func retryFailed(_ ids: [MediaID]? = nil) async {
        guard !isStopped else { return }
        guard !settings.offlineMode else {
            onRefused?("Offline mode is on, so nothing new can be fetched. Turn it off to download.")
            return
        }
        let wanted = ids.map { Set($0.map(local)) }
        var records: [DownloadRecord] = []
        for (id, state) in states {
            guard case .failed = state, wanted?.contains(id) ?? true else { continue }
            guard var record = try? index.download(forTrack: id) else { continue }
            retries[id] = nil
            rescues[id] = nil
            preparationWaits[id] = nil
            record.state = .queued
            record.failure = nil
            try? index.saveDownload(record)
            states[id] = .queued
            records.append(record)
        }
        // Someone asked, which is as good as having signed in.
        wallRaised = false
        bump()
        await resumeAll(records)
        bump()
    }

    /// Whether anything is on its way, for the screen that offers to stop it.
    var isDownloading: Bool {
        states.values.contains { $0.isActive }
    }

    /// Songs are owed and nothing whatever is being done about them.
    var isStalled: Bool {
        isDownloading && inFlight.isEmpty && preparing.isEmpty && !isWaitingForNetwork
    }

    /// `refetching` is for a song that is already here and is wanted again
    /// in a different format — see `refetchAtCurrentQuality`. Everything else
    /// about it is the same request; only the shortcut below is skipped.
    private func enqueue(
        _ track: Track, reason: String, retrying: Bool = false, refetching: Bool = false,
        batch: Batch? = nil
    ) async {
        guard !isStopped else { return }
        // Asked for as part of a batch that has since been stopped or had this
        // reason taken away: nothing this song does is worth doing, and above
        // all its reason must not be written back.
        if let batch, !isCurrent(batch) { return }
        var record = (try? index.download(forTrack: track.id)) ?? DownloadRecord(
            trackId: track.id.rawValue,
            state: .queued
        )
        // Written down every time, so a row that predates this knowledge
        // gains it on the next request, and a song whose library the index
        // does not hold still has a name.
        record.title = track.title
        record.artistName = track.artistName
        record.albumName = track.albumName
        record.artworkId = track.artwork?.rawValue
        record.duration = track.duration
        scheduleKeepingArtwork()
        var currentReasons = record.reasons
        currentReasons.insert(reason)
        requested.insert(reason)
        record.setReasons(currentReasons)
        reasons[track.id] = currentReasons

        // Already here: nothing to fetch, only a new reason to keep it.
        if !refetching, record.state == .done, store.existingFile(named: record.fileName) != nil {
            try? index.saveDownload(record)
            states[track.id] = .done
            tallyIfFinished(track.id)
            fileNames[track.id] = record.fileName
            return
        }

        // Already on its way, or already being asked about: one file, one
        // transfer, however many albums and playlists want it.
        if !retrying, states[track.id]?.isActive == true || preparing.contains(track.id) {
            try? index.saveDownload(record)
            return
        }

        preparing.insert(track.id)
        defer { preparing.remove(track.id) }
        let generation = batch?.generation ?? stopGeneration

        let options = PlayerModel.streamOptions(for: track, policy: settings.downloadTranscode)
        let variant = PlayerModel.variant(for: options)

        // How the server will hand this over, and where from, in one question.
        var source: StreamSource?
        var preparationError: (any Error)?
        if settings.offlineMode {
            preparationError = URLError(.notConnectedToInternet)
        } else {
            do {
                source = try await provider.downloadSource(for: track.id, options: options)
            } catch {
                preparationError = error
            }
        }
        // A Stop that landed while that question was in the air. Nothing
        // this song does after it is asked for again is worth doing.
        guard generation == stopGeneration, !isStopped else { return }
        if let batch, !isCurrent(batch) { return }

        // Another request for this song — the album, then a playlist it is also on — can have
        // written its row while this one waited on the server, and saving this request's copy over
        // it lost that reason.
        if let fresh = try? index.download(forTrack: track.id) {
            let merged = fresh.reasons.union(record.reasons)
            if merged != record.reasons {
                record.setReasons(merged)
                reasons[track.id] = merged
                requested.formUnion(merged)
            }
        }
        guard let request = source?.request else {
            unprepared(track, reason: reason, record: record, isConversion: !variant.isOriginal, error: preparationError)
            return
        }

        let name = DownloadStore.fileName(
            for: track.id,
            variant: variant,
            fileExtension: request.url?.pathExtension ?? ""
        )
        // A replacement: the copy that is here now stays the song, and stays on disk, until the new
        // one has arrived.
        if record.state == .done, let old = record.fileName, old != name,
           store.existingFile(named: old) != nil {
            record.previousFileName = old
            record.previousVariant = record.variant
        } else if record.previousFileName == name {
            // The same file again: the replacement will land on top of it.
            record.previousFileName = nil
            record.previousVariant = nil
        }
        previousFileNames[track.id] = record.previousFileName
        record.state = .queued
        record.fileName = name
        record.variant = variant.tag
        record.failure = nil
        try? index.saveDownload(record)

        states[track.id] = .queued
        fileNames[track.id] = name
        askedAt[track.id] = record.addedAt
        variants[track.id] = variant

        // Both kinds go through the same gate.
        begin(
            track.id,
            request: request,
            fileName: name,
            isConversion: !variant.isOriginal
        )
    }


    /// What to do with a song the server could not be asked about.
    private func unprepared(
        _ track: Track,
        reason: String,
        record: DownloadRecord,
        isConversion: Bool,
        error: (any Error)?
    ) {
        let id = track.id
        // Called off, not refused. Left as it is; the sweep for songs queued
        // with nothing behind them is what picks it up again if it matters.
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        // Asked again for a song that is here, and the server could not be asked.
        if record.state == .done, store.existingFile(named: record.fileName) != nil { return }

        var record = record
        let disposition = error.map {
            TransferFailureClassifier.disposition(forPreparation: $0, isConversion: isConversion)
        } ?? .retryable

        switch disposition {
        case .waitForNetwork:
            let waits = preparationWaits[id, default: 0] + 1
            preparationWaits[id] = waits
            if waits <= Self.preparationWaitLimit || settings.offlineMode || !network.isSatisfied {
                record.state = .queued
                record.failure = nil
                try? index.saveDownload(record)
                states[id] = .queued
                heldForNetwork.insert(id)
                bump()
                return
            }
        case .retryable:
            let used = retries[id, default: 0]
            if used + 1 < Self.attempts {
                retries[id] = used + 1
                record.state = .queued
                record.failure = nil
                try? index.saveDownload(record)
                states[id] = .queued
                scheduleRetry(track, reason: reason, after: Double(used + 1) * 2)
                bump()
                return
            }
        case .storageFull:
            sayStorageFull()
        case .proxyWall:
            record.state = .queued
            record.failure = nil
            try? index.saveDownload(record)
            states[id] = .queued
            heldForNetwork.insert(id)
            var page: URL?
            if case ProviderError.proxySignInRequired(let url)? = error { page = url }
            if !wallRaised {
                wallRaised = true
                onProxyWall?(page)
            }
            bump()
            return
        case .terminal:
            break
        }

        if restorePrevious(&record, id: id) {
            try? index.saveDownload(record)
            tallyIfFinished(id)
            bump()
            return
        }
        record.state = .failed
        record.failure = (error as? ProviderError)?.diagnosticDescription
            ?? error?.localizedDescription
            ?? "Could not ask the server for this song."
        try? index.saveDownload(record)
        states[id] = .failed(record.failure ?? "")
        tallyIfFinished(id)
        noteBatchIfFinished()
        bump()
    }

    /// Puts a song back on the copy it had before a replacement was asked for, when that copy is
    /// still there.
    private func restorePrevious(_ record: inout DownloadRecord, id: MediaID) -> Bool {
        guard let old = record.previousFileName, store.existingFile(named: old) != nil else {
            return false
        }
        record.fileName = old
        record.variant = record.previousVariant ?? record.variant
        record.previousFileName = nil
        record.previousVariant = nil
        record.state = .done
        record.failure = nil
        record.bytes = store.size(of: old)
        fileNames[id] = old
        variants[id] = MediaVariant(tag: record.variant)
        previousFileNames[id] = nil
        states[id] = .done
        return true
    }

    private func sayStorageFull() {
        guard !saidStorageFull else { return }
        saidStorageFull = true
        onRefused?("There is no room left on this iPhone. Free up some space, then try the rest again.")
    }

    private func hand(_ id: MediaID, request: URLRequest, fileName: String) {
        guard !isStopped else { return }
        // The sign-in cookie of a server behind an SSO proxy, stamped where every transfer passes:
        // a first request, a retry, a rescue and a song released from the wait queue all come
        // through here.
        let stamped = proxySessions?.authenticating(request) ?? request
        downloader.enqueue(
            id: id.rawValue,
            request: stamped,
            to: store.url(named: fileName),
            allowsCellular: permitsCellular
        )
    }

    /// Called when a transfer ends, however it ended.
    private func transferFinished(_ id: MediaID) {
        defer { forgetAnywayIfIdle() }
        lastActivity[id] = nil
        fractions[id] = nil
        started.remove(id)
        let wasConverting = convertingNow.remove(id) != nil
        let wasInFlight = inFlight.remove(id) != nil
        guard wasConverting || wasInFlight else { return }
        if wasConverting {
            // Tell the server it can stop: it opened a session for this song
            // and will keep it — and the work behind it — until told
            // otherwise.
            Task { [provider] in await provider.endConversion(for: id) }
        }
        drain()
    }

    // MARK: Keeping playlists current

    /// Compares every downloaded playlist with the server and settles the differences.
    @discardableResult
    func refreshDownloadedPlaylists() async -> Int {
        guard !settings.offlineMode, provider.capabilities.contains(.playlists) else { return 0 }

        var changed = 0
        for record in downloadedPlaylists() {
            if await refresh(record, using: provider) { changed += 1 }
        }
        if changed > 0 { bump() }
        return changed
    }

    /// - Returns: whether anything about this playlist actually differed.
    private func refresh(
        _ record: DownloadedPlaylistRecord,
        using provider: any MusicServerProvider
    ) async -> Bool {
        let id = MediaID(server: index.server, rawValue: record.id)
        let fetched: (playlist: Playlist, tracks: [Track])?
        do {
            fetched = try await everything(ofPlaylist: id, using: provider)
        } catch let error as ProviderError {
            // Gone from the server is a fact worth writing down.
            if error.meansNotFound {
                var marked = record
                marked.missingFromServer = true
                marked.checkedAt = Date()
                try? index.saveDownloadedPlaylist(marked)
                return true
            }
            return false
        } catch {
            return false
        }
        guard let fetched else { return false }

        let wanted = fetched.tracks.map(\.id.rawValue)
        let had = record.tracks
        let hadSet = Set(had)
        let departed = hadSet.subtracting(wanted)
        let arrived = fetched.tracks.filter { !hadSet.contains($0.id.rawValue) }
        let reordered = wanted != had
        let renamed = fetched.playlist.name != record.name

        var updated = record
        updated.name = fetched.playlist.name
        updated.artworkId = fetched.playlist.artwork?.rawValue
        updated.trackIds = wanted.joined(separator: "\n")
        updated.checkedAt = Date()
        updated.missingFromServer = false
        try? index.saveDownloadedPlaylist(updated)

        // Songs that have left. The playlist's claim on them is dropped; one
        // an album or an artist you downloaded still wants stays exactly where
        // it is, which is what the reason counting is for.
        if !departed.isEmpty {
            release(
                reason: DownloadReason.playlist(id),
                fromTracks: departed.map { MediaID(server: index.server, rawValue: $0) }
            )
        }
        // And the ones that have arrived.
        if !arrived.isEmpty {
            await download(arrived, reason: .playlist(id))
        }
        return !departed.isEmpty || !arrived.isEmpty || reordered || renamed
    }

    /// Every song in a playlist, a page at a time.
    private func everything(
        ofPlaylist id: MediaID,
        using provider: any MusicServerProvider
    ) async throws -> (playlist: Playlist, tracks: [Track])? {
        var tracks: [Track] = []
        var offset = 0
        var playlist: Playlist?
        while true {
            let page = try await provider.playlistPage(id: id, offset: offset, limit: Self.playlistPageSize)
            playlist = page.playlist
            tracks.append(contentsOf: page.entries.map(\.track))
            // Rows rather than entries: a row this app cannot make a song out
            // of is dropped, and counting entries would walk the same page for
            // ever.
            guard page.returnedRows > 0 else { break }
            offset += page.returnedRows
            if let total = page.total, offset >= total { break }
            // A short page is the end of the playlist.
            if page.returnedRows < Self.playlistPageSize { break }
            guard offset < Self.playlistTrackLimit else { break }
        }
        guard let playlist else { return nil }
        return (playlist, tracks)
    }

    /// How many songs are asked for at a time.
    private static let playlistPageSize = 1_000
    /// A guard against a server that never says it has finished. Far above any
    /// playlist anyone downloads to a phone.
    private static let playlistTrackLimit = 20_000

    /// Drops one reason from named tracks, deleting the files nothing else
    /// wants. The same rule as `remove(reason:)`, for part of a playlist
    /// rather than all of it.
    private func release(reason: DownloadReason, fromTracks tracks: [MediaID]) {
        let key = reason.key
        batchingCancels {
            for track in tracks {
                guard let record = try? index.download(forTrack: track),
                      record.reasons.contains(key)
                else { continue }
                var left = record.reasons
                left.remove(key)
                if left.isEmpty {
                    discard(track, record: record)
                } else {
                    var record = record
                    record.setReasons(left)
                    try? index.saveDownload(record)
                    reasons[track] = left
                }
            }
        }
    }

    // MARK: Removing

    /// Takes back one reason.
    func hasDownloads(album id: MediaID) -> Bool {
        isRequested(.album(id)) || (try? index.hasDownloadedTracks(inAlbum: id)) == true
    }

    func hasDownloads(artist id: MediaID) -> Bool {
        isRequested(.artist(id)) || (try? index.hasDownloadedTracks(byArtist: id)) == true
    }

    /// Whether there is anything left to fetch.
    func isMissingDownloads(album id: MediaID) -> Bool {
        (try? index.hasUndownloadedTracks(inAlbum: id)) ?? true
    }

    func isMissingDownloads(artist id: MediaID) -> Bool {
        (try? index.hasUndownloadedTracks(byArtist: id)) ?? true
    }

    /// Whether any song the playlist was kept with is not on the phone yet.
    func isMissingDownloads(playlist id: MediaID) -> Bool {
        guard let record = try? index.downloadedPlaylist(id: id) else { return true }
        return record.tracks.contains { raw in
            states[local(MediaID(server: index.server, rawValue: raw))] != .done
        }
    }

    /// Lets a record go, whatever brought it here.
    func removeAlbum(_ id: MediaID) {
        reasonEpoch[DownloadReason.album(id).key, default: 0] += 1
        let inAlbum = Set(((try? index.tracks(inAlbum: id)) ?? []).map(\.id))
        guard !inAlbum.isEmpty else {
            remove(reason: .album(id))
            return
        }
        requested.remove(DownloadReason.album(id).key)
        batchingCancels {
            for record in (try? index.downloads()) ?? [] {
                let track = MediaID(server: index.server, rawValue: record.trackId)
                guard inAlbum.contains(track) else { continue }
                let left = record.reasons.filter {
                    !$0.hasPrefix("album:") && !$0.hasPrefix("artist:")
                }
                if left.isEmpty {
                    discard(track, record: record)
                } else {
                    var record = record
                    record.setReasons(left)
                    try? index.saveDownload(record)
                    reasons[track] = left
                }
            }
        }
        bump()
    }

    /// The same, for everything an artist made.
    func removeArtist(_ id: MediaID) {
        reasonEpoch[DownloadReason.artist(id).key, default: 0] += 1
        let theirs = Set(((try? index.tracks(byArtist: id)) ?? []).map(\.id))
        guard !theirs.isEmpty else {
            remove(reason: .artist(id))
            return
        }
        requested.remove(DownloadReason.artist(id).key)
        batchingCancels {
            for record in (try? index.downloads()) ?? [] {
                let track = MediaID(server: index.server, rawValue: record.trackId)
                guard theirs.contains(track) else { continue }
                let left = record.reasons.filter {
                    !$0.hasPrefix("album:") && !$0.hasPrefix("artist:")
                }
                if left.isEmpty {
                    discard(track, record: record)
                } else {
                    var record = record
                    record.setReasons(left)
                    try? index.saveDownload(record)
                    reasons[track] = left
                }
            }
        }
        bump()
    }

    func remove(reason: DownloadReason) {
        reasonEpoch[reason.key, default: 0] += 1
        requested.remove(reason.key)
        if case .playlist(let id) = reason {
            try? index.deleteDownloadedPlaylist(id: id)
        }
        let key = reason.key
        batchingCancels {
            for record in (try? index.downloads()) ?? [] where record.reasons.contains(key) {
                let track = MediaID(server: index.server, rawValue: record.trackId)
                var left = record.reasons
                left.remove(key)
                if left.isEmpty {
                    discard(track, record: record)
                } else {
                    var record = record
                    record.setReasons(left)
                    try? index.saveDownload(record)
                    reasons[track] = left
                }
            }
        }
        bump()
        scheduleKeepingArtwork()
    }

    /// Removes a track outright, whatever asked for it.
    func remove(track: MediaID) {
        let track = local(track)
        reasonEpoch[DownloadReason.track(track).key, default: 0] += 1
        guard let record = try? index.download(forTrack: track) else { return }
        discard(track, record: record)
        bump()
        scheduleKeepingArtwork()
    }

    private func discard(_ track: MediaID, record: DownloadRecord) {
        // Whether the system can have anything to cancel: a finished song has
        // no transfer, and asking for one costs a walk of every task.
        let hadTransfer = states[track]?.isActive == true
            || inFlight.contains(track) || preparing.contains(track)
        waiting.removeAll { $0.id == track }
        transferFinished(track)
        // A download cancelled mid-conversion leaves a session too, and
        // `transferFinished` only speaks for the one that was running.
        if record.variant != MediaVariant.original.tag {
            Task { [provider] in await provider.endConversion(for: track) }
        }
        // A song removed on its own stops being a reason of its own; the
        // album it came with is still a reason for the rest of the album.
        requested.remove(DownloadReason.track(track).key)
        if hadTransfer { cancelTransfer(track.rawValue) }
        if let name = record.fileName { store.remove(named: name) }
        if let old = record.previousFileName { store.remove(named: old) }
        artStore.remove(for: track)
        previousFileNames[track] = nil
        try? index.deleteDownload(forTrack: track)
        states[track] = nil
        reasons[track] = nil
        fileNames[track] = nil
        retries[track] = nil
        rescues[track] = nil
        preparationWaits[track] = nil
        heldForNetwork.remove(track)
        askedAt[track] = nil
        variants[track] = nil
        lastProgressWrite[track] = nil
    }

    private func cancelTransfer(_ id: String) {
        if cancelBatch != nil {
            cancelBatch?.insert(id)
        } else {
            downloader.cancel(id: id)
        }
    }

    /// Runs a removal that may discard many songs and cancels their transfers
    /// in one pass at the end.
    private func batchingCancels(_ body: () -> Void) {
        let outer = cancelBatch != nil
        if !outer { cancelBatch = [] }
        body()
        guard !outer else { return }
        let ids = cancelBatch ?? []
        cancelBatch = nil
        downloader.cancel(ids: ids)
    }

    func removeEverything() {
        stopGeneration += 1
        preparing = []
        retries = [:]
        started = []
        heldForNetwork = []
        preparationWaits = [:]
        convertingNow = []
        inFlight = []
        waiting = []
        // Neither of these routes through `transferFinished`, which is the only other place the
        // "Download Anyway" permission is taken back — so without this, calling everything off here
        // left it standing for the rest of the session, waving every…
        forgetAnywayIfIdle()
        clearBatch()
        downloader.cancelAll()
        try? index.deleteAllDownloads()
        for playlist in downloadedPlaylists() {
            try? index.deleteDownloadedPlaylist(
                id: MediaID(server: index.server, rawValue: playlist.id)
            )
        }
        store.removeAll()
        artStore.removeAll()
        states = [:]
        reasons = [:]
        requested = []
        fileNames = [:]
        previousFileNames = [:]
        bump()
        scheduleKeepingArtwork()
    }

    // MARK: Reconciliation

    /// Reads the table back, checks it against the files that are really there, and picks up where
    /// the last run left off.
    func start() async {
        guard !isStopped else { return }
        // The downloader is shared across managers of one library: whatever
        // an earlier manager left held is let go, unless a song is being
        // waited for right now.
        if playbackIsFetching?() == true {
            pauseTransfersForPlayback()
        } else {
            transfersPaused = false
            downloader.setPaused(false)
        }
        // Held work is released the moment a cheaper connection arrives, and
        // the moment any connection does.
        if networkListener == nil {
            networkListener = network.onChange { [weak self] _ in
                Task { @MainActor in self?.networkChanged() }
            }
        }
        if pathListener == nil {
            pathListener = network.onPathChange { [weak self] satisfied in
                Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
            }
        }

        // A table that cannot be read is not an empty one.
        var records: [DownloadRecord] = []
        var readFailed = false
        do {
            records = try (recordLoader ?? { try self.index.downloads() })()
        } catch {
            readFailed = true
        }

        let plan = DownloadReconciler.plan(records: records) { name in
            store.existingFile(named: name) == nil ? nil : store.size(of: name)
        }
        var toResume: [DownloadRecord] = []

        for entry in plan.entries {
            let record = entry.record
            let id = MediaID(server: index.server, rawValue: record.trackId)
            reasons[id] = record.reasons
            requested.formUnion(record.reasons)
            fileNames[id] = record.fileName
            askedAt[id] = record.addedAt
            variants[id] = MediaVariant(tag: record.variant)

            switch entry.action {
            case .present:
                states[id] = .done
                tallyIfFinished(id)
                var fixed = record
                var changed = false
                if record.state != .done {
                    fixed.state = .done
                    fixed.bytes = store.size(of: record.fileName ?? "")
                    changed = true
                }
                // The replacement is here; the copy it replaced is swept.
                if record.previousFileName != nil {
                    fixed.previousFileName = nil
                    fixed.previousVariant = nil
                    changed = true
                }
                if changed { try? index.saveDownload(fixed) }
            case .redownload:
                // Owed, or marked done with the file gone. If a replacement
                // was in flight, the copy it replaces is still there to play.
                if let old = record.previousFileName { previousFileNames[id] = old }
                toResume.append(record)
            case .failed(let message):
                states[id] = .failed(message)
                tallyIfFinished(id)
            case .restorePrevious:
                var restored = record
                if restorePrevious(&restored, id: id) {
                    try? index.saveDownload(restored)
                    tallyIfFinished(id)
                }
            }
        }

        hasReadRecords = true

        // An empty table next to files on disk is not a library with nothing in it: it is what an
        // index that was just rebuilt (a corrupt one set aside, a restore without the database)
        // looks like, and the files are the user's downloads.
        let filesOnDisk = ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).isEmpty == false
        if !readFailed, !(records.isEmpty && filesOnDisk),
           ServerSwitching.mayRemoveUnaccountedFiles(managerServer: serverID, indexServer: index.server) {
            _ = store.removeFiles(notNamed: plan.keep)
        }
        listenForEvents()
        Task { await backfillDetails(records) }
        if !readFailed, ServerSwitching.mayRemoveUnaccountedFiles(managerServer: serverID, indexServer: index.server) {
            artStore.removeAll(except: records.filter { $0.state == .done }.map {
                MediaID(server: index.server, rawValue: $0.trackId)
            })
        }
        repairEmbeddedArtwork()
        scheduleKeepingArtwork()
        inspectEmbeddedArtwork(of: records.filter { $0.state == .done }.map {
            MediaID(server: index.server, rawValue: $0.trackId)
        })

        // Counted first, before anything new is started, and in two passes so the order of the
        // table cannot matter.
        let running = Set(await downloader.running())
        guard !isStopped else { return }
        for record in toResume where running.contains(record.trackId) {
            let id = MediaID(server: index.server, rawValue: record.trackId)
            states[id] = .running
            inFlight.insert(id)
            // A carried-over conversion still holds a session open at the far
            // end, and closing it is what `transferFinished` does for the
            // ones it knows about.
            if record.variant != MediaVariant.original.tag { convertingNow.insert(id) }
            // A slot taken with nothing watching it.
            lastActivity[id] = Date()
        }
        if !inFlight.isEmpty { startWatchdogIfNeeded() }

        let owed = toResume.filter { !running.contains($0.trackId) }
        for record in owed {
            states[MediaID(server: index.server, rawValue: record.trackId)] = .queued
        }
        if settings.offlineMode {
            // Offline by choice: asking would fail every one of them, and
            // failing was once what that did. They wait; turning Offline Mode
            // off reconnects, which builds a manager that starts them.
            for record in owed {
                heldForNetwork.insert(MediaID(server: index.server, rawValue: record.trackId))
            }
        } else {
            await resumeAll(owed)
        }

        // After everything above has settled which conversions are alive.
        if !readFailed {
            let alive = Set(inFlight).union(convertingNow)
            startConversionSweep(records: records, skipping: alive)
        }
        bump()
    }

    /// Ends, once per library, the conversion sessions older builds left open on the server.
    private func startConversionSweep(records: [DownloadRecord], skipping alive: Set<MediaID>) {
        let key = "downloads.conversionSweepDone.\(store.directory.lastPathComponent)"
        guard conversionSweep == nil,
              !UserDefaults.standard.bool(forKey: key),
              !settings.offlineMode
        else { return }
        let ids = records.compactMap { record -> MediaID? in
            guard record.state == .done,
                  record.variant != MediaVariant.original.tag,
                  store.existingFile(named: record.fileName) != nil
            else { return nil }
            let id = MediaID(server: index.server, rawValue: record.trackId)
            return alive.contains(id) ? nil : id
        }
        conversionSweep = Task { [weak self, provider] in
            for id in ids {
                guard !Task.isCancelled, let self, !self.isStopped else { return }
                await provider.endConversion(for: id)
            }
            // Only after the whole walk: a sweep cut short by a reconnect
            // starts again at the next one.
            if !Task.isCancelled { UserDefaults.standard.set(true, forKey: key) }
        }
    }

    /// Fills in the name of anything downloaded before the app kept one.
    private func backfillDetails(_ records: [DownloadRecord]) async {
        for record in records where record.title == nil {
            let id = MediaID(server: index.server, rawValue: record.trackId)
            var found = try? index.track(id: id)
            if found == nil {
                guard !settings.offlineMode else { continue }
                found = try? await provider.track(id: id)
            }
            guard let track = found,
                  var stored = try? index.download(forTrack: id)
            else { continue }
            stored.title = track.title
            stored.artistName = track.artistName
            stored.albumName = track.albumName
            stored.artworkId = track.artwork?.rawValue
            stored.duration = track.duration
            try? index.saveDownload(stored)
        }
        bump()
    }

    /// Puts a song from a previous run back on its way.
    private func resume(_ record: DownloadRecord, id: MediaID) async {
        guard !isStopped else { return }
        // Already handed over, or being got ready, by something else — a rescue, a retry, a
        // connection returning.
        guard !inFlight.contains(id), !preparing.contains(id),
              !waiting.contains(where: { $0.id == id })
        else { return }
        // The song, from wherever it can be had: this library's index, what was written down when
        // it was asked for, and the server.
        var found = track(id)
        if found == nil {
            guard !settings.offlineMode else {
                hold(id)
                return
            }
            do {
                found = try await provider.track(id: id)
            } catch let error as ProviderError where error.meansNotFound {
                gone(id, record: record)
                return
            } catch {
                // Unreachable, or the server is having a moment: parked, and
                // asked again when a connection returns.
                hold(id)
                return
            }
        }
        guard !isStopped, let track = found else { return }
        known[id] = track
        await enqueue(
            track,
            reason: record.reasons.first ?? DownloadReason.track(id).key,
            retrying: true
        )
    }

    /// Waits, queued, with nothing behind it, for the network.
    private func hold(_ id: MediaID) {
        states[id] = .queued
        heldForNetwork.insert(id)
        bump()
    }

    /// The server says the song is no longer there. Said so on the row, and
    /// nothing is deleted: a file already on the phone is still a file the
    /// user chose to keep, and the row is where they will look for why.
    private func gone(_ id: MediaID, record: DownloadRecord) {
        var record = record
        record.state = .failed
        record.failure = "This song is no longer on the server."
        try? index.saveDownload(record)
        states[id] = .failed(record.failure ?? "")
        tallyIfFinished(id)
        bump()
    }

    /// Retires this manager.
    func stop() {
        isStopped = true
        stopGeneration += 1
        // The hold is on the downloader, which outlives this manager, and the release is asked of
        // whichever manager is current when the song arrives — not this one.
        resumeTransfersAfterPlayback()
        keepingArtwork?.cancel()
        stopWatchdog()
        pendingBump?.cancel()
        pendingBump = nil
        events?.cancel()
        events = nil
        embeddedRunner?.cancel()
        embeddedRunner = nil
        conversionSweep?.cancel()
        conversionSweep = nil
        if let networkListener { network.removeOnChange(networkListener) }
        networkListener = nil
        if let pathListener { network.removeOnPathChange(pathListener) }
        pathListener = nil
        // Anything waiting for a preparation slot is let go to find it is
        // stopped.
        let waiters = slotWaiters
        slotWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func listenForEvents() {
        guard events == nil, !isStopped else { return }
        // Attached here, synchronously, rather than inside the task: whatever the downloader was
        // holding for a reader is delivered to this one, and the reader before it is finished at
        // this moment, not whenever the task happens to be scheduled.
        let stream = downloader.attach()
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handle(event)
            }
        }
    }

    /// A moving number, and nothing else.
    private func progressed(_ id: MediaID, received: Int64, expected: Int64?) {
        // A transfer nobody is keeping any more has nothing to report, and the row that used to
        // stand guard here is the very read this path exists to avoid — so the state it is mirrored
        // by stands guard instead.
        guard states[id] != nil else { return }
        // The coarse state only when it actually changes.
        if states[id] != .running { states[id] = .running }
        if let total = expected ?? estimatedBytes(for: id), total > 0 {
            fractions[id] = min(1, Double(received) / Double(total))
        }
        let now = Date()
        // Every byte counts as life, not only the ones written down: the
        // write below is throttled to two seconds and cannot answer whether a
        // transfer is still moving.
        lastActivity[id] = now
        noteStarted(id)
        // Ten seconds, not two.
        guard now.timeIntervalSince(lastProgressWrite[id] ?? .distantPast) > 10 else { return }
        lastProgressWrite[id] = now
        guard var record = try? index.download(forTrack: id) else { return }
        record.bytes = received
        record.expectedBytes = expected
        record.state = .running
        try? index.saveDownload(record)
    }

    /// What the queue does about a transfer that did not work.
    private func fail(_ record: inout DownloadRecord, id: MediaID, failure: BackgroundDownloadFailure) -> Bool {
        let isConversion = !(variants[id]?.isOriginal ?? true)
        switch TransferFailureClassifier.disposition(for: failure, isConversion: isConversion) {
        case .waitForNetwork:
            // No connection is not the song's fault. Parked, not failed,
            // and not charged an attempt.
            record.state = .queued
            record.failure = nil
            try? index.saveDownload(record)
            states[id] = .queued
            heldForNetwork.insert(id)
            bump()
            return true
        case .proxyWall:
            // Every other transfer would meet the same page. This one waits
            // with the rest, and the user is asked to sign in, once.
            record.state = .queued
            record.failure = nil
            try? index.saveDownload(record)
            states[id] = .queued
            heldForNetwork.insert(id)
            raiseWall(failure)
            bump()
            return true
        case .retryable:
            let used = retries[id, default: 0]
            if used + 1 < Self.attempts, let track = track(id) {
                retries[id] = used + 1
                record.state = .queued
                record.failure = nil
                states[id] = .queued
                try? index.saveDownload(record)
                let reason = record.reasons.first ?? DownloadReason.track(id).key
                // A moment for the server to finish whatever it was
                // struggling with, longer each time.
                scheduleRetry(track, reason: reason, after: Double(used + 1) * 2)
                bump()
                return true
            }
        case .storageFull:
            sayStorageFull()
        case .terminal:
            break
        }
        // A replacement that could not be fetched leaves the song as it was
        // rather than failing a copy that is sitting on the phone.
        if restorePrevious(&record, id: id) {
            tallyIfFinished(id)
            return false
        }
        record.state = .failed
        record.failure = failure.message
        states[id] = .failed(failure.message)
        tallyIfFinished(id)
        return false
    }

    private func raiseWall(_ failure: BackgroundDownloadFailure) {
        guard !wallRaised else { return }
        wallRaised = true
        var page: URL?
        if case .foreignHost(let url) = failure { page = url }
        onProxyWall?(page)
    }

    /// Whether a finished conversion is too small to be the song.
    private func shortConversion(_ id: MediaID, bytes: Int64) -> NotAudioReason? {
        guard let estimate = estimatedBytes(for: id), estimate > 0 else { return nil }
        guard Double(bytes) < Double(estimate) * Self.shortConversionFloor else { return nil }
        return .lengthMismatch(expected: estimate, actual: bytes)
    }

    /// A fraction of the estimate under which a converted file is a fragment.
    static let shortConversionFloor = 0.25

    /// The first bytes of a transfer, which is when it starts to count as one
    /// that can stall — and when a rescue it went through has done its job.
    private func noteStarted(_ id: MediaID) {
        guard states[id] != nil else { return }
        lastActivity[id] = Date()
        if started.insert(id).inserted { rescues[id] = nil }
    }

    private func handle(_ event: BackgroundDownloadEvent) {
        guard !isStopped else { return }
        let id = MediaID(server: index.server, rawValue: event.id)
        // Progress first, and without the database.
        if case .progress(let received, let expected) = event.kind {
            progressed(id, received: received, expected: expected)
            return
        }
        // Signs of life, and nothing to write down.
        if case .started = event.kind {
            noteStarted(id)
            return
        }
        if case .waiting = event.kind {
            if states[id] != nil { lastActivity[id] = Date() }
            return
        }
        guard var record = try? index.download(forTrack: id) else { return }
        switch event.kind {
        case .progress, .started, .waiting:
            return
        case .finished(let url):
            transferFinished(id)
            let bytes = store.size(of: url.lastPathComponent)
            // A conversion the server cut short arrives as a smaller file with nothing to say it is
            // incomplete: no length is announced, and the body simply ends.
            if let short = shortConversion(id, bytes: bytes) {
                store.remove(named: url.lastPathComponent)
                if fail(&record, id: id, failure: .notAudio(short)) { return }
                break
            }
            record.state = .done
            record.fileName = url.lastPathComponent
            // The replacement is in place, so the copy it replaces can go.
            if let old = record.previousFileName, old != url.lastPathComponent {
                store.remove(named: old)
            }
            record.previousFileName = nil
            record.previousVariant = nil
            previousFileNames[id] = nil
            record.bytes = bytes
            batchBytes += record.bytes ?? 0
            record.failure = nil
            fileNames[id] = url.lastPathComponent
            states[id] = .done
            // A song that got there is a fresh start: its next failure, in
            // some later refetch, is not the third of an old one.
            retries[id] = nil
            rescues[id] = nil
            preparationWaits[id] = nil
            heldForNetwork.remove(id)
            tallyIfFinished(id)
            forgetEmbeddedArtwork(id)
            inspectEmbeddedArtwork(of: [id])
        case .failed(let failure):
            transferFinished(id)
            // Cancelled on purpose, to let a song be heard. Nothing went
            // wrong with it, so it neither fails nor spends one of its own
            // attempts — `playbackFinishedFetching` asks for it again.
            guard !heldForPlayback.contains(id) else { return }
            if fail(&record, id: id, failure: failure) { return }
        }
        try? index.saveDownload(record)
        noteBatchIfFinished()
        bump()
    }

    /// Writes down how long a run of transfers took, once the last of them has landed.
    private func clearBatch() {
        batchStarted = nil
        batchSize = 0
        batchBytes = 0
        counted = []
        finishedInBatch = 0
        tallied = []
        // Nothing left to watch, and nothing left to hold against a song:
        // asking for it again is a fresh start, not a continuation of the
        // run that was stopped.
        lastActivity = [:]
        rescues = [:]
        saidStorageFull = false
        stopWatchdog()
    }

    /// Whether anything at all is still going: in flight, parked for a slot, or still being asked
    /// about.
    private var isBatchStillRunning: Bool {
        isDownloading || !preparing.isEmpty || !waiting.isEmpty || !inFlight.isEmpty
    }

    private func noteBatchIfFinished() {
        guard let started = batchStarted, !isBatchStillRunning else { return }
        let seconds = Date().timeIntervalSince(started)
        let songs = batchSize
        let bytes = batchBytes
        clearBatch()
        guard songs > 0, seconds > 1 else { return }
        let perMinute = Double(songs) / (seconds / 60)
        // Songs a minute answers "how long will my album take"; megabytes a second answers "is the
        // connection or the server the problem".
        let rate = bytes > 0
            ? String(format: " — %.1f MB/s", Double(bytes) / 1_000_000 / seconds)
            : ""
        settings.lastBatchSummary = String(
            format: "%d songs in %@ — %.1f a minute%@",
            songs,
            Self.spell(seconds),
            perMinute,
            rate
        )
    }

    private static func spell(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }

    /// Tells the screens something moved — at most a few times a second.
    private func bump() {
        let now = Date()
        guard now.timeIntervalSince(lastBump) < Self.bumpInterval else {
            lastBump = now
            pendingBump?.cancel()
            pendingBump = nil
            version &+= 1
            return
        }
        guard pendingBump == nil else { return }
        pendingBump = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.bumpInterval))
            guard let self, !Task.isCancelled else { return }
            self.pendingBump = nil
            self.lastBump = Date()
            self.version &+= 1
        }
    }

    /// Four times a second: fast enough that a list never looks stuck, slow
    /// enough that a burst of preparation cannot flood the main thread.
    private static let bumpInterval: TimeInterval = 0.25
    private var lastBump = Date.distantPast
    private var pendingBump: Task<Void, Never>?
}
