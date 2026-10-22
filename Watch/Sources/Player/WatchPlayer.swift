import Foundation
import Observation
import AVFoundation
import MediaPlayer
import os
import PleviAudio
import PleviDomain
import PleviTransport

/// The watch's player.
@MainActor
@Observable
final class WatchPlayer {
    private(set) var queue: [QueueItem] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    /// Fetching a song that cannot be streamed — see `WatchAudioSource`.
    private(set) var isPreparing = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var problem: String? {
        didSet { if let problem { lastProblem = problem } }
    }
    /// The same, kept after `problem` has been cleared by the next song starting.
    private(set) var lastProblem: String?

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex].track
    }

    /// The library the queue belongs to: the server its songs came from, or
    /// nil when nothing is queued.
    var queueServer: ServerID? {
        (currentTrack ?? queue.first?.track)?.id.server
    }

    var hasNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < queue.count
    }

    var upNext: [QueueItem] {
        guard let currentIndex else { return [] }
        return Array(queue.dropFirst(currentIndex + 1))
    }

    /// Told when something is deliberately put on, for Recently Played.
    var onSourcePlayed: ((PlayedSource, Date) -> Void)?
    /// Told when a stream could not start or went quiet in a way an
    /// unreachable address explains, so the model can choose the address
    /// again. Phone-relayed paths do not always report a path change.
    var onServerTrouble: (() -> Void)?
    /// Where plays go that could not be sent. Set by the model.
    var pendingPlays: WatchPendingPlays?

    private let player = AVQueuePlayer()
    private var timeObserver: Any?
    /// Watches the item the player was handed, because an item that cannot be
    /// opened says so here and nowhere else — see `watchLoading(of:)`.
    private var loadObservation: NSKeyValueObservation?
    private var stallWatchdog: Task<Void, Never>?
    /// Checks that the queue player's own handover actually played — see
    /// `confirmJoin(generation:)`.
    private var joinWatchdog: Task<Void, Never>?
    private var endObserver: (any NSObjectProtocol)?
    private var failureObserver: (any NSObjectProtocol)?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var routeObserver: (any NSObjectProtocol)?
    /// The song being fetched for the deck, and the work doing it.
    private var lookahead: (id: QueueItem.ID, task: Task<Void, Never>)?
    /// One fetch per song, whoever asked — see `fetched(_:for:options:)`.
    private struct Fetch {
        let token: UUID
        let task: Task<URL, any Error>
    }
    private var fetching: [MediaID: Fetch] = [:]
    /// Songs whose warm-ahead fetch just failed, left alone for a while.
    private var warmCooldown = WarmCooldown()
    /// The run of songs being got ready behind the one playing.
    private var warming: Task<Void, Never>?
    /// How many songs ahead are fetched before they are wanted.
    private static let warmAhead = 3
    /// Whether the listener wants audio, as opposed to whether it happens to be running.
    private var wantsPlayback = false
    /// Whether it was this app that an interruption stopped.
    private var pausedByInterruption = false
    /// Consecutive songs that would not load, so a queue of broken files
    /// stops rather than spinning through itself.
    private var failures = 0
    private static let failuresBeforeGivingUp = 3

    /// Which queue entry is sitting in the deck behind the current song.
    private var deckedNext: QueueItem.ID?
    /// Bumped on every load, so a fetch that finishes after the listener has
    /// moved on is discarded rather than starting the wrong song.
    private var generation = 0
    private var preparation: Task<Void, Never>?
    private var scrobbled = false
    private var playbackSchedule = PlaybackReportSchedule()

    private static let log = Logger(subsystem: AppIdentity.phone, category: "watchPlayer")

    /// Set by the model whenever the server it can reach changes.
    var source: WatchAudioSource? {
        didSet {
            // A song that could not start for want of a server starts now,
            // rather than waiting for somebody to notice and press play.
            if source != nil, waitingForServer {
                waitingForServer = false
                failures = 0
                startCurrent(autoplay: wantsPlayback)
            }
        }
    }
    /// Why there is no `source`, when the answer is "there never will be":
    /// the sign-in is missing. Nil while a connection is simply on its way.
    var sourceUnavailableReason: String?
    /// The current song is not on this watch and there is no server yet.
    private var waitingForServer = false
    var settings: WatchSettings?
    /// Where a song fetched whole is kept — see phase-three downloads for the
    /// deliberate version of the same idea.
    var downloadedFile: ((MediaID) -> URL?)?

    init() {
        player.actionAtItemEnd = .advance
        Self.clearFetched()
        observeTime()
        observeEnd()
        observeFailure()
        observeSession()
        Self.setUpRemoteCommands(for: self)
        updateRemoteCommands()
    }

    // MARK: Starting things

    func play(_ tracks: [Track], startingAt index: Int = 0, from origin: QueueOrigin = .songs) {
        guard !tracks.isEmpty else { return }
        // A deliberate start forgives whatever would not load last time.
        failures = 0
        queue = tracks.map(QueueItem.init)
        currentIndex = min(max(index, 0), tracks.count - 1)
        if let source = origin.playedSource {
            onSourcePlayed?(source, Date())
        }
        startCurrent(autoplay: true)
    }

    func shuffle(_ tracks: [Track], from origin: QueueOrigin = .songs) {
        guard !tracks.isEmpty else { return }
        play(tracks.shuffled(), startingAt: 0, from: origin)
    }

    /// Straight after the song playing now.
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let items = tracks.map(QueueItem.init)
        guard let currentIndex else {
            play(tracks)
            return
        }
        queue.insert(contentsOf: items, at: currentIndex + 1)
        updateRemoteCommands()
        refillLookahead()
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard currentIndex != nil else {
            play(tracks)
            return
        }
        queue.append(contentsOf: tracks.map(QueueItem.init))
        updateRemoteCommands()
        refillLookahead()
    }

    // MARK: Transport

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            wantsPlayback = false
            reportPlayback()
        } else if player.currentItem == nil || player.currentItem?.status == .failed {
            // Press play on a song that would not load and it loads again, rather than calling
            // `play()` on a dead item and drawing a pause button over the same silence.
            failures = 0
            startCurrent(autoplay: true)
        } else {
            wantsPlayback = true
            Task { [weak self] in
                guard let self, await activateSession(), wantsPlayback else {
                    self?.isPlaying = false
                    self?.updateNowPlaying()
                    return
                }
                player.play()
                isPlaying = true
                updateNowPlaying()
            }
        }
        updateNowPlaying()
    }

    func next() {
        guard let currentIndex, currentIndex + 1 < queue.count else {
            stop()
            return
        }
        self.currentIndex = currentIndex + 1
        startCurrent(autoplay: true)
    }

    /// Back to the start of this song, or to the previous one when barely in.
    func previous() {
        guard let currentIndex else { return }
        if elapsed > 3 || currentIndex == 0 {
            seek(to: 0)
            return
        }
        self.currentIndex = currentIndex - 1
        startCurrent(autoplay: true)
    }

    /// Jumps straight to a queued song, leaving everything before it in the
    /// queue as history rather than throwing it away.
    func jump(to item: QueueItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        failures = 0
        currentIndex = index
        startCurrent(autoplay: true)
    }

    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = max(0, seconds)
        updateNowPlaying()
    }

    func stop() {
        preparation?.cancel()
        stallWatchdog?.cancel()
        loadObservation?.invalidate()
        loadObservation = nil
        generation += 1
        waitingForServer = false
        reportPlayback(state: .stopped)
        playbackSchedule.reset()
        player.removeAllItems()
        lookahead?.task.cancel()
        lookahead = nil
        deckedNext = nil
        wantsPlayback = false
        queue = []
        currentIndex = nil
        isPlaying = false
        isPreparing = false
        elapsed = 0
        duration = nil
        updateRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Loading

    private func startCurrent(autoplay: Bool) {
        guard let track = currentTrack else { return }
        preparation?.cancel()
        lookahead?.task.cancel()
        lookahead = nil
        waitingForServer = false
        wantsPlayback = autoplay
        generation += 1
        let mine = generation
        scrobbled = false
        problem = nil
        elapsed = 0
        duration = track.duration
        player.removeAllItems()
        deckedNext = nil
        // Fetches for songs the listener has just skipped past keep running
        // unless they are called off here: cancelling the preparation above
        // does not reach them.
        reapStrayFetches()

        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await item(for: track, announcing: true)
                guard mine == generation else { return }
                player.insert(item, after: nil)
                watchLoading(of: item, generation: mine)
                isPreparing = false
                // Not reset here.
                if wantsPlayback, await activateSession(), wantsPlayback {
                    player.play()
                    isPlaying = true
                } else {
                    isPlaying = false
                }
                updateNowPlaying()
                reportNowPlaying(track)
                // Only once the current song is actually running: on a watch
                // two fetches at once is two radios' worth of battery for a
                // song that may be skipped.
                refillLookahead()
            } catch {
                guard mine == generation else { return }
                isPreparing = false
                // Not a fault in the song: the server is still being reached, or never will be.
                if case WatchPlaybackError.connecting = error {
                    waitingForServer = sourceUnavailableReason == nil
                    isPlaying = false
                    problem = sourceUnavailableReason ?? "Connecting to your server…"
                    updateNowPlaying()
                    return
                }
                let message = (error as? ProviderError)?.errorDescription
                    ?? error.localizedDescription
                Self.log.error("could not start \(track.displayTitle, privacy: .public): \(message)")
                // A song that will not load is a song that has to be moved past.
                failures += 1
                onServerTrouble?()
                guard failures < Self.failuresBeforeGivingUp, hasNext,
                      let index = currentIndex
                else {
                    isPlaying = false
                    problem = message
                    updateNowPlaying()
                    return
                }
                currentIndex = index + 1
                startCurrent(autoplay: wantsPlayback)
                // After, because the load just started clears it — and this
                // is the only account of why the song was skipped.
                problem = message
            }
        }
    }

    /// Builds the thing `AVQueuePlayer` plays, by whichever of the three routes this server needs.
    private func item(for track: Track, announcing: Bool) async throws -> AVPlayerItem {
        if let file = downloadedFile?(track.id) {
            return AVPlayerItem(url: file)
        }
        // Already here, because it was got ready behind the last song.
        if let ready = Self.cachedFile(for: track.id) {
            return AVPlayerItem(url: ready)
        }
        guard let source else { throw WatchPlaybackError.connecting }
        let options = streamOptions(for: track)
        switch try await source.prepare(track, options: options) {
        case .streaming(let item):
            return item
        case .needsFetch(let stream):
            if announcing { isPreparing = true }
            return AVPlayerItem(url: try await fetched(stream, for: track, options: options))
        }
    }

    /// The file for a fetched song, fetched once however many ask for it.
    private func fetched(
        _ stream: StreamSource, for track: Track, options: StreamOptions
    ) async throws -> URL {
        guard let source else { throw WatchPlaybackError.noURL }
        let destination = Self.fetchedFile(
            for: track.id,
            extension: WatchAudioSource.fileExtension(
                for: options, track: track, request: stream.request
            )
        )
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let running = fetching[track.id] { return try await running.task.value }

        let token = UUID()
        let task = Task<URL, any Error> { [weak self] in
            // Cleared by the work itself rather than by whoever was waiting on it.
            defer {
                if self?.fetching[track.id]?.token == token { self?.fetching[track.id] = nil }
            }
            // Assembled beside the real name and moved into place only once it is whole.
            let scratch = destination.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: scratch)
            do {
                _ = try await source.fetch(stream, for: track, to: scratch)
            } catch {
                try? FileManager.default.removeItem(at: scratch)
                throw error
            }
            // Named from its bytes when nothing else could name it: AVFoundation
            // reads the container from the extension, and `.audio` is refused.
            var final = destination
            if destination.pathExtension == "audio",
               let sniffed = WatchAudioSource.sniffedExtension(of: scratch) {
                final = destination.deletingPathExtension().appendingPathExtension(sniffed)
            }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: scratch, to: final)
            return final
        }
        fetching[track.id] = Fetch(token: token, task: task)
        return try await task.value
    }

    /// Calls off every whole-song fetch that is not the song now current or one of the few just
    /// ahead.
    private func reapStrayFetches() {
        let ahead = upcoming(Self.warmAhead).map(\.id)
        let stale = FetchReaping.stale(
            running: fetching.keys.map(\.rawValue),
            current: currentTrack?.id.rawValue,
            ahead: ahead.map(\.rawValue)
        )
        for raw in stale {
            guard let key = fetching.keys.first(where: { $0.rawValue == raw }) else { continue }
            fetching[key]?.task.cancel()
            fetching[key] = nil
        }
    }

    /// The next few songs in the queue, nearest first.
    private func upcoming(_ count: Int) -> [Track] {
        guard let currentIndex else { return [] }
        return (1...count).compactMap { offset -> Track? in
            let index = currentIndex + offset
            return queue.indices.contains(index) ? queue[index].track : nil
        }
    }

    /// Gets the next few songs ready before anybody asks for them.
    private func warm() {
        warming?.cancel()
        guard currentIndex != nil, source != nil else { return }
        let ahead = upcoming(Self.warmAhead)
        reapStrayFetches()
        var keep = Set(ahead.map(\.id))
        if let current = currentTrack?.id { keep.insert(current) }
        Self.evictFetched(keeping: keep)

        guard !ahead.isEmpty else { return }
        let mine = generation
        warmCooldown.prune(at: Date())
        warming = Task { [weak self] in
            for track in ahead {
                guard !Task.isCancelled, let self, mine == generation else { return }
                // A song that just failed is not asked for again at every
                // refill: that was sustained traffic for a song that may
                // never be reached, competing with the one playing.
                guard !warmCooldown.isCoolingDown(track.id.rawValue, at: Date()) else { continue }
                // Failures here are nobody's business: this song may never be
                // reached, and if it is, it will say so then.
                do {
                    try await warmed(track)
                    warmCooldown.recordSuccess(of: track.id.rawValue)
                } catch {
                    if !error.isCancelledFetch {
                        warmCooldown.recordFailure(of: track.id.rawValue, at: Date())
                    }
                }
            }
        }
    }

    /// One song got ready, put on the disk whether or not playing it now would have streamed it.
    private func warmed(_ track: Track) async throws {
        guard downloadedFile?(track.id) == nil, let source else { return }
        let options = streamOptions(for: track)
        guard worthWarming(track, options: options) else { return }
        let stream = try await source.source(for: track, options: options)
        _ = try await fetched(stream, for: track, options: options)
    }

    /// Whether a song is small enough to be worth having in advance.
    private func worthWarming(_ track: Track, options: StreamOptions) -> Bool {
        if options.transcodeTo != nil { return true }
        guard let kbps = track.bitRateKbps, let seconds = track.duration else { return false }
        return Double(kbps) * seconds / 8 * 1000 <= Self.warmSizeLimit
    }

    /// Twenty-five megabytes: a generous lossy original, well short of a
    /// lossless one.
    private static let warmSizeLimit: Double = 25_000_000

    /// The two settings, expressed as the policy type the phone already has,
    /// so the rule about which songs are converted is one rule rather than
    /// two that drift.
    private func streamOptions(for track: Track) -> StreamOptions {
        guard let settings else { return .original }
        let choice = settings.streaming
        let policy = TranscodePolicy.watch(
            transcoding: choice.converts,
            kbps: choice.kbps,
            codec: choice.format.rawValue
        )
        guard let target = policy.target(
            forCodec: track.codec ?? track.contentType, bitRateKbps: track.bitRateKbps
        ) else { return .original }
        return StreamOptions(
            maxBitRateKbps: policy.targetBitRateKbps,
            transcodeTo: TranscodeCodec(rawValue: target) ?? .mp3
        )
    }

    /// Hands the queue player the following song so the join does not wait on this app being awake.
    private func refillLookahead() {
        guard let currentIndex else { return }
        // Before the deck's own early exits below, so the songs further ahead
        // are kept in step with the queue even on the many passes where the
        // deck itself already holds the right one.
        warm()
        let wanted = currentIndex + 1 < queue.count ? queue[currentIndex + 1] : nil

        if let wanted {
            // Already in the deck, or already on its way. The second test is
            // what stops two fetches of one song racing into the same file.
            if deckedNext == wanted.id { return }
            if lookahead?.id == wanted.id { return }
        }

        // Take back whatever was being held or fetched: the queue has changed under it.
        lookahead?.task.cancel()
        lookahead = nil
        for item in player.items() where item !== player.currentItem {
            player.remove(item)
        }
        deckedNext = nil

        guard let wanted, player.currentItem != nil else { return }
        let mine = generation
        let task = Task { [weak self] in
            guard let self else { return }
            let built = try? await item(for: wanted.track, announcing: false)
            if lookahead?.id == wanted.id { lookahead = nil }
            guard let built, !Task.isCancelled else { return }
            // The queue can have moved again while this was being fetched,
            // and the player can have drained.
            guard mine == generation, isNextInQueue(wanted.id),
                  deckedNext == nil, player.currentItem != nil
            else { return }
            player.insert(built, after: player.items().last)
            deckedNext = wanted.id
        }
        lookahead = (wanted.id, task)
    }

    private func isNextInQueue(_ id: QueueItem.ID) -> Bool {
        guard let currentIndex, currentIndex + 1 < queue.count else { return false }
        return queue[currentIndex + 1].id == id
    }

    /// Where a song that had to be fetched whole is kept.
    private static let fetchedDirectory = FileManager.default.temporaryDirectory
        .appending(path: "fetched-songs", directoryHint: .isDirectory)

    /// Named for what it actually holds — see `WatchAudioSource.fileExtension(for:track:request:)`,
    /// which is the difference between a song that plays and one AVFoundation will not open.
    private static func fetchedFile(for id: MediaID, extension ext: String) -> URL {
        fetchedDirectory.appending(path: "\(safeName(for: id)).\(ext)")
    }

    private static func safeName(for id: MediaID) -> String {
        id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "song"
    }

    /// A song already on the disk, whatever it turned out to be called.
    static func cachedFile(for id: MediaID) -> URL? {
        let name = safeName(for: id)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fetchedDirectory, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first {
            FetchedFileName.isFinishedFile($0.lastPathComponent, forSafeName: name)
        }
    }

    /// How many of the songs just ahead are already here, for the line in
    /// Settings that says whether any of this is working.
    var readyAhead: (ready: Int, of: Int) {
        guard currentIndex != nil else { return (0, 0) }
        let ahead = upcoming(Self.warmAhead)
        let ready = ahead.filter {
            downloadedFile?($0.id) != nil || Self.cachedFile(for: $0.id) != nil
        }
        return (ready.count, ahead.count)
    }

    /// Throws away songs that are no longer the one playing or one of the few just ahead.
    private static func evictFetched(keeping ids: Set<MediaID>) {
        let names = Set(ids.map(safeName(for:)))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fetchedDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            let name = file.lastPathComponent
            // By song, so a `.partial` still being written is judged by the
            // song it belongs to rather than by its temporary name — and a
            // song whose name merely begins the same way is not that song.
            guard !FetchedFileName.belongs(name, toAnyOf: names) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func clearFetched() {
        try? FileManager.default.removeItem(at: fetchedDirectory)
        try? FileManager.default.createDirectory(
            at: fetchedDirectory, withIntermediateDirectories: true
        )
    }

    // MARK: Session and system integration

    /// Takes the audio route, and says whether it got one.
    private func activateSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.longFormAudio` is what tells watchOS this is music rather than a notification
            // sound: it is the policy that makes the system offer its own headphone picker, and
            // that keeps the app alive with the wrist down.
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            Self.log.error("audio session: \(error.localizedDescription, privacy: .public)")
            problem = "This watch would not start audio: \(error.localizedDescription)"
            return false
        }
        let outcome: (ok: Bool, message: String?) = await withCheckedContinuation { continuation in
            session.activate(options: []) { activated, error in
                continuation.resume(returning: (activated, error?.localizedDescription))
            }
        }
        guard outcome.ok else {
            Self.log.error("audio route: \(outcome.message ?? "declined", privacy: .public)")
            problem = "Connect headphones to play on this watch."
            return false
        }
        problem = nil
        return true
    }

    /// Says when the player cannot open what it was given.
    private func watchLoading(of item: AVPlayerItem, generation mine: Int) {
        loadObservation?.invalidate()
        loadObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error as NSError?
            let message = error.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" }
                ?? "This song would not play."
            let failed = ObjectIdentifier(item as AnyObject)
            Task { @MainActor [weak self] in
                guard let self, mine == generation else { return }
                itemFailed(failed, message: message)
            }
        }
        watchForAStall(generation: mine)
    }

    /// Says when nothing failed and nothing happened either.
    private func watchForAStall(generation mine: Int) {
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, mine == generation else { return }
            guard wantsPlayback, elapsed == 0, player.timeControlStatus != .playing else { return }
            let reason = player.reasonForWaitingToPlay
            Self.log.error("stalled: \(reason?.rawValue ?? "no reason given", privacy: .public)")
            onServerTrouble?()
            problem = reason == .noItemToPlay
                ? "There is nothing loaded to play."
                : "Still waiting for your server."
        }
    }

    /// Makes sure a join actually made a sound.
    private func confirmJoin(generation mine: Int) {
        joinWatchdog?.cancel()
        joinWatchdog = Task { [weak self] in
            let joined = Date()
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                guard let self, mine == generation else { return }
                switch WatchJoinCheck.verdict(joinObservation(since: joined)) {
                case .fine:
                    return
                case .restart:
                    Self.log.error("the join made no sound; starting the song properly")
                    startCurrent(autoplay: true)
                    return
                case .keepWatching:
                    // Still buffering.
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    /// What the player is doing, in the terms `WatchJoinCheck` decides on.
    private func joinObservation(since joined: Date) -> WatchJoinCheck.Observation {
        let control: WatchJoinCheck.Control = switch player.timeControlStatus {
        case .playing: .playing
        case .paused: .paused
        case .waitingToPlayAtSpecifiedRate: .waiting
        @unknown default: .waiting
        }
        let reason: WatchJoinCheck.WaitingReason = switch player.reasonForWaitingToPlay {
        case nil: .none
        case .some(.toMinimizeStalls): .toMinimizeStalls
        case .some(.evaluatingBufferingRate): .evaluatingBufferingRate
        case .some(.noItemToPlay): .noItemToPlay
        default: .other
        }
        return WatchJoinCheck.Observation(
            wantsPlayback: wantsPlayback,
            hasCurrentItem: player.currentItem != nil,
            itemFailed: player.currentItem?.status == .failed,
            control: control,
            waitingReason: reason,
            elapsed: elapsed,
            secondsSinceJoin: Date().timeIntervalSince(joined)
        )
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    private func tick(_ time: CMTime) {
        elapsed = time.seconds.isFinite ? time.seconds : 0
        // Heard: this song plays, so the run of failures before it is over.
        if elapsed > 0, failures > 0 { failures = 0 }
        if let item = player.currentItem {
            let length = item.duration.seconds
            if length.isFinite, length > 0 { duration = length }
        }
        reportPlayback()
        submitScrobbleIfDue()
    }

    /// A song ending is the queue player's business, not ours — but which
    /// song is now current *is* ours, so the index follows the deck.
    private func observeEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemEnded() }
        }
    }

    private func itemEnded() {
        guard let index = currentIndex else { return }

        // What the deck actually promoted is what the listener is now hearing, and it is the only
        // thing worth following.
        if let promoted = deckedNext,
           let index = queue.firstIndex(where: { $0.id == promoted }) {
            deckedNext = nil
            currentIndex = index
            scrobbled = false
            failures = 0
            problem = nil
            elapsed = 0
            duration = queue[index].track.duration
            // The queue player promotes the next item on its own, but it does not reliably carry
            // the rate over with it: the song changed on screen and nothing came out of the
            // headphones.
            if wantsPlayback {
                player.play()
                isPlaying = true
            }
            // A promoted song was watched by nothing.
            if let item = player.currentItem {
                watchLoading(of: item, generation: generation)
            }
            if let track = currentTrack {
                updateNowPlaying()
                reportNowPlaying(track)
            }
            confirmJoin(generation: generation)
            refillLookahead()
            return
        }

        // Nothing was decked, so nothing is playing: either this was the last song, or the song
        // behind it never arrived — a fetch that failed quietly.
        guard index + 1 < queue.count else {
            stop()
            return
        }
        currentIndex = index + 1
        startCurrent(autoplay: isPlaying)
    }

    /// A song the player could not play at all.
    private func observeFailure() {
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Read off the notification here, on the queue it was posted to.
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? (any Error)
            let message = error?.localizedDescription ?? "This song would not play."
            let failed = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.itemFailed(failed, message: message) }
        }
    }

    private func itemFailed(_ failed: ObjectIdentifier?, message: String) {
        Self.log.error("item failed: \(message, privacy: .public)")
        let current = player.currentItem.map { ObjectIdentifier($0 as AnyObject) }

        // The song being got ready behind this one, not the one playing. Let
        // it go and leave the current song alone — the deck can try again at
        // the join.
        guard failed == nil || failed == current else {
            for item in player.items().dropFirst() { player.remove(item) }
            deckedNext = nil
            return
        }

        // A failure is not an ending: the queue player does not advance off a broken item the way
        // it advances off a finished one, so the next song has to be started rather than assumed to
        // be under way.
        failures += 1
        guard failures < Self.failuresBeforeGivingUp,
              let index = currentIndex, index + 1 < queue.count
        else {
            isPlaying = false
            problem = message
            return
        }
        currentIndex = index + 1
        startCurrent(autoplay: wantsPlayback)
        // After the start, which clears it — otherwise the one report this
        // observer exists to make is wiped in the same turn it is written.
        problem = message
    }

    /// A call arriving, and headphones going away.
    private func observeSession() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated { self?.interrupted(type, options: options) }
        }
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.routeChanged(reason) }
        }
    }

    private func interrupted(
        _ type: AVAudioSession.InterruptionType?,
        options: AVAudioSession.InterruptionOptions
    ) {
        switch type {
        case .some(.began):
            // Remembered, because `.shouldResume` says the system permits
            // resuming, not that this app was the one playing.
            pausedByInterruption = isPlaying
            isPlaying = false
            updateNowPlaying()
        case .some(.ended):
            // Only when the system says the interruption was the kind that
            // hands playback back. A call the wearer took and ended does;
            // starting another app's audio does not.
            let wasOurs = pausedByInterruption
            pausedByInterruption = false
            guard options.contains(.shouldResume), wasOurs, currentTrack != nil else { return }
            Task { [weak self] in
                guard let self, await activateSession() else { return }
                player.play()
                isPlaying = true
                updateNowPlaying()
            }
        default:
            break
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard reason == .oldDeviceUnavailable else { return }
        // Headphones gone. The audio has already stopped; this is only about
        // agreeing with it.
        player.pause()
        isPlaying = false
        wantsPlayback = false
        updateNowPlaying()
    }

    /// Wires the transport buttons the system shows outside the app.
    private nonisolated static func setUpRemoteCommands(for player: WatchPlayer) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak player] _ in
            Task { @MainActor in
                guard let player, !player.isPlaying else { return }
                player.togglePlayPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            Task { @MainActor in
                guard let player, player.isPlaying else { return }
                player.togglePlayPause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in
            // Only when there is a song to go to.
            Task { @MainActor in
                guard let player, player.hasNext else { return }
                player.next()
            }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            // Read off the event before the hop: it belongs to the caller
            // and is not ours to carry across one.
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in player?.seek(to: position) }
            return .success
        }
    }

    /// What the system's transport may offer: Next only where there is a next
    /// song.
    private func updateRemoteCommands() {
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
    }

    private func updateNowPlaying() {
        updateRemoteCommands()
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = track.artistName { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.albumName { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    // MARK: Telling the server

    private func reportNowPlaying(_ track: Track) {
        guard let provider = source?.provider else { return }
        Task { try? await provider.scrobble(id: track.id, at: Date(), submission: false) }
        reportPlayback()
    }

    /// What is playing and where it has got to, for a server that keeps its own account of it —
    /// Plex's dashboard, where this watch did not appear at all.
    private func reportPlayback(state: PlaybackReport.State? = nil) {
        guard let track = currentTrack, let provider = source?.provider else { return }
        let report = PlaybackReport(
            id: track.id,
            state: state ?? (isPlaying ? .playing : .paused),
            position: elapsed,
            duration: duration
        )
        guard playbackSchedule.shouldSend(report, now: Date()) else { return }
        Task { try? await provider.report(report) }
    }

    /// Halfway, or four minutes in, whichever comes first — the same rule the phone follows, so a
    /// song played on either device counts once and counts the same.
    private func submitScrobbleIfDue() {
        guard !scrobbled, let track = currentTrack else { return }
        let halfway = duration.map { elapsed >= $0 / 2 } ?? false
        guard halfway || elapsed >= 240 else { return }
        scrobbled = true
        let playedAt = Date()
        guard let provider = source?.provider else {
            pendingPlays?.enqueue(track.id, at: playedAt)
            return
        }
        Task { [weak self] in
            do {
                try await provider.scrobble(id: track.id, at: playedAt, submission: true)
            } catch {
                // Kept when the server or the link was the problem; dropped
                // when the server answered and said no, since asking again at
                // the front of a queue is the same answer for ever.
                if PendingPlays.outcome(afterFailure: error) == .keepAndStop {
                    self?.pendingPlays?.enqueue(track.id, at: playedAt)
                    self?.onServerTrouble?()
                }
            }
        }
    }
}
