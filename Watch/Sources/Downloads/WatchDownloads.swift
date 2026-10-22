import Foundation
import AVFoundation
import Observation
import os
import WatchKit
import PleviAudio
import PleviDomain
import PleviLibraryIndex
import PleviTransport

/// What is kept on the watch, and what is on its way.
@MainActor
@Observable
final class WatchDownloads {
    enum State: Equatable, Sendable {
        case queued
        case running
        case done
        case failed(String)

        var isActive: Bool {
            switch self {
            case .queued, .running: true
            case .done, .failed: false
            }
        }
    }

    private(set) var states: [MediaID: State] = [:]

    /// How far each transfer in flight has got, kept apart from `states`.
    private(set) var fractions: [MediaID: Double] = [:]

    /// What the batch on the go is called, for the one progress line.
    private(set) var runningTitle: String?

    /// Why the queue is holding itself, said once on the queue page: the watch
    /// is full, or a sign-in page is in the way. Every other song would fail
    /// the same way, so the queue stops instead of failing them all.
    private(set) var holdMessage: String?

    /// Told when a failure is the sort an unreachable address explains, so the
    /// model can choose the address again. Wired by `WatchModel`.
    @ObservationIgnored
    var onTrouble: (() -> Void)?

    /// The queue waits until this time before starting anything, after a failure that was the
    /// server's or the link's moment.
    @ObservationIgnored
    private var retryAfter: Date?
    @ObservationIgnored
    private var retryTask: Task<Void, Never>?

    private let index: LibraryIndex
    private let store: DownloadStore
    private let storage: ServerID
    private let downloader: BackgroundDownloader
    private let provider: any MusicServerProvider
    private let settings: WatchSettings
    private let config: ServerConfig
    /// The sign-in for a proxy in front of the server.
    private let proxySessions: ProxySessionHolder
    @ObservationIgnored
    private var fileNames: [MediaID: String] = [:]
    private var requested: Set<String> = []
    private static let log = Logger(subsystem: AppIdentity.phone, category: "watchDownloads")

    init(
        index: LibraryIndex,
        storage: ServerID,
        config: ServerConfig,
        provider: any MusicServerProvider,
        downloader: BackgroundDownloader,
        settings: WatchSettings,
        proxySessions: ProxySessionHolder
    ) {
        self.index = index
        self.storage = storage
        self.config = config
        self.provider = provider
        self.downloader = downloader
        self.settings = settings
        self.proxySessions = proxySessions
        self.store = DownloadStore(serverID: storage)
        restore()
    }

    /// What the table already says, so a relaunch does not forget what is on
    /// the disk it is looking at.
    private func restore() {
        for record in (try? index.downloads()) ?? [] {
            let id = MediaID(server: storage, rawValue: record.trackId)
            fileNames[id] = record.fileName
            remember(record, id: id)
            states[id] = switch record.state {
            case .done: .done
            case .failed: .failed(record.failure ?? "It did not finish.")
            case .queued, .running: .queued
            }
            // Songs still owed are a run, from the first draw.
            if states[id]?.isActive == true { count(id) }
            if let order = record.queueOrder {
                entries[id] = Entry(
                    title: record.title ?? "A song", artist: record.artistName, order: order
                )
            }
            // Off non-failed rows only, the same rule `clearQueue` and `drop` keep.
            if record.state != .failed { requested.formUnion(record.reasons) }
        }
        // The queue itself, back in the order it was asked for.
        nextQueueOrder = ((try? index.highestQueueOrder()) ?? nil) ?? 0
        for record in (try? index.queuedDownloads()) ?? [] {
            let id = MediaID(server: storage, rawValue: record.trackId)
            // The run is what the table says it is.
            count(id)
            if record.state == .done || record.state == .failed { tally(id) }
            guard record.state == .queued || record.state == .running else { continue }
            // Sorted so a set's order does not decide which reason a resumed
            // song carries. Whichever it is, the others are already on the
            // row and nothing here takes them off.
            guard states[id]?.isActive == true,
                  let resumed = resumable(record)
            else { continue }
            waiting.append(resumed)
        }
        sortWaiting()
    }

    /// Takes back off the row what a transfer in flight will need to be measured and checked.
    private func remember(_ record: DownloadRecord, id: MediaID) {
        if let duration = record.duration { durations[id] = duration }
        // Only from a row a transfer actually spoke for.
        guard record.fileName != nil, let variant = MediaVariant(tag: record.variant) else { return }
        variants[id] = variant
    }

    /// Settles the table against the disk and against the system's own queue.
    func reconcile() async {
        let carrying = Set(await downloader.running())
        // A table that cannot be read is not an empty one.
        var records: [DownloadRecord] = []
        var readFailed = false
        do {
            records = try index.downloads()
        } catch {
            readFailed = true
            Self.log.error("could not read the download table: \(error.localizedDescription, privacy: .public)")
        }
        // The same planner the phone settles its table with.
        let plan = DownloadReconciler.plan(records: records) { name in
            store.existingFile(named: name) == nil ? nil : store.size(of: name)
        }
        var changed: [DownloadRecord] = []
        for entry in plan.entries {
            let record = entry.record
            let id = MediaID(server: storage, rawValue: record.trackId)
            let onDisk = entry.action == .present
            var row = record
            remember(record, id: id)
            switch record.state {
            case .done where onDisk:
                // A file the server sent with no extension and nobody could
                // name was saved as `.audio`, which AVFoundation refuses.
                // The bytes say what it is.
                if let name = record.fileName, name.hasSuffix(".audio"), fileNames[id] == name,
                   let unplayable = nameFileByContent(id) {
                    row.state = .failed
                    row.failure = unplayable
                    states[id] = .failed(unplayable)
                    store.remove(named: name)
                    tally(id)
                    changed.append(row)
                }
                continue
            case .done where !onDisk:
                // Marked done and the file is gone: a restored backup, a
                // wipe, storage pressure. Owed again, not failed — the song
                // was asked for and nothing about it was refused. Failed only
                // when there is no way to rebuild it.
                guard let (track, _) = resumable(record) else {
                    row.state = .failed
                    row.failure = "The file is no longer on this watch."
                    states[id] = .failed(row.failure ?? "")
                    tally(id)
                    break
                }
                nextQueueOrder += 1
                row.state = .queued
                row.failure = nil
                row.queueOrder = nextQueueOrder
                states[id] = .queued
                count(id)
                entries[id] = Entry(
                    title: row.title ?? track.title, artist: row.artistName, order: nextQueueOrder
                )
                if let (resumedTrack, reason) = resumable(record),
                   !waiting.contains(where: { $0.track.id == id }) {
                    waiting.append((track: resumedTrack, reason: reason))
                }
            case .queued, .running:
                if onDisk {
                    // Checked here as well as in `apply`, because this is the other way a
                    // background completion arrives: the file is simply *there* at the next launch
                    // and no event survived to say so.
                    if let short = tooShort(id) {
                        row.state = .failed
                        row.failure = short
                        states[id] = .failed(short)
                        if let name = record.fileName { store.remove(named: name) }
                        tally(id)
                        changed.append(row)
                        continue
                    }
                    row.state = .done
                    row.failure = nil
                    states[id] = .done
                    tally(id)
                } else if carrying.contains(record.trackId) {
                    // Still on its way; the events will say when it lands.
                    states[id] = .running
                    // And it holds the lane, if it is a conversion.
                    if converting == nil, variants[id]?.isOriginal == false {
                        converting = id
                        lastActivity[id] = Date()
                        startWatchdog()
                    }
                    // And out of the queue.
                    waiting.removeAll { $0.track.id == id }
                    // And it is part of a run, so the bar has something to divide by.
                    count(id)
                    running.insert(id)
                    continue
                } else {
                    // A row nothing can rebuild into a song is worse than a failure: it would count
                    // towards the run, keep the ring turning, and no Start Again could ever pick it
                    // up, because rebuilding it is precisely what cannot be done.
                    guard record.queueOrder != nil, resumable(record) != nil
                    else {
                        row.state = .failed
                        row.failure = "It did not finish."
                        states[id] = .failed(row.failure ?? "")
                        tally(id)
                        break
                    }
                    // Owed, not broken.
                    states[id] = .queued
                    // A row with a file name is one `start` got as far as handing over: a
                    // conversion this watch opened and then died holding, which nothing else will
                    // ever close and which the server counts against everyone.
                    if record.fileName != nil { endConversion(id) }
                    continue
                }
            default:
                continue
            }
            changed.append(row)
        }
        // One transaction for everything settled, not one per song.
        try? index.saveDownloads(changed)
        // Songs on the disk that no row speaks for — a wipe interrupted, or a transfer that landed
        // after its row was deleted.
        let skipOnce = Self.takeSkipSweep(for: storage)
        if DownloadSweepPolicy.maySweep(readSucceeded: !readFailed, skipOnce: skipOnce) {
            let swept = store.removeFiles(notNamed: plan.keep)
            if swept > 0 { Self.log.info("swept \(swept, privacy: .public) orphaned files") }
        }
        endRun()
        // Anything asked for while this was settling has been waiting for it.
        isSettled = true
        await drain()
    }

    // MARK: Asking

    // MARK: Sweep hold-off

    private static func skipSweepKey(_ storage: ServerID) -> String {
        "watch.skipSweep.\(storage.rawValue.uuidString)"
    }

    /// Left by `PhoneLink.install` when the rows of the library being
    /// replaced could not be read and so could not be carried across.
    static func holdNextSweep(for storage: ServerID, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: skipSweepKey(storage))
    }

    /// Reads and clears it: the hold-off is for one sweep, not for ever.
    private static func takeSkipSweep(for storage: ServerID, defaults: UserDefaults = .standard) -> Bool {
        let held = defaults.bool(forKey: skipSweepKey(storage))
        if held { defaults.removeObject(forKey: skipSweepKey(storage)) }
        return held
    }

    func isDownloaded(_ id: MediaID) -> Bool { states[id] == .done }

    func isRequested(_ reason: DownloadReason) -> Bool { requested.contains(reason.key) }

    var activeCount: Int { states.values.lazy.filter(\.isActive).count }

    /// Asked without counting, because it is read from the body of both
    /// pages: this is a boolean, and `activeCount > 0` built an array of
    /// every active song to answer it.
    var isDownloading: Bool { states.values.contains(where: \.isActive) }

    /// How many songs are actually here, for screens that must refresh as
    /// that number moves.
    var doneCount: Int { states.values.lazy.filter { $0 == .done }.count }

    /// How far the run has got, from nothing to one, or `nil` when there is no run.
    var progress: Double? {
        guard runSize > 0 else { return nil }
        // The songs that are over are tallied as they finish rather than recounted here, because
        // this is read from a body while transfers report five times a second — and `states` holds
        // a row for every song ever kept on this watch, not just the ones…
        var landed = Double(runFinished)
        // Only songs this run is actually counting, and only ones not already
        // tallied as over — otherwise a song can be described twice, once in
        // each half of the sum.
        let fractions = self.fractions
        for id in running where counted.contains(id) && !tallied.contains(id) {
            landed += fractions[id] ?? 0
        }
        return min(1, landed / Double(runSize))
    }

    /// The same thing in the words somebody would use, for the line above the bar.
    var queueHeadline: String? {
        guard runSize > 0 else { return nil }
        return "\(runFinished) of \(runSize.counted("song"))"
    }

    /// How many songs this run began with, and how many are over.
    private var runSize = 0
    private var runFinished = 0
    /// Songs already counted into this run, so a song asked for twice is one
    /// song, and songs already tallied as over, so one that fails after
    /// finishing is counted once.
    @ObservationIgnored
    private var counted: Set<MediaID> = []
    @ObservationIgnored
    private var tallied: Set<MediaID> = []
    /// The transfers actually in flight, which is what `progress` walks. Never
    /// `states`, which is every song on the watch.
    private var running: Set<MediaID> = []

    /// Counts a song into the run, once.
    private func count(_ id: MediaID) {
        if tallied.remove(id) != nil { runFinished -= 1 }
        guard !counted.contains(id) else { return }
        counted.insert(id)
        runSize += 1
    }

    /// Records that a song is over, once, however it ended.
    private func tally(_ id: MediaID) {
        running.remove(id)
        fractions[id] = nil
        guard counted.contains(id), !tallied.contains(id) else { return }
        tallied.insert(id)
        runFinished += 1
    }

    /// The end of a run, wherever it is reached from.
    private func endRun() {
        guard !isDownloading else { return }
        // Felt, not just seen.
        if runSize > 0 {
            WKInterfaceDevice.current().play(failureCount > 0 ? .failure : .success)
        }
        runningTitle = nil
        runSize = 0
        runFinished = 0
        counted = []
        tallied = []
        running = []
        fractions = [:]
        entries = [:]
        lastActivity = [:]
        rescues = [:]
        holdMessage = nil
        cancelRetry()
        stopWatchdog()
        // The places are given back too, or the next run's first song sits
        // behind a queue that is not there any more — and every finished song
        // would go on counting towards a run that is over.
        try? index.clearQueueOrder()
        nextQueueOrder = 0
        // And the hold goes with it.
        settings.isDownloadQueuePaused = false
    }

    func fileURL(for id: MediaID) -> URL? {
        guard states[id] == .done else { return nil }
        return store.existingFile(named: fileNames[id])
    }

    func usage() -> Int64 { store.usage() }

    /// The same figure, without holding the main actor while it is counted.
    nonisolated func usageOffMainActor() async -> Int64 {
        let store = self.store
        return await Task.detached(priority: .utility) { store.usage() }.value
    }

    // MARK: Starting

    /// - Returns: a sentence for the wearer when nothing could be queued for a
    ///   reason they can act on (no room); nil otherwise.
    @discardableResult
    func download(_ tracks: [Track], reason: DownloadReason, named title: String) async -> String? {
        guard !tracks.isEmpty else { return nil }
        requested.insert(reason.key)
        // A song already on this watch still gains the new reason.
        var topped: [DownloadRecord] = []
        for var row in (try? index.downloads(forTracks: tracks.map(\.id))) ?? [] {
            var reasons = Set(row.reasons)
            guard !reasons.contains(reason.key) else { continue }
            reasons.insert(reason.key)
            row.setReasons(reasons)
            topped.append(row)
        }
        save(topped)
        // Not the ones already on their way, either. Handing the same song to
        // the system twice is two transfers writing one file.
        var wanted = tracks.filter {
            states[$0.id] != .done
                && !(states[$0.id]?.isActive ?? false)
                // And not one whose turn has come and whose request is still out with the server.
                && preparing[$0.id] == nil
        }
        // Named only once there is something to name.
        guard !wanted.isEmpty else {
            endRun()
            return nil
        }
        // Room for it, before anything is handed to the system.
        if let free = Self.freeSpace() {
            let fit = WatchDownloadRoom.countThatFit(
                sizes: wanted.map(estimatedSize(of:)), free: free
            )
            if fit < wanted.count {
                guard fit > 0 else {
                    endRun()
                    return "Not enough room on this watch. Free some space in Settings."
                }
                wanted = Array(wanted.prefix(fit))
                holdMessage = "Only \(fit) of \(tracks.count) songs fit on this watch."
            }
        }
        runningTitle = title
        // The whole batch is spoken for before any of it starts, because `start` asks the server
        // where the file is and that answer takes a moment.
        enqueueRows(wanted, reason: reason)
        // One conversion at a time, the rest held here.
        for track in wanted where !waiting.contains(where: { $0.track.id == track.id }) {
            waiting.append((track: track, reason: reason))
        }
        await drain()
        return nil
    }

    /// Writes down that a song is owed, before anything is done about it.
    private func enqueueRows(_ tracks: [Track], reason: DownloadReason) {
        let existing = Dictionary(
            ((try? index.downloads(forTracks: tracks.map(\.id))) ?? []).map { ($0.trackId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [DownloadRecord] = []
        rows.reserveCapacity(tracks.count)
        for track in tracks {
            states[track.id] = .queued
            count(track.id)
            var reasons = Set(existing[track.id.rawValue]?.reasons ?? [])
            reasons.insert(reason.key)
            nextQueueOrder += 1
            var row = DownloadRecord(
                trackId: track.id.rawValue,
                state: .queued,
                variant: MediaVariant.original.tag,
                title: track.title,
                artistName: track.artistName,
                albumName: track.albumName,
                artworkId: track.artwork?.rawValue,
                duration: track.duration,
                queueOrder: nextQueueOrder
            )
            row.setReasons(reasons)
            rows.append(row)
            durations[track.id] = track.duration
            entries[track.id] = Entry(
                title: track.title, artist: track.artistName, order: nextQueueOrder
            )
        }
        save(rows)
    }

    /// What a song is expected to take on this watch, for the room check.
    private func estimatedSize(of track: Track) -> Int64? {
        let choice = settings.downloads
        let policy = TranscodePolicy.watch(
            transcoding: choice.converts,
            kbps: choice.kbps,
            codec: choice.format.rawValue
        )
        if policy.target(forCodec: track.codec ?? track.contentType, bitRateKbps: track.bitRateKbps) != nil {
            return estimatedConversionBytes(kbps: policy.targetBitRateKbps, duration: track.duration)
        }
        return estimatedConversionBytes(kbps: track.bitRateKbps, duration: track.duration)
    }

    /// Space left on the watch. `attributesOfFileSystem` rather than the
    /// resource keys: the "important usage" capacity is unavailable on
    /// watchOS, and the plain one is an `Int` of thirty-two bits here.
    static func freeSpace() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Writes rows, and says so when it cannot.
    private func save(_ rows: [DownloadRecord]) {
        guard !rows.isEmpty else { return }
        do {
            try index.saveDownloads(rows)
        } catch {
            noteWriteFailure(error)
        }
    }

    private func save(_ row: DownloadRecord) {
        do {
            try index.saveDownload(row)
        } catch {
            noteWriteFailure(error)
        }
    }

    private func noteWriteFailure(_ error: any Error) {
        Self.log.error("could not write the download table: \(error.localizedDescription, privacy: .public)")
        if TransferFailureClassifier.isOutOfSpace(error) {
            holdQueue(message: WatchDownloadRecovery.message(for: .storageFull))
        }
    }

    /// The last place given out, so a song asked for next goes behind
    /// everything already waiting rather than in among it.
    @ObservationIgnored
    private var nextQueueOrder = 0

    /// What each queued song is, for a screen that lists them.
    struct Entry: Sendable {
        var title: String
        var artist: String?
        var order: Int
    }

    @ObservationIgnored
    private var entries: [MediaID: Entry] = [:]

    /// Songs asked for and not yet started. See `download(_:reason:named:)`.
    private var waiting: [(track: Track, reason: DownloadReason)] = []

    /// A record's track and its reason, when both can still be worked out — the three lines every
    /// place below that turns a stored row back into something `start` can be given, done once
    /// rather than copy-pasted at each of them.
    private func resumable(_ record: DownloadRecord) -> (track: Track, reason: DownloadReason)? {
        let indexed = try? index.track(id: MediaID(server: storage, rawValue: record.trackId))
        guard let track = indexed ?? record.rememberedTrack(server: storage),
              let key = record.reasons.sorted().first,
              let reason = DownloadReason(key: key, server: storage)
        else { return nil }
        return (track, reason)
    }

    /// The song whose conversion is in flight, where there is one.
    private var converting: MediaID?
    /// The song being asked about, which is not yet the song in the lane.
    @ObservationIgnored
    private var preparing: [MediaID: Int] = [:]
    /// Ticks once per attempt, so each one can tell its own slot from a
    /// later attempt's.
    @ObservationIgnored
    private var nextAttempt = 0
    /// Whether `reconcile` has settled the table against the system's own queue yet.
    @ObservationIgnored
    private var isSettled = false

    /// Whether the queue is being held. Persisted — see `WatchSettings`.
    var isPaused: Bool { settings.isDownloadQueuePaused }

    /// Songs are owed and nothing whatever is being done about them.
    var isStalled: Bool {
        !isPaused && isDownloading
            && converting == nil && preparing.isEmpty
            && waiting.isEmpty && running.isEmpty
    }

    /// How many songs are still owed, for the row that offers the queue.
    var queueCount: Int { runSize - runFinished }
    /// Bumped whenever the queue is called off, so a song whose preparation was already in the air
    /// when Stop was pressed knows not to land.
    @ObservationIgnored
    private var stopGeneration = 0

    /// Whether the queue is sitting out the pause a failure asked for.
    private var isWaitingToRetry: Bool {
        retryAfter.map { $0 > Date() } ?? false
    }

    /// Makes the queue wait `seconds` before it starts anything, and looks
    /// again when they are up. Stop and Pause call it off; a nudge from the
    /// endpoint refresh ends the wait early (see `restartQueue`).
    private func scheduleRetry(after seconds: TimeInterval) {
        let due = Date().addingTimeInterval(seconds)
        if let current = retryAfter, current > due {} else { retryAfter = due }
        let wait = max(0, (retryAfter ?? due).timeIntervalSinceNow)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            retryAfter = nil
            await drain()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryAfter = nil
    }

    /// Holds the queue where it is, once, with one message. The song that hit
    /// the wall has already been put back and keeps its place.
    private func holdQueue(message: String) {
        holdMessage = message
        pauseQueue()
    }

    /// Acts on a recovery decision that is not "fail the song". True when the
    /// song was dealt with here.
    private func applyRecovery(_ decision: WatchDownloadRecovery.Decision, for id: MediaID) -> Bool {
        switch decision {
        case .fail:
            return false
        case .retry(let seconds, let charges):
            if charges { rescues[id, default: 0] += 1 }
            returnToQueue(id)
            sortWaiting()
            scheduleRetry(after: seconds)
            // A server or a link that is not answering may be answering at
            // the wrong address.
            onTrouble?()
            return true
        case .holdQueue(let disposition):
            returnToQueue(id)
            sortWaiting()
            holdQueue(message: WatchDownloadRecovery.message(for: disposition))
            return true
        }
    }

    /// Starts the next song, if the one before it is done.
    private func drain() async {
        // `Task.isCancelled` because a drain can be running inside a wait
        // somebody has given up on — see `WatchModel.waitBriefly`. Without it
        // the loop went on starting songs after the wake was over.
        while !Task.isCancelled,
              isSettled, !isPaused, !isWaitingToRetry,
              converting == nil, preparing.isEmpty, !waiting.isEmpty {
            let next = waiting.removeFirst()
            // Cancelled, or already here, while it waited its turn — and not one the downloader is
            // already carrying, which is the state a song restored from the table arrives in.
            guard states[next.track.id] == .queued,
                  !running.contains(next.track.id)
            else { continue }
            await start(next.track, reason: next.reason)
        }
    }

    /// Tells the server to stop converting a song this watch has stopped wanting.
    private func endConversion(_ id: MediaID, variantTag: String? = nil) {
        // From the row where one is offered, because `forget` takes the
        // in-memory variant with it and a relaunch never had one.
        let variant = variantTag.flatMap(MediaVariant.init(tag:)) ?? variants[id]
        guard variant?.isOriginal == false else { return }
        // Chained behind whatever stop is already in the air for this song, and kept so `start` can
        // wait for it.
        let previous = stopping[id]
        // Told apart from whatever stop comes after it, so this one only ever clears its own entry
        // — the same bargain `MediaFileStore.Transfer` makes with its own token, for the same
        // reason: a name is not enough once a second thing can arrive under…
        let token = UUID()
        stoppingTokens[id] = token
        stopping[id] = Task { [provider, weak self] in
            await previous?.value
            // And not for ever.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await provider.endConversion(for: id) }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            // Its own entry, once it is done with it.
            if self?.stoppingTokens[id] == token {
                self?.stopping[id] = nil
                self?.stoppingTokens[id] = nil
            }
        }
    }

    /// Stops asked for and not yet acknowledged. See `endConversion`.
    @ObservationIgnored
    private var stopping: [MediaID: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var stoppingTokens: [MediaID: UUID] = [:]

    /// When each transfer last showed any sign of life.
    @ObservationIgnored
    private var lastActivity: [MediaID: Date] = [:]
    /// How many times each has been picked up and started again, so a song
    /// the server will never send does not restart for ever.
    @ObservationIgnored
    private var rescues: [MediaID: Int] = [:]
    @ObservationIgnored
    private var watchdog: Task<Void, Never>?

    /// Watches the song in the lane for signs of life, and moves the queue on when there are none.
    private static let stallAfter: TimeInterval = 300
    private static let rescueLimit = 2

    /// When the watchdog last looked. A gap far longer than its own interval
    /// means the app was suspended — the wrist dropped — and the silence of
    /// those minutes is not evidence about any transfer.
    @ObservationIgnored
    private var lastSweep: Date?

    /// The app came forward: transfers could not report while it was asleep,
    /// so their silence starts counting from now.
    func noteForeground() {
        let now = Date()
        for id in lastActivity.keys { lastActivity[id] = now }
        lastSweep = now
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        lastSweep = Date()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                await self.rescueTheStalled()
            }
        }
    }

    /// Fails or restarts the song in the lane when it has stopped moving.
    private func rescueTheStalled() async {
        guard !isPaused else { return }
        // Everything this app believes is in flight, not only the song in the lane.
        var candidates = Array(running)
        if let holder = converting, !candidates.contains(holder) { candidates.append(holder) }
        guard !candidates.isEmpty else { stopWatchdog(); return }
        // Awake time, not wall-clock time.
        let now = Date()
        if WatchDownloadRecovery.sweepWasStarved(since: lastSweep, now: now) {
            for id in candidates { lastActivity[id] = now }
        }
        lastSweep = now
        let carried = Set(await downloader.running())
        // Asking the system took a moment, and Stop can land inside it —
        // rescuing songs a moment after somebody called the whole thing off
        // is the one thing a watchdog must not do.
        guard !isPaused, !isRetired else { return }
        var restarted = false
        for id in candidates {
            // A song whose request is still out with the server is not stuck,
            // it is being asked for.
            guard preparing[id] == nil, states[id]?.isActive == true else { continue }
            let missing = !carried.contains(id.rawValue)
            // Silence counts against the song in the lane and nothing else.
            let silence = lastActivity[id].map { Date().timeIntervalSince($0) } ?? 0
            let silent = converting == id && silence > Self.stallAfter
            guard missing || silent else { continue }

            let attempts = rescues[id, default: 0]
            guard attempts < Self.rescueLimit else {
                Self.log.error("giving up on \(id.rawValue, privacy: .public)")
                downloader.cancel(id: id.rawValue)
                let message = "\(Stage.transferring.rawValue): "
                    + "it stopped part way and did not start again."
                states[id] = .failed(message)
                if var row = try? index.download(forTrack: id) {
                    row.state = .failed
                    row.failure = message
                    try? index.saveDownload(row)
                }
                tally(id)
                // Which closes the conversion as well as freeing the lane, so
                // this path does not send Plex a second stop for one session.
                transferEnded(id)
                continue
            }
            rescues[id] = attempts + 1
            Self.log.info("restarting stalled \(id.rawValue, privacy: .public)")
            downloader.cancel(id: id.rawValue)
            endConversion(id)
            if converting == id { converting = nil }
            lastActivity[id] = nil
            returnToQueue(id)
            restarted = true
        }
        if restarted { sortWaiting() }
        endRun()
        await drain()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        lastSweep = nil
    }

    /// Called when a transfer ends, however it ended.
    private func transferEnded(_ id: MediaID) {
        if converting == id {
            converting = nil
            // Whatever ended it.
            endConversion(id)
        }
        Task { [weak self] in await self?.drain() }
    }

    /// A playlist is kept whole — its name, its picture and the order of its songs — because
    /// offline there is no server to ask what it was.
    @discardableResult
    func download(playlist: Playlist, tracks: [Track]) async -> String? {
        guard !tracks.isEmpty else { return nil }
        try? index.saveDownloadedPlaylist(DownloadedPlaylistRecord(
            id: playlist.id.rawValue,
            name: playlist.name,
            artworkId: playlist.artwork?.rawValue,
            trackIds: tracks.map(\.id.rawValue)
        ))
        return await download(tracks, reason: .playlist(playlist.id), named: playlist.name)
    }

    private func start(_ track: Track, reason: DownloadReason) async {
        nextAttempt += 1
        let attempt = nextAttempt
        preparing[track.id] = attempt
        // Only ever this attempt's own slot. See `preparing`.
        defer { if preparing[track.id] == attempt { preparing[track.id] = nil } }
        // Which run this song belongs to. Everything below happens on the far
        // side of a round trip to the server, and Stop can land inside it.
        let generation = stopGeneration
        // And after any stop still owed for this song, so the server is never
        // asked to close the conversion this is about to open.
        if let stop = stopping.removeValue(forKey: track.id) {
            stoppingTokens[track.id] = nil
            // Raced rather than plainly awaited.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await stop.value }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                await group.next()
                group.cancelAll()
            }
        }
        let choice = settings.downloads
        let policy = TranscodePolicy.watch(
            transcoding: choice.converts,
            kbps: choice.kbps,
            codec: choice.format.rawValue
        )
        var options = StreamOptions.original
        // What the row already says this song is, where it says anything.
        if case .converted(let codec, let kbps)? = variants[track.id] {
            options = StreamOptions(
                maxBitRateKbps: kbps,
                transcodeTo: TranscodeCodec(rawValue: codec) ?? .mp3
            )
        } else if variants[track.id] == nil, let target = policy.target(
            forCodec: track.codec ?? track.contentType, bitRateKbps: track.bitRateKbps
        ) {
            options = StreamOptions(
                maxBitRateKbps: policy.targetBitRateKbps,
                transcodeTo: TranscodeCodec(rawValue: target) ?? .mp3
            )
        }
        // The lane is taken before the server is asked, not after it answers.
        if options.transcodeTo != nil { converting = track.id }
        lastActivity[track.id] = Date()
        do {
            let source = try await provider.downloadSource(for: track.id, options: options)
            // Asking the server where the file is takes a round trip, and everything that calls a
            // download off — Stop, Remove, Clear — is a synchronous call that can land inside it.
            guard preparing[track.id] == attempt else { return }
            guard generation == stopGeneration, states[track.id]?.isActive == true else {
                transferEnded(track.id)
                return
            }
            // One file, whatever the codec — so every download is handed to the system and survives
            // the wrist dropping.
            let variant = MediaVariant.of(options)
            let name = DownloadStore.fileName(
                for: track.id,
                variant: variant,
                fileExtension: WatchAudioSource.fileExtension(
                    for: options, track: track, request: source.request
                )
            )
            fileNames[track.id] = name
            if states[track.id] != .queued { states[track.id] = .queued }
            durations[track.id] = track.duration
            variants[track.id] = variant
            running.insert(track.id)
            // Only a conversion holds the lane.
            var row = (try? index.download(forTrack: track.id))
                ?? record(track, name: name, variant: variant, state: .queued, reason: reason)
            row.state = .queued
            row.fileName = name
            row.variant = variant.tag
            var reasons = Set(row.reasons)
            reasons.insert(reason.key)
            row.setReasons(reasons)
            try index.saveDownload(row)
            downloader.enqueue(
                id: track.id.rawValue,
                request: source.request,
                to: store.url(named: name),
                // A watch is on Wi-Fi or it is relaying through the phone; there is no separate
                // cellular decision to make here, and refusing would only stop downloads on a
                // cellular watch that has nothing else to use.
                allowsCellular: true
            )
            // Only while transfers are live, and only then: a thirty-second
            // timer for the life of the app is battery somebody paid for.
            startWatchdog()
        } catch {
            // Called off, not refused.
            if error.isCancelledFetch {
                returnToQueue(track.id)
                transferEnded(track.id)
                return
            }
            // "The server is out of reach right now" is not "the server refused this song".
            if preparing[track.id] == attempt, generation == stopGeneration,
               applyRecovery(
                WatchDownloadRecovery.decide(
                    TransferFailureClassifier.disposition(
                        forPreparation: error, isConversion: options.transcodeTo != nil
                    ),
                    attemptsUsed: rescues[track.id, default: 0]
                ),
                for: track.id
               ) {
                transferEnded(track.id)
                return
            }
            fail(track, reason: reason, message: message(for: error, at: .preparing))
            transferEnded(track.id)
        }
    }

    private func record(
        _ track: Track, name: String, variant: MediaVariant,
        state: DownloadRecord.State, reason: DownloadReason
    ) -> DownloadRecord {
        var record = DownloadRecord(
            trackId: track.id.rawValue,
            state: state,
            fileName: name,
            variant: variant.tag,
            addedAt: Date(),
            requestedBy: [],
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            artworkId: track.artwork?.rawValue,
            duration: track.duration
        )
        var reasons = Set((try? index.download(forTrack: track.id))?.reasons ?? [])
        reasons.insert(reason.key)
        record.setReasons(reasons)
        return record
    }

    private func fail(_ track: Track, reason: DownloadReason, message: String) {
        // A song nobody is keeping any more cannot report a failure.
        guard states[track.id] != nil else { return }
        states[track.id] = .failed(message)
        // Kept in the table as well as in memory, so a relaunch can still say which songs did not
        // arrive and why — but written onto the row that is already there rather than over it, and
        // never with a name it does not have.
        var row = (try? index.download(forTrack: track.id))
            ?? record(track, name: "", variant: .original, state: .failed, reason: reason)
        row.state = .failed
        row.failure = message
        if row.fileName?.isEmpty ?? false { row.fileName = nil }
        var reasons = Set(row.reasons)
        reasons.insert(reason.key)
        row.setReasons(reasons)
        save(row)
        tally(track.id)
        endRun()
        Self.log.error("\(track.displayTitle, privacy: .public): \(message, privacy: .public)")
    }

    /// A song that did not arrive, with enough about it to be recognised.
    struct Failure: Identifiable, Sendable {
        let id: MediaID
        let title: String
        let artist: String?
        let message: String
    }

    /// How many songs did not arrive.
    var failureCount: Int {
        states.values.reduce(into: 0) { total, state in
            if case .failed = state { total += 1 }
        }
    }

    /// The first thing that went wrong, for a row with room for one line of it.
    var firstFailureMessage: String? {
        states.values
            .compactMap { state -> String? in
                if case .failed(let message) = state { return message }
                return nil
            }
            .sorted()
            .first
    }

    /// Songs that did not arrive, named and in full.
    var failures: [Failure] {
        states.compactMap { id, state -> Failure? in
            guard case .failed(let message) = state else { return nil }
            let row = try? index.download(forTrack: id)
            return Failure(
                id: id,
                title: row?.title ?? "A song",
                artist: row?.artistName,
                message: message
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Where a download gave up.
    enum Stage: String {
        case preparing = "Preparing"
        case transferring = "Transferring"
    }

    private func message(for error: any Error, at stage: Stage) -> String {
        let said = (error as? ProviderError)?.diagnosticDescription
            ?? error.localizedDescription
        return "\(stage.rawValue): \(said)"
    }

    // MARK: Transfers

    /// Applies one transfer event.
    func apply(_ event: BackgroundDownloadEvent) {
        let id = MediaID(server: storage, rawValue: event.id)
        // A song nobody is keeping any more has nothing to report.
        guard states[id] != nil else { return }
        // Cancelling is asked of the system rather than done to it, so a transfer called off can
        // still finish in the moment before the cancel lands.
        guard preparing[id] == nil,
              !waiting.contains(where: { $0.track.id == id })
        else { return }
        switch event.kind {
        case .progress(let received, let expected):
            // Activity, not mere existence.
            guard states[id]?.isActive == true else { return }
            // Written only when it changes.
            if states[id] != .running { states[id] = .running }
            lastActivity[id] = Date()
            if let total = expected ?? estimatedBytes(for: id), total > 0 {
                fractions[id] = min(1, Double(received) / Double(total))
            }
        case .started, .waiting:
            // Signs of life. The watch judges a transfer by its silence too.
            if states[id]?.isActive == true { lastActivity[id] = Date() }
        case .finished:
            defer { transferEnded(id) }
            // Named for what it is before it is opened: AVFoundation decides
            // from the extension, and a song saved as `.audio` is refused.
            if let unplayable = nameFileByContent(id) {
                states[id] = .failed(unplayable)
                if let name = fileNames[id] { store.remove(named: name) }
                if var record = try? index.download(forTrack: id) {
                    record.state = .failed
                    record.failure = unplayable
                    save(record)
                }
                tally(id)
                endRun()
                return
            }
            // A file that arrived whole but holds a fraction of the song is not the song.
            if let short = tooShort(id) {
                states[id] = .failed(short)
                if let name = fileNames[id] { store.remove(named: name) }
                if var record = try? index.download(forTrack: id) {
                    record.state = .failed
                    record.failure = short
                    save(record)
                }
                tally(id)
                endRun()
                return
            }
            states[id] = .done
            if var record = try? index.download(forTrack: id) {
                record.state = .done
                save(record)
            }
            tally(id)
            endRun()
        case .failed(let failure):
            defer { transferEnded(id) }
            // By kind, as a failed preparation is: a link that dropped, a server having a moment, a
            // full watch and a sign-in wall are not the same thing and do not end the same way.
            let decision = WatchDownloadRecovery.decide(
                TransferFailureClassifier.disposition(
                    for: failure, isConversion: variants[id]?.isOriginal == false
                ),
                attemptsUsed: rescues[id, default: 0]
            )
            if applyRecovery(decision, for: id) { return }
            let message = "\(Stage.transferring.rawValue): \(failure.message)"
            states[id] = .failed(message)
            if var record = try? index.download(forTrack: id) {
                record.state = .failed
                record.failure = message
                save(record)
            }
            tally(id)
            endRun()
        }
    }

    /// Gives a finished file the extension its bytes call for, and answers a reason when they call
    /// for none.
    private func nameFileByContent(_ id: MediaID) -> String? {
        guard let name = fileNames[id], name.hasSuffix(".audio"),
              let url = store.existingFile(named: name)
        else { return nil }
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 16)
        } ?? Data()
        guard let ext = AudioContainer.sniff(head) else {
            return "The server sent a format this watch cannot play."
        }
        let renamed = String(name.dropLast("audio".count)) + ext
        do {
            let destination = store.url(named: renamed)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            return "The song could not be saved: \(error.localizedDescription)"
        }
        fileNames[id] = renamed
        if var row = try? index.download(forTrack: id) {
            row.fileName = renamed
            save(row)
        }
        return nil
    }

    // MARK: Removing

    func remove(reason: DownloadReason, tracks: [MediaID]) {
        requested.remove(reason.key)
        if case .playlist(let id) = reason {
            try? index.deleteDownloadedPlaylist(id: id)
        }
        // One read, then one write and one delete for the whole record. A
        // thirty-song album was thirty transactions on the main actor; an
        // artist with two hundred songs was two hundred.
        var rows: [String: DownloadRecord] = [:]
        for row in (try? index.downloads(forTracks: tracks)) ?? [] { rows[row.trackId] = row }
        var rewritten: [DownloadRecord] = []
        var deleted: [MediaID] = []
        for id in tracks {
            switch remove(track: id, because: reason, row: rows[id.rawValue]) {
            case .kept(let row): rewritten.append(row)
            case .deleted: deleted.append(id)
            case .nothing: break
            }
        }
        save(rewritten)
        try? index.deleteDownloads(forTracks: deleted)
        // Cancelling is the one ending that reports nothing: the downloader drops the task and no
        // event ever comes, so nothing else here would ever give the lane back.
        if let holder = converting, states[holder] == nil {
            converting = nil
        }
        // Removing the last of what was on its way ends the run as surely as
        // finishing it does, and the tallies have to go with it or the next
        // batch opens part-full with the last one's numbers.
        endRun()
        if !waiting.isEmpty {
            Task { [weak self] in await self?.drain() }
        }
    }

    /// A song stays until the last reason for keeping it is gone — it may be
    /// on the watch as part of a record *and* as part of a playlist.
    private enum Removal {
        /// Another reason still holds it: the row with this one taken off.
        case kept(DownloadRecord)
        /// The file and the row go; the caller deletes the row.
        case deleted
        /// It was never here.
        case nothing
    }

    private func remove(track id: MediaID, because reason: DownloadReason, row: DownloadRecord?) -> Removal {
        guard var record = row else {
            // No row at all, which since songs are written down when they are asked for means a
            // song this watch never held and never queued — an album being removed always names
            // every track it has, most of which were never downloaded.
            waiting.removeAll { $0.track.id == id }
            forget(id)
            return .nothing
        }
        var reasons = Set(record.reasons)
        reasons.remove(reason.key)
        guard reasons.isEmpty else {
            record.setReasons(reasons)
            return .kept(record)
        }
        downloader.cancel(id: id.rawValue)
        // Through the same chain everything else uses, or the stop for this song could land after
        // the request that asks for it again — the session is named after the song, so it would
        // close the conversion it was never meant to touch.
        endConversion(id, variantTag: record.variant)
        if let name = record.fileName { store.remove(named: name) }
        waiting.removeAll { $0.track.id == id }
        forget(id)
        return .deleted
    }

    /// Lets go of a song entirely — the state a screen reads and every side map that hangs off it.
    private func forget(_ id: MediaID) {
        // The preparation too, so the request still out with the server
        // cannot land on a song nobody is keeping — and so asking for it
        // again is not refused by a slot that will never be given back.
        preparing[id] = nil
        states[id] = nil
        fileNames[id] = nil
        fractions[id] = nil
        durations[id] = nil
        variants[id] = nil
        running.remove(id)
        // A stale count of stalls, or the next download of this same song
        // is refused the ordinary two-attempt budget on its very first
        // stall — see `rescueTheStalled`.
        rescues[id] = nil
        // Out of the run's arithmetic as well as out of the run.
        if counted.remove(id) != nil {
            runSize -= 1
            if tallied.remove(id) != nil { runFinished -= 1 }
        }
    }

    /// Stands this object down, for one that is replacing it.
    func discard() {
        isRetired = true
        stopGeneration += 1
        waiting = []
        preparing = [:]
        converting = nil
        stopWatchdog()
        cancelRetry()
        // And nothing starts again. A drain already in flight finds the gate
        // shut rather than racing the object that has replaced this one.
        isSettled = false
    }

    /// Whether this object has been stood down for one replacing it.
    @ObservationIgnored
    private var isRetired = false

    /// Holds the queue where it is, keeping every song still owed.
    func pauseQueue() {
        // Nothing owed, nothing to hold.
        guard queueCount > 0 else { return }
        settings.isDownloadQueuePaused = true
        cancelRetry()
        stopGeneration += 1
        // Every song this watch has anything open for: the one in the lane, the ones the system is
        // carrying, and the one whose request is out with the server.
        var held = running
        if let id = converting { held.insert(id) }
        held.formUnion(preparing.keys)
        preparing = [:]
        converting = nil
        for id in held {
            downloader.cancel(id: id.rawValue)
            endConversion(id)
            returnToQueue(id)
        }
        running = []
        fractions = [:]
        // Nothing to watch while the queue is held.
        stopWatchdog()
        lastActivity = [:]
        // Once, after all of them, rather than per song.
        sortWaiting()
    }

    /// Puts a song that was in flight back where it was in the queue.
    private func returnToQueue(_ id: MediaID) {
        guard states[id]?.isActive == true else { return }
        states[id] = .queued
        fractions[id] = nil
        running.remove(id)
        guard var row = try? index.download(forTrack: id) else { return }
        row.state = .queued
        row.failure = nil
        try? index.saveDownload(row)
        guard !waiting.contains(where: { $0.track.id == id }),
              let resumed = resumable(row)
        else { return }
        waiting.append(resumed)
    }

    /// Puts the queue back into the order the table gives it.
    private func sortWaiting() {
        waiting.sort { first, second in
            (entries[first.track.id]?.order ?? .max) < (entries[second.track.id]?.order ?? .max)
        }
    }

    /// Lets the queue go again, and is also the way out of a queue that has
    /// stopped moving for reasons nobody chose.
    func startQueue() async {
        holdMessage = nil
        cancelRetry()
        settings.isDownloadQueuePaused = false
        // Pressing it by hand is a fresh start for everything in the queue,
        // including whatever the watchdog had lost patience with.
        rescues = [:]
        await restartQueue()
    }

    /// Puts everything still owed back on its way.
    func restartQueue() async {
        guard !isRetired else { return }
        // Asked for by something that changed the picture — the address moved,
        // a link came back, the wearer pressed Start Again — so whatever the
        // queue was waiting out is over.
        cancelRetry()
        let carried = Set(await downloader.running())
        guard !isRetired else { return }
        // A song being prepared holds the lane and cannot be in `carried` — `start` takes the lane
        // before the round trip and hands the transfer over after it.
        if let holder = converting,
           !carried.contains(holder.rawValue),
           preparing[holder] == nil {
            converting = nil
        }
        // A conversion the system is carrying holds the lane, and is watched.
        for id in carried.map({ MediaID(server: storage, rawValue: $0) })
        where converting == nil && variants[id]?.isOriginal == false {
            converting = id
            lastActivity[id] = Date()
            startWatchdog()
        }
        // Asking the system what it holds is the same thing `reconcile` does before it opens the
        // gate, and this has just done it — so the queue may move even when the app was woken
        // straight into this without a reconcile of its own.
        isSettled = true
        for record in (try? index.queuedDownloads()) ?? [] {
            guard record.state == .queued || record.state == .running else { continue }
            guard !carried.contains(record.trackId) else { continue }
            let id = MediaID(server: storage, rawValue: record.trackId)
            guard preparing[id] == nil,
                  converting != id,
                  !waiting.contains(where: { $0.track.id == id }),
                  let (track, reason) = resumable(record)
            else { continue }
            states[id] = .queued
            count(id)
            if entries[id] == nil, let order = record.queueOrder {
                entries[id] = Entry(
                    title: record.title ?? track.title,
                    artist: record.artistName,
                    order: order
                )
            }
            waiting.append((track: track, reason: reason))
        }
        sortWaiting()
        await drain()
    }

    /// Puts the songs that did not arrive back in the queue.
    func retryFailures() async {
        var any = false
        var rewritten: [DownloadRecord] = []
        let failed = states.compactMap { id, state -> MediaID? in
            if case .failed = state { return id }
            return nil
        }
        let rows = Dictionary(
            ((try? index.downloads(forTracks: failed)) ?? []).map { ($0.trackId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in failed {
            guard var row = rows[id.rawValue],
                  let (track, reason) = resumable(row)
            else { continue }
            nextQueueOrder += 1
            row.state = .queued
            row.failure = nil
            row.queueOrder = nextQueueOrder
            rewritten.append(row)
            states[id] = .queued
            count(id)
            // Asking again is asking again: a song that used up its rescues
            // last time starts with a full budget, or Try Again would give up
            // on it before it had begun.
            rescues[id] = nil
            entries[id] = Entry(
                title: row.title ?? track.title, artist: row.artistName, order: nextQueueOrder
            )
            if !waiting.contains(where: { $0.track.id == id }) {
                waiting.append((track: track, reason: reason))
            }
            any = true
        }
        save(rewritten)
        guard any else { return }
        sortWaiting()
        holdMessage = nil
        cancelRetry()
        settings.isDownloadQueuePaused = false
        await drain()
    }

    /// Takes one song out of the queue, leaving the rest of it alone.
    func drop(_ id: MediaID) {
        waiting.removeAll { $0.track.id == id }
        if converting == id || running.contains(id) {
            downloader.cancel(id: id.rawValue)
            endConversion(id)
            if converting == id { converting = nil }
        }
        if let name = fileNames[id] { store.remove(named: name) }
        try? index.deleteDownload(forTrack: id)
        forget(id)
        // The record this song belonged to may no longer be wholly kept, and
        // `requested` is what the hold sheet reads to decide whether it is
        // offering to keep something or to let it go.
        requested = Set(
            ((try? index.downloads()) ?? [])
                .filter { $0.state != .failed }
                .flatMap(\.reasons)
        )
        endRun()
        if !waiting.isEmpty {
            Task { [weak self] in await self?.drain() }
        }
    }

    /// What is still owed, in the order it will arrive, for the queue screen.
    var queue: [QueuedSong] {
        states.compactMap { id, state -> QueuedSong? in
            guard state.isActive, let entry = entries[id] else { return nil }
            return QueuedSong(
                id: id, title: entry.title, artist: entry.artist,
                order: entry.order, isLeading: converting == id || leadingWhenNoLane == id
            )
        }
        .sorted { $0.order < $1.order }
    }

    /// The song to report on when no lane is held.
    private var leadingWhenNoLane: MediaID? {
        guard converting == nil else { return nil }
        return running.filter { states[$0]?.isActive == true }
            .min { (entries[$0]?.order ?? .max) < (entries[$1]?.order ?? .max) }
    }

    /// A song waiting its turn, with enough about it to be drawn.
    struct QueuedSong: Identifiable, Sendable {
        let id: MediaID
        let title: String
        let artist: String?
        let order: Int
        /// The one being fetched right now, which is the only row with
        /// anything to say beyond its own name.
        let isLeading: Bool
    }

    /// How far this one song has got, where that is known.
    func fraction(for id: MediaID) -> Double? { fractions[id] }

    /// Changes as the queue does, for a screen that reads it into state rather than from its body.
    var queueTally: String { "\(runFinished) of \(runSize)" }

    var queueKey: String {
        let leading = (converting ?? leadingWhenNoLane)?.rawValue ?? ""
        return "\(runSize)-\(runFinished)-\(running.count)-\(leading)-\(isPaused)-\(isStalled)"
    }

    /// Calls off what is still on its way, and keeps what has arrived.
    func clearQueue() {
        stopGeneration += 1
        holdMessage = nil
        cancelRetry()
        settings.isDownloadQueuePaused = false
        // Every conversion this watch opened and is about to abandon. Before
        // the files and the rows, because `forget` takes with it the variant
        // that says which songs had a session at all.
        for (id, state) in states where state.isActive { endConversion(id) }
        downloader.cancelAll()
        waiting = []
        converting = nil
        // The song whose request is still out with the server will bail on the generation when it
        // comes back, but until then it holds the gate that `drain` reads — so stopping and
        // immediately asking for something else did nothing at all until the…
        preparing = [:]
        for (id, state) in states where state.isActive {
            if let name = fileNames[id] { store.remove(named: name) }
            try? index.deleteDownload(forTrack: id)
            forget(id)
        }
        // What is still asked for is whatever still has a row behind it.
        requested = Set(
            ((try? index.downloads()) ?? [])
                .filter { $0.state != .failed }
                .flatMap(\.reasons)
        )
        for record in (try? index.downloadedPlaylists()) ?? [] {
            let id = MediaID(server: storage, rawValue: record.id)
            guard !isRequested(.playlist(id)) else { continue }
            try? index.deleteDownloadedPlaylist(id: id)
        }
        endRun()
    }

    /// How long each song should be, so what arrives can be checked against
    /// it — see `tooShort`, and `estimatedBytes`.
    @ObservationIgnored
    private var durations: [MediaID: TimeInterval] = [:]

    /// What each song was asked for as, which is where the bit rate behind
    /// `estimatedBytes` comes from.
    @ObservationIgnored
    private var variants: [MediaID: MediaVariant] = [:]

    /// What a conversion of this song should come to, when the server will not say.
    private func estimatedBytes(for id: MediaID) -> Int64? {
        guard case .converted(_, let kbps)? = variants[id] else { return nil }
        return estimatedConversionBytes(kbps: kbps, duration: durations[id])
    }

    /// Says so when the file that landed holds far less music than the song has, and nothing when
    /// it cannot tell.
    private func tooShort(_ id: MediaID) -> String? {
        guard let expected = durations[id], expected > 0,
              let name = fileNames[id],
              let url = store.existingFile(named: name),
              let opened = try? AVAudioFile(forReading: url)
        else { return nil }
        let rate = opened.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        let arrived = Double(opened.length) / rate
        guard arrived > 0, arrived < expected / 2 else { return nil }
        return "The server sent \(Int(arrived.rounded())) seconds of a "
            + "\(Int(expected.rounded()))-second song."
    }

    /// Everything, after one confirmation. Nothing on the server is touched.
    func removeEverything() {
        stopGeneration += 1
        preparing = [:]
        stopWatchdog()
        holdMessage = nil
        cancelRetry()
        // Nothing left to hold.
        settings.isDownloadQueuePaused = false
        // Every conversion this watch opened, closed before the variants that
        // say which ones they were are thrown away with everything else.
        for (id, state) in states where state.isActive { endConversion(id) }
        // Before the files, not after: a transfer the system is still carrying recreates the
        // directory and moves its song into it when it lands, so a wipe that only deleted files
        // left songs reappearing in a store the wearer had just emptied — with…
        downloader.cancelAll()
        waiting = []
        converting = nil
        store.removeAll()
        for record in (try? index.downloads()) ?? [] {
            try? index.deleteDownload(forTrack: MediaID(server: storage, rawValue: record.trackId))
        }
        for record in (try? index.downloadedPlaylists()) ?? [] {
            try? index.deleteDownloadedPlaylist(id: MediaID(server: storage, rawValue: record.id))
        }
        states = [:]
        fileNames = [:]
        fractions = [:]
        durations = [:]
        variants = [:]
        requested = []
        runSize = 0
        runFinished = 0
        counted = []
        tallied = []
        running = []
        runningTitle = nil
        // Same reason as `forget`: a stalled song's count of its own stalls
        // has to go with everything else it stood for, or a wipe leaves the
        // next attempt at the same song starting with no retries left.
        rescues = [:]
        // `endConversion` above filed one of these for everything just
        // stopped. Nothing will ever collect them if a wipe does not — see
        // `stopping`'s own doc comment.
        stopping = [:]
        stoppingTokens = [:]
    }
}

extension MediaVariant {
    /// The one mapping from what was asked for to what the file is called.
    static func of(_ options: StreamOptions) -> MediaVariant {
        guard let codec = options.transcodeTo else { return .original }
        return .converted(codec: codec.rawValue, kbps: options.maxBitRateKbps)
    }
}
