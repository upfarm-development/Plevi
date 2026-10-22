import Foundation
import AVFoundation
import MediaPlayer
import Observation
import PleviAudio
import PleviDomain
import PleviLibraryIndex
import PleviTransport
import PleviAudio

/// Queue, transport controls, scrobbling, and system integration (lock
/// screen, Control Center). Depends only on `MusicServerProvider` and
/// `AudioEngine`.
@MainActor
@Observable
final class PlayerModel {
    private(set) var queue: [QueueItem] = [] {
        didSet { syncStoreInUse() }
    }
    private(set) var currentIndex: Int? {
        didSet { syncStoreInUse() }
    }
    /// whatever starts this locally while this device is controlling
    /// another ends control — the lock screen, Control Center, AirPods and CarPlay all drive this
    /// `PlayerModel` directly through…
    private(set) var isPlaying = false {
        didSet {
            guard isPlaying, !oldValue else { return }
            onLocalPlaybackStarted?()
        }
    }
    private(set) var currentTime: TimeInterval = 0
    private(set) var lastError: String? {
        didSet {
            // A failure without a more specific kind named first is a plain
            // playback failure; clearing the text clears the kind (R-11).
            if lastError == nil {
                lastFailureKind = nil
            } else if lastFailureKind == nil {
                lastFailureKind = .failed
            }
        }
    }
    /// Why playback last failed, as something that can cross the wire (`lastError` is free text,
    /// and server details do not leave the device — §4.5.5).
    private(set) var lastFailureKind: PlaybackFailureKind?
    private(set) var repeatMode: RepeatMode = .off
    private(set) var isShuffled = false
    /// When playback will stop by itself, if a sleep timer is running.
    private(set) var sleepTimerEnd: Date?
    /// Stop at the end of the current song rather than at a fixed time.
    private(set) var sleepsAtEndOfTrack = false
    /// Surfaces playback failures to the app-level banner, so a failure is
    /// visible even when the Now Playing screen is closed.
    var onPlaybackProblem: ((String) -> Void)?
    /// Called when the server does not recognise an id that came out of our
    /// own index — the index is describing a library that has moved on, and
    /// only a fresh sync fixes it.
    var onStaleLibrary: (() -> Void)?
    /// D2 — see `isPlaying`'s own comment for why this lives on the
    /// property rather than at each call site that can start playback.
    var onLocalPlaybackStarted: (() -> Void)?
    /// One recovery attempt per track change: an id the server refuses is
    /// worth one question back, not a loop of them.
    private var hasTriedRecovery = false
    /// Bumped at the start of every genuinely new `startCurrentTrack` call, and read back after
    /// every `await` inside it.
    private var runToken = 0
    /// The in-flight attempt to make some track current — whichever of `startCurrentTrack` or
    /// `continueSmartly` is presently deciding what plays next.
    private var currentTrackTask: Task<Void, Never>?

    /// Starts (or restarts) the attempt to make the queue's current position play, cancelling
    /// whatever attempt was still running.
    private func restartCurrentTrackTask(_ operation: @escaping () async -> Void) {
        currentTrackTask?.cancel()
        currentTrackTask = Task { await operation() }
    }
    /// True when the current song never reached the audio engine.
    private var needsReload = false
    /// How many times this song's fetch has been tried again after a dropped
    /// connection. Reset when a different song starts.
    private var networkRetries = 0
    /// How long to wait before each further attempt.
    private static let networkRetryBackoff: [Double] = [0.5, 1.5, 3, 5]
    private static var networkRetryLimit: Int { networkRetryBackoff.count }

    /// Whether a fetch ended because this app cancelled it — a newer song taking the store's one
    /// lane — rather than because anything went wrong.
    private static func wasCutOff(_ error: any Error) -> Bool {
        error.isCancelledFetch
    }



    private var engineDuration: TimeInterval?
    private let engine: any AudioEngine
    private var provider: (any MusicServerProvider)?
    /// Media is loaded by AVFoundation rather than through the app's
    /// transport, so the proxy cookie has to be attached here instead.
    private var proxySessions: (any ProxySessionSource)?
    /// Present when the streaming engine is in use: it plays local files, so
    /// the fetch happens here and goes through the app's own transport.
    private var mediaStore: MediaFileStore?
    /// Kept files, asked before anything else. Weak because the app owns it
    /// and rebuilds it whenever the library changes underneath us.
    weak var downloads: DownloadManager?
    /// Offline by choice: nothing is reported to the server, because the
    /// point of the switch is that the app leaves the network alone.
    var isOffline = false {
        // Read-ahead is decided by whether the server can be reached, so
        // it has to be decided again when that changes: offline with the next
        // song downloaded, the kept copy is what should be armed.
        didSet { if oldValue != isOffline { prefetchNext() } }
    }
    /// The server cannot be reached right now — a failed connection test, or the network gone
    /// altogether — as distinct from `isOffline`, which is a choice.
    var serverUnreachable = false {
        didSet { if oldValue != serverUnreachable { prefetchNext() } }
    }
    /// Where a finished listen goes. The player does not decide whether the
    /// server can be reached — the outbox does, and keeps it if not.
    var onPlaySubmitted: ((MediaID, Date) -> Void)?
    /// Fires as soon as a new track becomes current — before the first
    /// sample plays, unlike `onPlaySubmitted`, which waits for the halfway
    /// mark. A DJ engine needs to react the moment a song starts, to decide
    /// whether the queue ahead of it still needs topping up; waiting for a
    /// scrobble-timed signal would mean it only ever reacted once a song
    /// was half over.
    var onTrackStarted: ((Track) -> Void)?
    /// Fires after any of the *user-facing* queue-editing methods — `playNext`, `addToQueue`,
    /// `moveQueueItems`, `removeQueueItem`, `clearUpNext`, `toggleShuffle` — never after the
    /// `dj`-prefixed ones a DJ engine calls for its own insertions, which…
    var onQueueEditedByUser: (() -> Void)?
    /// Fires whenever a genuinely new queue starts — `play(_:from:)` or `shuffle(_:from:)`, never
    /// the edits below.
    var onNewQueueStarted: (() -> Void)?
    /// Told when something deliberately chosen — a record, a playlist — has actually been listened
    /// to.
    var onSourcePlayed: ((PlayedSource, Date) -> Void)?
    /// True while a track is being fetched before it can start.
    private(set) var isBuffering = false
    /// When the engine last said it had run out of audio, so the spinner
    /// raised by a stall can be told apart from the one raised by a fetch
    /// that has not started yet — see `handle(_:)`.
    private var stalledSince: Date?
    /// True while the song being listened to is coming off the server as a conversion — the seconds
    /// when the listener is waiting on a note.
    private var fetchesForPlayback = 0
    var isFetchingForPlayback: Bool { fetchesForPlayback > 0 }
    /// Bumped whenever the position moves somewhere it did not play to — a
    /// restart, for now. The seek bar watches this so such a move is a jump
    /// rather than an animated slide.
    private(set) var positionJumps = 0
    /// Bumped on every deliberate `seek(to:)`. A controller's `TargetPublisher`
    /// watches this rather than `currentTime` itself, so it sends a position
    /// on a genuine seek without waking on every half-second progress tick.
    private(set) var seeks = 0
    /// Loudness fetched for a track whose own listing carried none, keyed by the track it belongs
    /// to.
    private var fetchedGainByTrack: [MediaID: PleviDomain.ReplayGain] = [:]
    /// A conversion the settings say not to keep, waiting for playback to
    /// leave it before it is deleted.
    private var conversionToDiscard: MediaID?
    /// What the audio actually is, read from the file the engine opened —
    /// not what the transcoding policy asked the server for. This is the one
    /// that can be trusted to say whether a conversion really happened.
    private(set) var playingFormat: PlayingAudioFormat?
    /// What the Ogg Vorbis files being played were, by the decoded copy the
    /// engine was handed. The copy is plain PCM and says nothing of that, so
    /// the badge is told here.
    private var decodedSources: [URL: VorbisSourceInfo] = [:]
    /// Cancelled when the track changes, so a prefetch for a track the user
    /// has already skipped past does not hold the connection.
    private var prefetch: Task<Void, Never>?
    /// The next track, once it is on disk — held so a crossfade can start it
    /// without waiting for a fetch at the very moment it is needed.
    private var nextTrackFile: URL?
    /// The queue entry `nextTrackFile` was fetched for.
    private var nextTrackOwner: QueueItem.ID?
    /// The file in hand for this queue entry, or nil if what is held is for
    /// some other one.
    private func nextTrackFile(for item: QueueItem) -> URL? {
        nextTrackOwner == item.id ? nextTrackFile : nil
    }
    /// The file actually handed to the engine to follow this one, kept separately because
    /// `nextTrackFile` is cleared whenever the track changes — and a gapless advance needs to know
    /// afterwards what it was that started playing.
    private var preloadedFile: URL?
    /// The file the current track is playing from, which is what its ending
    /// has to be measured from.
    private var currentTrackFile: URL?
    private let smartFades = SmartFades()
    /// The part-written file a conversion is playing from, and a token that
    /// tells a callback from an abandoned fetch from a live one.
    private var growingFile: URL?
    private var growToken = 0
    private var artwork: ArtworkLoader?
    /// The `MPMediaItemArtwork` last handed to `MPNowPlayingInfoCenter`, and what it was made from
    /// — kept so a same-album track cut can hand CarPlay the identical instance instead of a
    /// freshly-built one.
    private var publishedArtwork: (id: ArtworkID, bucket: Int, artwork: MPMediaItemArtwork)?
    private var libraryIndex: LibraryIndex?
    private var waveforms: WaveformSampler?
    /// Watches whether the connection charges by the megabyte.
    private let network: NetworkPathMonitor
    private var playbackSchedule = PlaybackReportSchedule()
    private var scrobbleSubmitted = false
    /// How long this track has really been listened to, as opposed to where
    /// the play head is. See `ListenedTime`.
    private var listened = ListenedTime()
    /// The last position, length and track a progress tick reported, so the "stopped" report for a
    /// song that has just been left can say where it stopped — by the time it is built, the
    /// position has been reset for the song that replaced it.
    private var lastProgress: (id: MediaID?, position: TimeInterval, duration: TimeInterval?)?
    /// True around the deliberate `engine.stop()` at the start of a new song,
    /// whose `rateChanged(0)` is not the listener pausing.
    private var stoppingForNewTrack = false
    /// The song the lock screen dictionary was last built for.
    private var nowPlayingTrackID: MediaID?
    /// Songs skipped in a row because they could not be played; see
    /// `BadTrackPolicy`.
    private var consecutiveSkips = 0
    /// Whether the current song became current without the listener choosing
    /// it (the previous one ended, or an earlier one was skipped), and the
    /// same fact waiting for the next `startCurrentTrack` to pick up.
    private var arrivedAutomatically = false
    private var pendingAutomaticArrival = false
    /// The `runToken` of a load that is still under way, and whether the listener wants the song to
    /// start when it lands.
    private var loadingToken: Int?
    private var wantsPlaybackWhenLoaded = true
    /// Set by the engine's `.failed` while a load is being handed over, so the call site can tell
    /// that the load did not take.
    private var engineFailedLoad = false
    /// The song the server was last told about, so the next track change can
    /// say that one has stopped — see `reportStoppedForPreviousTrack`.
    private var reportedTrack: Track?

    /// What has been played since this queue began, newest first.
    private var heard: [QueueItem] = []

    /// What has been heard, newest first — not counting the song playing now.
    var history: [QueueItem] {
        let playing = currentTrack?.id
        return heard.filter { $0.track.id != playing }
    }
    /// Set by `previous()` while it steps back through `history`; see there.
    private var steppingBackTo: MediaID?

    /// The most that is kept. Long enough to cover an evening, short enough
    /// that nothing has to think about it.
    private static let historyLimit = 100

    /// Forgets what has been heard, without touching what is queued.
    func clearHistory() {
        let playing = currentTrack?.id
        heard = heard.filter { $0.track.id == playing }
    }

    /// Records a song as heard, newest first.
    private func noteInHistory(_ item: QueueItem) {
        if steppingBackTo == item.track.id {
            steppingBackTo = nil
            return
        }
        heard.removeAll { $0.track.id == item.track.id }
        heard.insert(item, at: 0)
        if heard.count > Self.historyLimit { heard.removeLast() }
    }
    private var sessionConfigured = false
    /// The queue's order before shuffling, as entry ids, so the toggle is reversible.
    private var originalOrder: [UUID]?
    private var sleepTask: Task<Void, Never>?

    /// The song playing, wearing the picture inside its downloaded file where that differs from the
    /// album's cover — Plex serves one cover per album, so a record whose songs carry their own
    /// pictures shows the same sleeve for every one of them.
    var currentTrack: Track? {
        guard var track = currentItem?.track else { return nil }
        track.artwork = artwork(for: track)
        return track
    }

    func artwork(for track: Track) -> ArtworkID? {
        downloads?.embeddedArtwork(for: track.id) ?? track.artwork
    }

    var currentItem: QueueItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// The part of the queue still to play.
    var upNext: [QueueItem] {
        guard let currentIndex, currentIndex + 1 < queue.count else { return [] }
        return Array(queue[(currentIndex + 1)...])
    }

    /// The tracks still to play, walked in place rather than copied.
    var upNextTracks: LazyMapSequence<ArraySlice<QueueItem>, Track> {
        guard let currentIndex, currentIndex + 1 < queue.count else { return ([] as [QueueItem])[...].lazy.map(\.track) }
        return queue[(currentIndex + 1)...].lazy.map(\.track)
    }

    /// The next `limit` entries still to play, and no more.
    func upNext(limit: Int) -> [QueueItem] {
        guard let currentIndex, currentIndex + 1 < queue.count else { return [] }
        return Array(queue[(currentIndex + 1)...].prefix(limit))
    }

    /// How many entries are still to play. O(1), unlike `upNext.count`.
    var upNextCount: Int {
        guard let currentIndex else { return 0 }
        return max(queue.count - currentIndex - 1, 0)
    }

    /// Whether anything is still to play. O(1), unlike `!upNext.isEmpty`.
    var hasUpNext: Bool { upNextCount > 0 }

    var duration: TimeInterval? {
        engineDuration ?? currentTrack?.duration
    }

    /// True while a top-up is in flight, so a second one is not started for
    /// the same stretch of queue.
    private var isToppingUp = false
    /// Set when the server had nothing to add, so the remaining songs do not
    /// each ask again. Cleared whenever a new queue starts.
    private var topUpCameBackEmpty = false
    /// Whether this queue has already been written into Recently Played.
    private var sourceRecorded = false

    /// Where the playing queue came from.
    private(set) var queueOrigin: QueueOrigin = .songs

    /// Whether *this* queue carries on when it runs out.
    var smartContinueForThisQueue = true {
        didSet {
            // A new queue is seeded from the setting by `adopt`, which has
            // its own bookkeeping to do and is not the listener's switch.
            guard !isAdoptingQueue, oldValue != smartContinueForThisQueue else { return }
            if oldValue {
                dropContinuationAhead()
            } else {
                // Switched back on: fill in at once if the queue is running low,
                // so the new set is there to see rather than turning up at the
                // next track change.
                topUpIfRunningLow()
            }
        }
    }
    private var isAdoptingQueue = false

    /// Takes back what Smart Continue added and the listener has not reached, when it is switched
    /// off for this queue.
    private func dropContinuationAhead() {
        guard !continuationItems.isEmpty, let index = currentIndex else { return }
        queue = queue.enumerated()
            .filter { offset, item in offset <= index || !continuationItems.contains(item.id) }
            .map(\.element)
        continuationItems.removeAll()
        onQueueEditedByUser?()
        // The engine may already hold one of the songs just taken out as its
        // join: reconciling gives it back, or it would play once and be put
        // back in the queue as an ordinary entry.
        prefetchNext()
    }

    private func adopt(_ origin: QueueOrigin) {
        isAdoptingQueue = true
        defer { isAdoptingQueue = false }
        queueEpoch &+= 1
        topUpTask?.cancel()
        topUpTask = nil
        isToppingUp = false
        continuationItems = []
        queueOrigin = origin
        smartContinueForThisQueue = settingsForGain.smartContinue(for: origin.kind)
        // A different queue is a different question: whatever the server said
        // about the last one tells us nothing about this one.
        topUpCameBackEmpty = false
        sourceRecorded = false
        onNewQueueStarted?()
    }

    var hasNext: Bool {
        guard let currentIndex else { return false }
        if repeatMode.isOn { return !queue.isEmpty }
        if currentIndex + 1 < queue.count { return true }
        // With Smart Continue on there is always something after the last song, so the skip button
        // stays live.
        return smartContinueForThisQueue && !queue.isEmpty && !topUpCameBackEmpty
    }

    init(engine: (any AudioEngine)? = nil, network: NetworkPathMonitor = NetworkPathMonitor()) {
        self.engine = engine ?? StreamingAudioEngine()
        self.network = network
        self.engine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        Self.registerRemoteCommands(for: self)
    }

    func resume() {
        if needsReload {
            // A load that is still under way is not a failure to retry: restarting it fetched the
            // song again from zero, re-fired `onTrackStarted`, and repeated presses meant it never
            // landed.
            if loadingToken != nil, loadingToken == runToken {
                wantsPlaybackWhenLoaded = true
                return
            }
            restartCurrentTrackTask { await self.startCurrentTrack() }
        } else {
            engine.play()
        }
    }

    func pause() {
        resumeOnReconnect = false
        // Paused while the song is still loading: it lands paused.
        if loadingToken != nil { wantsPlaybackWhenLoaded = false }
        engine.pause()
    }

    /// Set only where a fetch gave up because the connection was down, while the listener wanted
    /// music.
    private var resumeOnReconnect = false

    /// The network is back and the server address has been re-chosen.
    func networkReturned() {
        guard resumeOnReconnect, needsReload, !isOffline, currentTrack != nil else { return }
        resumeOnReconnect = false
        TranscodeLog.record("network returned: starting \(currentTrack?.title ?? "?") again")
        restartCurrentTrackTask { await self.startCurrentTrack() }
    }

    func configure(
        provider: any MusicServerProvider,
        artwork: ArtworkLoader?,
        index: LibraryIndex? = nil,
        proxySessions: (any ProxySessionSource)? = nil,
        mediaStore: MediaFileStore? = nil,
        waveforms: WaveformSampler? = nil
    ) {
        self.provider = provider
        self.artwork = artwork
        self.libraryIndex = index
        self.proxySessions = proxySessions
        self.mediaStore = mediaStore
        self.waveforms = waveforms
        // A store that has just been attached knows nothing of what is playing.
        storeInUse = []
        syncStoreInUse()
        startStoreHeartbeat()
        // The read-ahead in hand was started against the store and provider
        // this replaces, whose transport is being closed: begun again against
        // the new ones, or the first join after a library switch is cold.
        if currentIndex != nil { prefetchNext() }
    }

    /// Times how long the media store takes to answer a question that costs it nothing, every two
    /// seconds.
    private func startStoreHeartbeat() {
        storeHeartbeat?.cancel()
        storeHeartbeat = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, let store = self.mediaStore else { continue }
                tick += 1
                let sent = tick
                let start = Date()
                TranscodeLog.record("store ping \(sent) sent")
                Task {
                    _ = await store.ping()
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    TranscodeLog.record("store ping \(sent) answered in \(ms)ms")
                }
            }
        }
    }

    private var storeHeartbeat: Task<Void, Never>?

    /// Reads a track's shape as soon as its audio is on disk, and keeps it.
    private func engineFile(for file: URL) async -> URL {
        let started = Date()
        let result = await DecodedAudioCache.shared.playable(file)
        if let source = result.source {
            decodedSources[result.url] = source
            TranscodeLog.record("decoded Ogg Vorbis for playback: \(source.frames) frames at \(source.sampleRate) Hz in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } else if VorbisFile.isVorbis(at: file) {
            // Not decodable: the engine will refuse the file, and the player
            // treats that as it treats any file it cannot open.
            TranscodeLog.record("Ogg Vorbis file could not be decoded: \(file.lastPathComponent)")
        }
        return result.url
    }

    /// Plays a file that is on the device: as it is, or — for Ogg Vorbis, which
    /// iOS cannot read — decoded as it goes, so the song starts on its first
    /// seconds and not after the whole of it. See `DecodedAudioCache.playableEarly`.
    private func playLocalFile(_ file: URL, track: Track, token: Int) async {
        guard VorbisFile.isVorbis(at: file) else {
            playFromDisk(file, track: track)
            return
        }
        let started = Date()
        let early = await DecodedAudioCache.shared.playableEarly(file) { [weak self] ok in
            Task { @MainActor [weak self] in self?.vorbisDecodeFinished(track.id, ok: ok, token: token) }
        }
        guard token == runToken, currentTrack?.id == track.id else { return }
        guard let source = early.playable.source else {
            // Not decodable: the engine will refuse the file, and the player
            // treats that as it treats any file it cannot open.
            TranscodeLog.record("Ogg Vorbis file could not be decoded: \(file.lastPathComponent)")
            playFromDisk(file, track: track)
            return
        }
        decodedSources[early.playable.url] = source
        TranscodeLog.record("decoded Ogg Vorbis for playback: first audio in \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(early.isComplete ? "whole copy" : "rest still being decoded")")
        if early.isComplete {
            playFromDisk(early.playable.url, track: track)
            return
        }
        // The rest is still being written: played as a growing file, exactly as
        // a conversion is, until `vorbisDecodeFinished` says it is whole.
        let copy = early.playable.url
        growToken &+= 1
        growingFile = copy
        currentTrackFile = copy
        engineFailedLoad = false
        engine.loadGrowing(
            copy,
            expectedDuration: track.duration,
            autoplay: wantsPlaybackWhenLoaded,
            declaresLength: false
        )
        needsReload = engineFailedLoad
        if engineFailedLoad { growingFile = nil; return }
        isBuffering = false
        updatePlaybackInfo()
        if let mediaStore { Task { await mediaStore.used(file) } }
        prefetchNext()
        publishNowPlaying(track)
        guard !isOffline else { return }
        Task { [provider = self.provider] in
            try? await provider?.scrobble(id: track.id, at: Date(), submission: false)
        }
    }

    /// The decoded copy is whole: the engine is told that what it was playing as
    /// it grew is all there is, and the next song can be joined on.
    private func vorbisDecodeFinished(_ id: MediaID, ok: Bool, token: Int) {
        guard token == runToken, currentTrack?.id == id, let copy = growingFile else { return }
        growToken &+= 1
        growingFile = nil
        if !ok { TranscodeLog.record("decoding Ogg Vorbis stopped part-way; playing what was decoded") }
        engine.growthFinished(at: copy)
        // A gapless join could not be armed while this song was still arriving.
        if let index = currentIndex, queue.indices.contains(index + 1),
           let next = nextTrackFile(for: queue[index + 1]) {
            armNext(queue[index + 1], file: next)
        }
        warmWaveform(for: id, file: copy)
    }

    /// Whether this track's codec is one the app decodes for itself, and so
    /// arrives whole rather than being played as it grows.
    private static func isBundledDecoded(_ track: Track) -> Bool {
        guard let value = NativeAudioSupport.normalise(track.codec ?? track.contentType) else { return false }
        return NativeAudioSupport.bundledDecoders.contains(value)
    }

    private func playFromDisk(_ file: URL, track: Track) {
        let autoplay = wantsPlaybackWhenLoaded
        // Nothing is arriving in pieces any more.
        growToken &+= 1
        growingFile = nil
        // The file this track's ending will be measured from.
        currentTrackFile = file
        engineFailedLoad = false
        engine.load(URLRequest(url: file), autoplay: autoplay)
        needsReload = engineFailedLoad
        // A file that would not open: nothing is playing, so there is nothing
        // to read the shape of, line up behind, publish or report.
        if engineFailedLoad { return }
        // A play, for the cache's sake: a hit never passes through the store,
        // so without this the files played most were evicted first.
        if let mediaStore { Task { await mediaStore.used(file) } }
        warmWaveform(for: track.id, file: file)
        prefetchNext()
        publishNowPlaying(track)
        guard !isOffline else { return }
        Task { [provider = self.provider] in
            try? await provider?.scrobble(id: track.id, at: Date(), submission: false)
        }
    }

    private func warmWaveform(for id: MediaID, file: URL) {
        guard let waveforms, let libraryIndex,
              (try? libraryIndex.waveform(forTrack: id)) ?? nil == nil
        else { return }
        Task { [weak self] in
            guard let bars = await waveforms.waveform(for: id, url: file) else { return }
            try? self?.libraryIndex?.storeWaveform(bars, forTrack: id)
        }
    }

    /// Fetches the next track while this one plays.
    private func prefetchNext() {
        // Every queue edit ends here, and the engine may be holding a join the
        // edit has just made wrong — see `reconcileArmedNext`.
        reconcileArmedNext()
        prefetch?.cancel()
        guard let mediaStore, let provider, let currentIndex else { return }

        // How far ahead depends on what the connection costs: several songs
        // on a home network, and by default only the next one on cellular,
        // where reading ahead spends data on songs that may be skipped.
        let depth = max(
            1,
            settingsForGain.prefetchCount(expensiveNetwork: network.isExpensive)
        )
        // Entries, not just tracks: what gets armed is remembered by the entry's
        // id, so a later edit can tell whether it is still the next one.
        let upcomingItems = Array(queue.dropFirst(currentIndex + 1).prefix(depth))
        guard !upcomingItems.isEmpty else { return }

        prefetch = Task { [weak self] in
            guard let self else { return }
            // In order, one at a time: the next song has to arrive first, and
            // three parallel downloads over one connection help nobody.
            for (offset, item) in upcomingItems.enumerated() {
                let track = item.track
                guard !Task.isCancelled, self.currentTrack != nil else { return }
                // A copy that is already on the phone, exactly as the current track would choose
                // it.
                if let kept = self.downloads?.fileURL(for: track.id), self.shouldPlayDownloadedCopy(of: track) {
                    // Only the next song is decoded ahead of time — that is the one a gapless join
                    // has to have in hand.
                    let playable = offset == 0 ? await self.engineFile(for: kept) : kept
                    guard !Task.isCancelled, self.currentTrack != nil else { return }
                    self.warmWaveform(for: track.id, file: playable)
                    if offset == 0 { self.armNext(item, file: playable) }
                    continue
                }
                // The depth is the setting *now*, not the one this pass started under: leaving
                // Wi-Fi halfway through fifteen songs must not go on spending cellular data on the
                // rest, and the picker being lowered mid-pass counts too.
                guard ReadAhead.mayFetch(
                    offset: offset,
                    allowedDepth: self.settingsForGain.prefetchCount(expensiveNetwork: self.network.isExpensive)
                ) else { return }
                // Offline or unreachable, with no copy to play: the fetch below
                // can only fail, and would fail again for each of the fifteen.
                let cannotReachServer = self.isOffline || self.serverUnreachable
                // Same rule as the current track: never convert a song the
                // disk already holds in full. One listing answers that and
                // whether the song is here at all.
                let local = await mediaStore.localFiles(for: track.id)
                var options = Self.streamOptions(for: track, policy: self.streamPolicy)
                if options.transcodeTo != nil, local.hasOriginal, NativeAudioSupport.canDecode(track.codec ?? track.contentType, includingBundled: true) {
                    options = .original
                }
                let variant = Self.variant(for: options)
                let file: URL
                if let cached = local.cached(variant: variant) {
                    // Already here: nothing to fetch, and no conversion to end.
                    file = cached
                    // Not fetched, but wanted: it stays oldest otherwise.
                    await mediaStore.used(cached)
                } else {
                    if cannotReachServer { continue }
                    guard let source = try? await provider.streamSource(
                        for: track.id,
                        options: options
                    ) else { continue }
                    guard !Task.isCancelled else { return }
                    // A guess at the next song, and asked for as one: it waits while the song
                    // playing now arrives, and is cut off by a tap.
                    guard let fetched = try? await mediaStore.file(
                        for: track.id,
                        request: self.proxySessions?.authenticating(source.request) ?? source.request,
                        variant: variant,
                        priority: .readAhead,
                        markPlayed: false,
                        expectedDuration: track.duration,
                        bitRateKbps: track.bitRateKbps
                    ) else { continue }
                    file = fetched
                    if variant.isOriginal {
                        await mediaStore.dropConversions(for: track.id)
                    } else {
                        // The whole of it is on this device now, so the server has nothing further
                        // to do for this song.
                        TranscodeLog.record("endPlayback: \(track.title) (prefetch)")
                        await provider.endPlayback(for: track.id)
                    }
                }
                guard !Task.isCancelled, self.currentTrack != nil else { return }

                // Decoded now if it is Ogg Vorbis, so the join has a file the
                // engine can open.
                let playable = offset == 0 ? await self.engineFile(for: file) : file
                guard !Task.isCancelled, self.currentTrack != nil else { return }
                self.warmWaveform(for: track.id, file: playable)

                // Only the immediate next track is handed to the engine —
                // that is the one a gapless join needs in hand.
                if offset == 0 { self.armNext(item, file: playable) }
            }
        }
    }

    /// Records the file behind the next queue entry and, where the join is gapless by default,
    /// hands it to the engine.
    private func armNext(_ item: QueueItem, file: URL) {
        guard repeatMode != .one,
              let currentIndex, queue.indices.contains(currentIndex + 1),
              queue[currentIndex + 1].id == item.id
        else { return }
        nextTrackFile = file
        nextTrackOwner = item.id
        guard !settingsForGain.smartFades, !sleepsAtEndOfTrack, armedNext == nil else { return }
        if engine.preloadNext(URLRequest(url: file)) {
            preloadedFile = file
            armedNext = item
        }
    }

    /// The queue entry whose audio the engine holds behind the playing one.
    private var armedNext: QueueItem? {
        didSet { syncStoreInUse() }
    }

    /// The tracks the media store has last been told are in use, and the
    /// order that was said in.
    private var storeInUse: Set<MediaID> = []
    private var storeInUseSequence = 0

    /// Tells the media store which tracks are playing or about to, so that Clear cache, turning off
    /// "Keep transcoded files" and eviction leave their files alone.
    private func syncStoreInUse() {
        guard let mediaStore else { return }
        var ids: Set<MediaID> = []
        if let currentIndex, queue.indices.contains(currentIndex) {
            ids.insert(queue[currentIndex].track.id)
            if queue.indices.contains(currentIndex + 1) { ids.insert(queue[currentIndex + 1].track.id) }
        }
        if let armedNext { ids.insert(armedNext.track.id) }
        guard ids != storeInUse else { return }
        storeInUse = ids
        storeInUseSequence &+= 1
        let sequence = storeInUseSequence
        Task { await mediaStore.setInUse(ids, sequence: sequence) }
    }

    /// Takes the engine's join back if the queue no longer says the same song is next.
    private func reconcileArmedNext() {
        guard let armed = armedNext else { return }
        guard QueueJoin.status(of: queue, currentIndex: currentIndex, armed: armed.id) != .inPlace
        else { return }
        disarmNext()
    }

    /// Asks the engine to take the armed join back, and forgets it here when
    /// it did. When the overlap is already audible the engine refuses, and the
    /// model keeps the record so the advance can follow the audio instead.
    private func disarmNext() {
        guard armedNext != nil else { return }
        guard engine.cancelPendingNext() else { return }
        armedNext = nil
        preloadedFile = nil
        nextTrackFile = nil
        transitionSettled = false
    }

    /// The engine dropped a join we thought was armed — a seek cancelled the
    /// overlap, or a rebuild threw the schedule away. The file is still on
    /// disk, so the join can be decided again.
    private func engineDroppedArmedNext() {
        let dropped = armedNext
        armedNext = nil
        if let file = preloadedFile {
            nextTrackFile = file
            nextTrackOwner = dropped?.id
        }
        preloadedFile = nil
        transitionSettled = false
    }

    /// How long before the end a transition is settled on.
    private static let decisionLeadSeconds = TransitionTiming.decisionLeadSeconds

    /// Whether this track's join has already been settled, either way.
    private var transitionSettled = false

    /// Decides how this track should meet the next one, once it is close enough to the end to be
    /// worth doing and while there is still room.
    private func settleTransitionIfDue(at time: TimeInterval) {
        guard settingsForGain.smartFades, !transitionSettled else { return }
        // Nothing to decide when the engine already holds a join (Smart Fades
        // was switched on after the gapless one was armed): deciding again
        // would schedule the next song a second time on top of it.
        if armedNext != nil {
            transitionSettled = true
            return
        }
        // An end-of-song sleep wants a clean ending, not a join.
        guard !sleepsAtEndOfTrack else { return }
        guard let total = duration, total > 0 else { return }
        guard repeatMode != .one, hasNext else { return }

        let remaining = total - time
        guard remaining <= Self.decisionLeadSeconds else { return }

        // Past this there is no longer room to schedule honestly, so the join
        // is left plain rather than rushed.
        let floorRemaining = TransitionTiming.floorRemaining(
            maxOverlap: settingsForGain.maxOverlapSeconds
        )
        guard remaining >= floorRemaining else {
            // Said out loud: nothing arms a join after this, so the track runs out and the next one
            // is loaded from scratch.
            logJoin(
                "window missed with \(String(format: "%.1f", remaining))s left — "
                    + "next file \(nextTrackFile == nil ? "not on disk" : "ready"), "
                    + "this file \(currentTrackFile == nil ? "not on disk" : "ready")"
            )
            transitionSettled = true
            return
        }
        // The file for whoever is next *now*. One held for a song that has
        // since been put behind another is not it, and arming it would play
        // that song under this one's name.
        guard let upcoming = queue.dropFirst((currentIndex ?? 0) + 1).first,
              let file = nextTrackFile(for: upcoming)
        else { return }

        let outgoing = currentTrack
        let incomingItem = queue.dropFirst((currentIndex ?? 0) + 1).first
        let incoming = incomingItem?.track
        // Only once there is something to decide with.
        guard let outgoing, let incomingItem, let incoming, let outgoingFile = currentTrackFile else { return }
        transitionSettled = true

        Task { [weak self] in
            await self?.settleTransition(
                outgoing: outgoing,
                outgoingFile: outgoingFile,
                incomingItem: incomingItem,
                incoming: incoming,
                incomingFile: file,
                totalDuration: total
            )
        }
    }

    /// One line in the playback log about how the join out of the playing
    /// track was decided — the part of a transition nothing else records.
    private func logJoin(_ message: String, outgoing: Track? = nil, incoming: Track? = nil) {
        let from = outgoing ?? currentTrack
        let to = incoming ?? queue.dropFirst((currentIndex ?? -1) + 1).first?.track
        TranscodeLog.record("join \(from?.title ?? "?") → \(to?.title ?? "?"): \(message)")
    }

    private func settleTransition(
        outgoing: Track,
        outgoingFile: URL,
        incomingItem: QueueItem,
        incoming: Track,
        incomingFile: URL,
        totalDuration: TimeInterval
    ) async {
        let settings = settingsForGain
        // Whether the decision is still about the right pair of songs.
        func stillNext() -> Bool {
            guard currentTrack?.id == outgoing.id,
                  let index = currentIndex, queue.indices.contains(index + 1),
                  queue[index + 1].id == incomingItem.id,
                  armedNext == nil, repeatMode != .one, !sleepsAtEndOfTrack
            else { return false }
            return true
        }
        // Whatever happens below, the join has to be armed one way or the
        // other before this returns. A decision that quietly did nothing
        // would leave a silence where the gapless join used to be.
        var armGapless = true
        defer {
            if armGapless, stillNext() {
                // The engine's answer is kept: it may refuse (another sample
                // rate, something already armed), and then there is no join.
                if engine.preloadNext(URLRequest(url: incomingFile)) {
                    preloadedFile = incomingFile
                    armedNext = incomingItem
                    logJoin("gapless join armed", outgoing: outgoing, incoming: incoming)
                } else {
                    logJoin("gapless join refused by the engine", outgoing: outgoing, incoming: incoming)
                }
            } else if armGapless, currentTrack?.id == outgoing.id {
                // The queue moved on while this was deciding. Let the next
                // progress tick decide again about whoever is next now.
                transitionSettled = false
            }
        }

        // Known well ahead of when it is needed — a join is settled a good twenty seconds before it
        // happens — so there is time for the one network round trip a Plex track without its own
        // tag might still need.
        if let provider, incoming.replayGain == nil {
            await prefetchLoudnessIfNeeded(for: incoming, from: provider)
        }
        let outgoingGain = linearGain(for: outgoing, settings: settings)
        let incomingGain = linearGain(for: incoming, settings: settings)

        async let outgoingMeasured = smartFades.measurement(for: outgoing.id, fileAt: outgoingFile)
        async let incomingMeasured = smartFades.measurement(for: incoming.id, fileAt: incomingFile)
        let measuredTail = await outgoingMeasured
        let measuredHead = await incomingMeasured
        guard let tail = measuredTail, let head = measuredHead else {
            logJoin(
                "could not be measured (\(measuredTail == nil ? "this song's end" : "")"
                    + "\(measuredTail == nil && measuredHead == nil ? " and " : "")"
                    + "\(measuredHead == nil ? "the next song's start" : "")) — joined plainly",
                outgoing: outgoing,
                incoming: incoming
            )
            return
        }
        // The song may have moved on while the two files were being measured.
        guard currentTrack?.id == outgoing.id else {
            armGapless = false
            return
        }
        guard stillNext() else { return }

        let ratesConflict = settings.matchSampleRates
            && SmartFades.sampleRatesConflict(outgoingFile, incomingFile)

        let decision = TransitionPlanner.plan(
            outgoing: tail.profile.scaled(byLinearGain: Double(outgoingGain)),
            incoming: head.profile.scaled(byLinearGain: Double(incomingGain)),
            context: TransitionContext(
                outgoingDuration: totalDuration,
                incomingDuration: incoming.duration ?? totalDuration,
                incomingLeadingSilence: head.leadingSilence,
                sameAlbum: outgoing.albumID != nil && outgoing.albumID == incoming.albumID,
                sampleRatesConflict: ratesConflict,
                incomingIsReady: true
            ),
            settings: TransitionSettings(
                thresholdDb: settings.fadeThresholdDb,
                overlapTrim: settings.overlapTrimSeconds,
                maxOverlap: settings.maxOverlapSeconds,
                envelope: settings.fadeEnvelope,
                keepAlbumsGapless: settings.keepAlbumsGapless
            )
        )

        let numbers = "this song's tail \(String(format: "%.1f", tail.profile.tailSeconds(atThresholdDb: settings.fadeThresholdDb)))s, "
            + "the next one's head \(String(format: "%.1f", head.profile.headSeconds(atThresholdDb: settings.fadeThresholdDb)))s, "
            + "levels \(String(format: "%.1f", tail.profile.referenceDb)) / \(String(format: "%.1f", head.profile.referenceDb)) dB, "
            + "raw overlap \(String(format: "%.1f", decision.rawOverlap))s"
        guard case let .overlap(seconds, envelope, attenuationDb) = decision.transition else {
            // A refusal is an answer: the two are joined plainly, which the
            // deferred arming above does.
            logJoin(
                "gapless (\(decision.reason?.rawValue ?? "no reason")) — \(numbers)",
                outgoing: outgoing,
                incoming: incoming
            )
            return
        }
        let attenuation = Float(pow(10.0, attenuationDb / 20))
        if engine.beginOverlap(
            into: URLRequest(url: incomingFile),
            overlap: seconds,
            envelope: envelope,
            incomingGain: incomingGain,
            attenuation: attenuation
        ) {
            armGapless = false
            // The overlap has taken the incoming file, so that is what will be
            // playing after the join.
            preloadedFile = incomingFile
            armedNext = incomingItem
            logJoin(
                "overlap \(String(format: "%.1f", seconds))s, \(envelope.rawValue) — \(numbers)",
                outgoing: outgoing,
                incoming: incoming
            )
        } else {
            logJoin(
                "overlap \(String(format: "%.1f", seconds))s refused by the engine (too late, "
                    + "or something already armed) — joined plainly",
                outgoing: outgoing,
                incoming: incoming
            )
        }
    }

    /// Kept so a gapless advance can re-level without the view layer.
    private var settingsForGain = AppSettings()

    /// Pushes the current tone and levelling settings into the engine.
    func applyAudioSettings(_ settings: AppSettings) {
        let smartFadesChanged = settingsForGain.smartFades != settings.smartFades
        settingsForGain = settings
        engine.setEqualizer(settings.equalizerPreset)
        engine.setLimiter(settings.limiterEnabled)
        applyReplayGain(for: currentTrack, settings: settings)
        // Levelling switched on mid-song: a Plex listing carries no loudness, so the current track
        // and the one armed behind it have nothing to level with until it is asked for.
        if let provider, settings.replayGainMode.isEnabled {
            let wanted = [currentTrack, queue.dropFirst((currentIndex ?? -1) + 1).first?.track]
            for track in wanted.compactMap({ $0 }) {
                Task { [weak self] in await self?.prefetchLoudnessIfNeeded(for: track, from: provider) }
            }
        }
        // Smart Fades turned off after the join was decided: nothing arms the gapless join any more
        // (the settle step is off), so do it here.
        if smartFadesChanged, !settings.smartFades {
            transitionSettled = false
            prefetchNext()
        }
    }

    /// Puts the position back to zero at the *same moment* the track changes.
    private func resetPosition(keepingTime: Bool = false) {
        if !keepingTime {
            currentTime = 0
            engineDuration = nil
        }
        // A new track brings a new join to settle.
        transitionSettled = false
        // And the file behind the *next* join is not the one behind the last.
        nextTrackFile = nil
    }

    private func applyReplayGain(for track: Track?, settings: AppSettings) {
        engine.setGain(linearGain(for: track, settings: settings))
    }

    /// The linear ReplayGain multiplier for a track, from whatever loudness is currently known for
    /// it.
    private func linearGain(for track: Track?, settings: AppSettings) -> Float {
        let gain = track?.replayGain ?? track.flatMap { fetchedGainByTrack[$0.id] }
        let tags = ReplayGainTags(
            trackGainDB: gain?.trackGain,
            trackPeak: gain?.trackPeak,
            albumGainDB: gain?.albumGain,
            albumPeak: gain?.albumPeak
        )
        return ReplayGain.linearGain(
            for: tags,
            mode: settings.replayGainMode,
            preampDB: settings.replayGainPreampDB
        )
    }

    // MARK: Transport

    func play(_ tracks: [Track], startingAt index: Int = 0, from origin: QueueOrigin = .songs) {
        guard tracks.indices.contains(index) else { return }
        adopt(origin)
        // A new queue is a new sitting; what was heard before it belonged to
        // the last one.
        heard = []
        queue = tracks.map(QueueItem.init)
        originalOrder = nil
        isShuffled = false
        resetPosition()
        currentIndex = index
        restartCurrentTrackTask { await self.startCurrentTrack() }
    }

    /// Starts the given tracks in a random order.
    func shuffle(
        _ tracks: [Track], startingWith seed: Track? = nil, from origin: QueueOrigin = .songs, smart: Bool? = nil
    ) {
        guard !tracks.isEmpty else { return }
        adopt(origin)
        // Built once, and `queue` below is derived from this same array rather than a second
        // `.map(QueueItem.init)` over the same tracks: `QueueItem.init` mints a fresh id every
        // call, and a second batch of them would leave `originalOrder` and…
        let items = tracks.map(QueueItem.init)
        originalOrder = items.map(\.id)

        let pinned = seed.flatMap { seed in items.firstIndex { $0.track.id == seed.id } }
        queue = shuffledOrder(items, smart: smart, pinned: pinned)
        isShuffled = true
        resetPosition()
        currentIndex = 0
        restartCurrentTrackTask { await self.startCurrentTrack() }
    }

    /// A running order for these entries: the smart shuffle or a plain one, following the setting,
    /// whatever the queue came from, and anything the listener asked for explicitly.
    private func shuffledOrder(_ items: [QueueItem], smart: Bool? = nil, pinned: Int? = nil) -> [QueueItem] {
        var generator = SystemRandomNumberGenerator()
        return QueueOrder.shuffled(
            items,
            track: \.track,
            smart: SmartShuffle.isSmart(
                default: settingsForGain.smartShuffleByDefault,
                override: smart,
                isAlbum: queueOrigin.kind == .album
            ),
            settings: settingsForGain.smartShuffle,
            pinned: pinned,
            using: &generator
        )
    }

    /// Inserts directly after the playing track, so it plays once the current
    /// one finishes. Starts playback when nothing is playing.
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let currentIndex else {
            play(tracks)
            return
        }
        queue.insert(contentsOf: tracks.map(QueueItem.init), at: min(currentIndex + 1, queue.count))
        onQueueEditedByUser?()
        prefetchNext()
    }

    /// Appends to the end of the queue. Starts playback when nothing is
    /// playing.
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard currentIndex != nil else {
            play(tracks)
            return
        }
        let items = tracks.map(QueueItem.init)
        // Before anything Smart Continue has added, not after: something put
        // on the queue by hand is not meant to wait behind two hours of music
        // the app chose.
        if let current = currentIndex,
           let at = queue.indices.first(where: { $0 > current && continuationItems.contains(queue[$0].id) }) {
            queue.insert(contentsOf: items, at: at)
        } else {
            queue.append(contentsOf: items)
        }
        onQueueEditedByUser?()
        prefetchNext()
    }

    // MARK: Queue editing

    /// Reorders the queue. The playing track keeps playing wherever it lands,
    /// at whatever position it had already reached.
    func moveQueueItems(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let playing = currentItem
        queue.move(fromOffsets: offsets, toOffset: destination)
        if let playing, let index = queue.firstIndex(where: { $0.id == playing.id }) {
            resetPosition(keepingTime: true)
            currentIndex = index
        }
        // A hand-made order is the order now: there is nothing meaningful to
        // restore to.
        originalOrder = nil
        onQueueEditedByUser?()
        prefetchNext()
    }

    /// Removes one entry. Removing the playing track advances to the next.
    func removeQueueItem(_ item: QueueItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let wasPlaying = index == currentIndex
        queue.remove(at: index)

        guard let current = currentIndex else {
            onQueueEditedByUser?()
            return
        }
        // Told once the indexes are right: a DJ reacts to this at once and
        // reads what is up next from `currentIndex`.
        defer { onQueueEditedByUser?() }
        if wasPlaying {
            if queue.isEmpty {
                stop()
            } else {
                resetPosition()
                currentIndex = min(current, queue.count - 1)
                // No explicit prefetch call needed here — `startCurrentTrack()`
                // calls `prefetchNext()` itself, against this now-corrected
                // index.
                restartCurrentTrackTask { await self.startCurrentTrack() }
            }
        } else {
            // The playing track did not move, but everything downstream of the removed entry did —
            // what `prefetchNext()` was chasing may no longer be next at all.
            if index < current {
                // The same song is still playing, one place earlier: its
                // position and length stay.
                resetPosition(keepingTime: true)
                currentIndex = current - 1
            }
            prefetchNext()
        }
    }

    /// Jumps straight to an entry.
    func play(_ item: QueueItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        resetPosition()
        currentIndex = index
        restartCurrentTrackTask { await self.startCurrentTrack() }
    }

    /// Back to a song that has already been heard.
    func playAgain(_ item: QueueItem) {
        if let queued = queue.first(where: { $0.id == item.id }) {
            play(queued)
        } else if let sameTrack = queue.first(where: { $0.track.id == item.track.id }) {
            play(sameTrack)
        }
    }

    /// Empties everything after the playing track.
    func applyRating(_ rating: StarRating?, to id: MediaID) {
        for index in queue.indices where queue[index].track.id == id {
            queue[index].track.rating = rating
        }
        for index in heard.indices where heard[index].track.id == id {
            heard[index].track.rating = rating
        }
    }

    func applyFavorite(_ favorite: Bool, to id: MediaID) {
        for index in queue.indices where queue[index].track.id == id {
            queue[index].track.isFavorite = favorite
        }
        for index in heard.indices where heard[index].track.id == id {
            heard[index].track.isFavorite = favorite
        }
    }

    func clearUpNext() {
        guard let currentIndex, currentIndex + 1 < queue.count else { return }
        queue.removeSubrange((currentIndex + 1)...)
        onQueueEditedByUser?()
        // Nothing left to prefetch, but this also cancels whatever fetch was
        // still in flight for a track that no longer exists in the queue —
        // worth calling for that alone.
        prefetchNext()
    }

    /// Removes several entries in one pass — a remote controller's multi-select, Up Next only.
    func removeQueueEntries(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        // Up Next only, as documented: removing the playing entry or one
        // before it would leave `currentIndex` pointing at the wrong song.
        guard let current = currentIndex else { return }
        var offset = -1
        queue.removeAll { item in
            offset += 1
            return offset > current && ids.contains(item.id)
        }
        onQueueEditedByUser?()
        prefetchNext()
    }

    // MARK: Modes

    func cycleRepeatMode() {
        applyRepeatMode(repeatMode.next)
    }

    /// Sets the mode directly, for a caller that already knows which one it
    /// wants — a remote controller's own repeat control, which offers all
    /// three rather than cycling through them.
    func setRepeatMode(_ mode: RepeatMode) {
        applyRepeatMode(mode)
    }

    /// Repeat-one replays this track instead of moving on, so a join armed behind it has to come
    /// out, and one that was skipped while repeat-one was on has to go back in.
    private func applyRepeatMode(_ mode: RepeatMode) {
        let previous = repeatMode
        repeatMode = mode
        // Repeat Queue and Repeat One take over from Smart Continue. Music it
        // had already added ahead of the playing song goes, or the queue would
        // wrap at the end of that rather than at the end of the record.
        if mode.isOn, !previous.isOn, !continuationItems.isEmpty, let index = currentIndex {
            queue = queue.enumerated()
                .filter { offset, item in offset <= index || !continuationItems.contains(item.id) }
                .map(\.element)
            continuationItems.removeAll()
            // The engine may have been handed the song that has just been taken out of the queue as
            // the join to make: reconciling gives it back, or it plays once and is put back in the
            // queue as an ordinary entry.
            prefetchNext()
        }
        if mode == .one, previous != .one {
            disarmNext()
            // Nothing to settle while repeating one song.
            transitionSettled = true
        } else if previous == .one, mode != .one {
            transitionSettled = false
            prefetchNext()
        }
    }

    /// Shuffles the whole queue, the playing song carrying on first, or
    /// restores the original order.
    func toggleShuffle() {
        guard !queue.isEmpty else { return }
        let playing = currentItem

        if isShuffled {
            if let originalOrder {
                // What Smart Continue added is not part of the record's order, and `restored` files
                // an entry it has no rank for after whichever ranked one it follows — which, after
                // a shuffle, is any of them.
                let extras = queue.filter { continuationItems.contains($0.id) }
                let base = queue.filter { !continuationItems.contains($0.id) }
                queue = QueueOrder.restored(base, originalOrder: originalOrder) + extras
            }
            isShuffled = false
            originalOrder = nil
        } else {
            originalOrder = queue.map(\.id)
            // The whole queue, with the song that is playing carrying on first.
            let extras = queue.filter { continuationItems.contains($0.id) && $0.id != playing?.id }
            let body = queue.filter { !extras.contains($0) }
            if let playing, let index = body.firstIndex(where: { $0.id == playing.id }) {
                var others = body
                others.remove(at: index)
                queue = [playing] + shuffledOrder(others) + extras
            } else {
                queue = shuffledOrder(body) + extras
            }
            isShuffled = true
        }

        // By id: the whole entry also carries the track's rating and heart, which change under a
        // playing song, and a comparison of whole entries then finds nothing and leaves
        // `currentIndex` on the wrong song.
        if let playing, let index = queue.firstIndex(where: { $0.id == playing.id }) {
            resetPosition(keepingTime: true)
            currentIndex = index
        }
        onQueueEditedByUser?()
        // Whatever was next before the shuffle very likely is not next
        // anymore.
        prefetchNext()
    }

    // MARK: DJ queue editing
    //
    // Kept apart from "Queue editing" above deliberately: everything here is
    // called by a DJ engine acting on its own decisions, and none of it
    // fires `onQueueEditedByUser` — that hook exists so a DJ engine can tell
    // a person's edit from its own, and firing it here would mean a DJ
    // engine misreading its own insertions as a person overriding it.
    //
    // Every method below only ever touches `upNext` — strictly after
    // `currentIndex` — never the playing track or anything before it, so
    // none of them need to adjust `currentIndex` the way the user-facing
    // methods above sometimes do.

    /// Inserts DJ-authored tracks right after the playing one — Moody and
    /// Fresh weaving into a gap, or the first tracks of a fresh Era/Purist/
    /// Deep Cuts/Gold continuation.
    func djInsertNext(_ tracks: [Track], by origin: DJStrategyKind) {
        guard !tracks.isEmpty, let currentIndex else { return }
        let items = tracks.map { QueueItem.authored($0, by: origin) }
        queue.insert(contentsOf: items, at: min(currentIndex + 1, queue.count))
        // Landed right after the playing track — almost certainly the new "next," and due for a
        // prefetch head start rather than sitting uncached until the moment it is actually needed.
        prefetchNext()
    }

    /// Appends DJ-authored tracks to the end of the queue — Era, Purist,
    /// Deep Cuts and Gold's own continuation, and Drift/Journey topping up
    /// their rolling buffer.
    func djAppend(_ tracks: [Track], by origin: DJStrategyKind) {
        guard !tracks.isEmpty else { return }
        queue.append(contentsOf: tracks.map { QueueItem.authored($0, by: origin) })
        prefetchNext()
    }

    /// Inserts DJ-authored tracks right after one specific, still-present entry — Moody and Fresh
    /// weaving into the gap after one particular upcoming song, as opposed to `djInsertNext`, which
    /// always means "right after whatever is playing right…
    @discardableResult
    func djInsertAfter(_ afterID: UUID, tracks: [Track], by origin: DJStrategyKind) -> Bool {
        guard !tracks.isEmpty, let anchorIndex = queue.firstIndex(where: { $0.id == afterID }) else { return false }
        // An anchor the listener has since skipped past: inserting after it
        // would put the picks before the playing song and leave `currentIndex`
        // naming a different entry.
        guard anchorIndex >= (currentIndex ?? -1) else { return false }
        let items = tracks.map { QueueItem.authored($0, by: origin) }
        queue.insert(contentsOf: items, at: anchorIndex + 1)
        prefetchNext()
        return true
    }

    /// Clears everything not yet played and replaces it with a fresh, DJ-authored run — Drift and
    /// Journey's own queue policy.
    @discardableResult
    func djReplaceUpcoming(with tracks: [Track], by origin: DJStrategyKind) -> [QueueItem] {
        guard let currentIndex else { return [] }
        let displaced = currentIndex + 1 < queue.count ? Array(queue[(currentIndex + 1)...]) : []
        if !displaced.isEmpty {
            queue.removeSubrange((currentIndex + 1)...)
        }
        originalOrder = nil
        if !tracks.isEmpty {
            queue.append(contentsOf: tracks.map { QueueItem.authored($0, by: origin) })
        }
        prefetchNext()
        return displaced
    }

    /// Deactivation's own cleanup: removes specific not-yet-played entries by id, leaving
    /// everything else — the user's own entries, and anything already played — exactly where it is.
    func djRemoveEntries(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        queue.removeAll { ids.contains($0.id) }
        prefetchNext()
    }

    /// Re-inserts previously stashed entries right after the playing track — "Restore queue."
    /// Whatever the user has added since the stash was taken stays exactly where it is, further
    /// back in the queue; this only ever inserts, it never clears…
    func djRestoreStashed(_ items: [QueueItem]) {
        guard !items.isEmpty, let currentIndex else { return }
        queue.insert(contentsOf: items, at: min(currentIndex + 1, queue.count))
        prefetchNext()
    }

    // MARK: Sleep timer

    /// Minutes remaining, for display.
    var sleepMinutesRemaining: Int? {
        guard let sleepTimerEnd else { return nil }
        return max(0, Int(sleepTimerEnd.timeIntervalSinceNow / 60) + 1)
    }

    var isSleepTimerActive: Bool {
        sleepTimerEnd != nil || sleepsAtEndOfTrack
    }

    func startSleepTimer(minutes requested: Int) {
        cancelSleepTimer()
        // A minute to a day, whoever asks: `Duration.seconds` traps on an
        // overflowing product, and a controller's `sleep(.minutes(Int.max))`
        // arrives here from the wire (`TargetSession.apply`).
        let minutes = min(max(requested, 1), 1440)
        let end = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepTimerEnd = end
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TimeInterval(minutes) * 60))
            guard !Task.isCancelled else { return }
            self?.sleepNow()
        }
    }

    /// Stops once the playing song finishes, handled in the finish event.
    func sleepAtEndOfTrack() {
        clearSleepState()
        sleepsAtEndOfTrack = true
        // A join that is already armed would carry the album on past the end of this song without
        // ever reporting that it ended.
        disarmNext()
    }

    func cancelSleepTimer() {
        let hadEndOfTrack = sleepsAtEndOfTrack
        clearSleepState()
        // The join was held back for the sleep; put it back.
        if hadEndOfTrack, currentTrack != nil, isPlaying {
            transitionSettled = false
            prefetchNext()
        }
    }

    private func clearSleepState() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEnd = nil
        sleepsAtEndOfTrack = false
    }

    private func sleepNow() {
        // Through `pause()`, which also withdraws a song that is still loading
        // and a restart waiting on the network; paused here directly, either
        // could start music again after the timer had put it to sleep.
        pause()
        clearSleepState()
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            engine.pause()
        } else {
            resume()
        }
    }

    /// `automatic` marks the end of a song rather than a deliberate skip:
    /// repeat-one only repeats on its own, never when you press next.
    func next(automatic: Bool = false) {
        guard let index = currentIndex else { return }
        pendingAutomaticArrival = automatic

        if automatic, repeatMode == .one {
            restartCurrentTrackTask { await self.startCurrentTrack() }
            return
        }
        if index + 1 < queue.count {
            resetPosition()
            currentIndex = index + 1
            restartCurrentTrackTask { await self.startCurrentTrack() }
            return
        }
        if repeatMode.isOn, !queue.isEmpty {
            resetPosition()
            currentIndex = 0
            restartCurrentTrackTask { await self.startCurrentTrack() }
            return
        }
        // The end of the queue, and nothing set to repeat. Rather than stop,
        // carry on with music drawn from the whole of what just played.
        if smartContinueForThisQueue, !queue.isEmpty {
            restartCurrentTrackTask { await self.continueSmartly() }
            return
        }
        stop()
    }

    /// Extends the queue past its end and plays on.
    private func topUpIfRunningLow() {
        // Not while repeating: Repeat Queue takes over from Smart Continue (see
        // `next`), and a queue topped up with other music as it ran low would
        // repeat the record *and* what was added to it, never the record.
        guard smartContinueForThisQueue, !repeatMode.isOn, !isToppingUp, !topUpCameBackEmpty else { return }
        guard let index = currentIndex else { return }
        let remaining = queue.count - (index + 1)
        guard remaining <= SmartContinue.topUpWhenRemaining else { return }

        isToppingUp = true
        let epoch = queueEpoch
        topUpTask = Task { [weak self] in
            guard let self else { return }
            let result = await extendQueue()
            // A different queue has started since (`adopt` and `stop` cancel
            // this and reset the flags for the new queue): what came back
            // describes the old one and must not touch the new one's state.
            guard epoch == queueEpoch, !Task.isCancelled else { return }
            isToppingUp = false
            // Asked once and told there is nothing similar, do not ask again
            // for this queue. Without this the last five songs would each
            // send six requests that are already known to come back empty.
            if result == .empty { topUpCameBackEmpty = true }
        }
    }

    /// Bumped whenever a genuinely new queue starts (`adopt`) or the queue is emptied (`stop`) —
    /// not on reorder, remove, un-shuffle or Play Next, which leave it the same queue.
    private var queueEpoch = 0
    private var topUpTask: Task<Void, Never>?
    /// The entries Smart Continue added after the music that was asked for, so
    /// that turning repeat on can take back the ones still ahead: the queue
    /// that repeats is the one that was started, not what was added to it.
    private var continuationItems: Set<UUID> = []

    /// `failed` is not `empty`: the server was not reached, which says nothing
    /// about whether it knows anything similar, so it is not remembered for the
    /// rest of the queue.
    private enum Extension { case added, empty, stale, failed }

    /// The end of the queue with nothing added ahead of it — the backstop for
    /// when the top-up could not run or did not finish in time.
    private func continueSmartly() async {
        let epoch = queueEpoch
        let result = await extendQueue()
        // Superseded while the neighbours were being fetched: the listener
        // started something else, and this run has no business stopping it or
        // moving its index.
        guard epoch == queueEpoch, !Task.isCancelled, result != .stale else { return }
        // Whether this fetch added anything or an earlier top-up already had:
        // songs ahead are songs to play, and stopping would wipe them.
        guard let index = currentIndex, index + 1 < queue.count else {
            stop()
            return
        }
        resetPosition()
        currentIndex = index + 1
        await startCurrentTrack()
    }

    /// Fetches music like the whole of what has played and appends it.
    ///
    /// - Returns: whether anything was added.
    @discardableResult
    private func extendQueue() async -> Extension {
        guard let provider, provider.capabilities.contains(.similarItems) else { return .empty }
        let epoch = queueEpoch
        let played = queue.map(\.track)
        // Chance in both the choice of seeds and the choice from what they turn up: asked twice
        // over the same queue, this used to give the same thirty songs both times, so turning Smart
        // Continue off and on again brought back exactly what had just…
        var generator = SystemRandomNumberGenerator()
        let seeds = SmartContinue.variedSeeds(from: played, using: &generator)
        guard !seeds.isEmpty else { return .empty }

        // Each seed's neighbours, fetched together rather than in turn: six
        // requests one after another is a wait long enough to notice even
        // with a song still playing over it.
        var neighbours: [[Track]] = []
        var answered = 0
        await withTaskGroup(of: [Track]?.self) { group in
            for seed in seeds {
                group.addTask {
                    try? await provider.similarTracks(
                        to: seed.id,
                        limit: SmartContinue.neighboursPerSeed
                    )
                }
            }
            for await list in group {
                if let list { neighbours.append(list); answered += 1 }
            }
        }

        guard epoch == queueEpoch, !Task.isCancelled else { return .stale }
        // Every request failed — offline, in a tunnel, a server having a
        // moment — which is not the same as the server having nothing like it.
        guard answered > 0 else { return .failed }

        // Everything already in the queue is excluded, not just what has played: the top-up runs
        // while songs are still ahead of it, and offering one of those again would be a duplicate
        // in plain sight.
        let more = SmartContinue.blend(
            neighbours,
            excluding: Set(queue.map(\.track.id)),
            alreadyHeard: queue.map(\.track),
            varied: &generator
        )
        guard !more.isEmpty else { return .empty }

        // The listener may have turned Repeat on, or Smart Continue off, while
        // the neighbours were being fetched; those answers are not wanted now.
        guard smartContinueForThisQueue, !repeatMode.isOn else { return .stale }
        let items = more.map(QueueItem.init)
        continuationItems.formUnion(items.map(\.id))
        queue.append(contentsOf: items)
        return .added
    }

    func previous() {
        // Shuffling puts the playing song first, so the songs heard before it are no longer behind
        // it in the queue — Previous at the top of a shuffled queue went nowhere, restarting the
        // song however often it was pressed.
        if isShuffled, currentTime <= 3, currentIndex == 0,
           let at = heard.firstIndex(where: { $0.track.id == currentTrack?.id }),
           at + 1 < heard.count {
            let back = heard[at + 1]
            queue.insert(QueueItem(back.track), at: 0)
            // Stepping back is not hearing it afresh: the list keeps its order,
            // so Previous again goes on to the one before, not forward again.
            steppingBackTo = back.track.id
            resetPosition()
            currentIndex = 0
            onQueueEditedByUser?()
            restartCurrentTrackTask { await self.startCurrentTrack() }
            return
        }
        // Restart the current track unless we're within its first seconds.
        if currentTime > 3 || currentIndex == 0 || currentIndex == nil {
            // Counted so the seek bar can tell a restart from ordinary
            // progress and land at zero rather than winding back to it.
            positionJumps &+= 1
            seek(to: 0)
            return
        }
        resetPosition()
        currentIndex = (currentIndex ?? 1) - 1
        restartCurrentTrackTask { await self.startCurrentTrack() }
    }

    /// A seek can ask for further into a still-downloading track than has actually arrived — the
    /// engine clamps to what it has and reports the real landing spot through
    /// `onEvent(.progress(_:))`, which `handle(_:)` already applies to `currentTime`…
    func seek(to seconds: TimeInterval) {
        // A seek is not listening: the next tick starts a fresh stretch.
        listened.noteJump()
        engine.seek(to: seconds)
        seeks &+= 1
        updatePlaybackInfo()
    }

    /// Stops playback and empties the queue.
    func stop() {
        queueEpoch &+= 1
        topUpTask?.cancel()
        topUpTask = nil
        isToppingUp = false
        continuationItems = []
        // The fetches too.
        currentTrackTask?.cancel()
        currentTrackTask = nil
        prefetch?.cancel()
        prefetch = nil
        reportPlayback(state: .stopped)
        reportedTrack = nil
        heard = []
        playbackSchedule.reset()
        // The engine saying it has stopped is not news for the server: it was
        // just told so, and a second report went out as "paused", leaving the
        // session on its dashboard paused rather than ended.
        stoppingForNewTrack = true
        engine.stop()
        stoppingForNewTrack = false
        discardUnwantedConversion(unless: nil)
        playingFormat = nil
        isPlaying = false
        currentIndex = nil
        queue = []
        originalOrder = nil
        isShuffled = false
        currentTime = 0
        engineDuration = nil
        clearSleepState()
        resumeOnReconnect = false
        pendingAutomaticArrival = false
        nowPlayingTrackID = nil
        listened.reset()
        armedNext = nil
        preloadedFile = nil
        nextTrackFile = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Cleared as well as emptied: an app that leaves the state at
        // "playing" keeps its controls on the lock screen with nothing
        // behind them.
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        // Let go of the audio session, telling whatever we interrupted that it may carry on.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Stream selection

    /// What to ask the server for, under a policy.
    private func discardUnwantedConversion(unless id: MediaID?) {
        guard let pending = conversionToDiscard, pending != id, let mediaStore else { return }
        conversionToDiscard = nil
        Task { await mediaStore.dropConversions(for: pending) }
    }

    /// What a fetch made with these options will be, as the cache files it.
    static func variant(for options: StreamOptions) -> MediaVariant {
        guard let codec = options.transcodeTo else { return .original }
        return .converted(codec: codec.rawValue, kbps: options.maxBitRateKbps)
    }

    static func streamOptions(
        for track: Track,
        policy: TranscodePolicy = .streamingDefault
    ) -> StreamOptions {
        guard let target = policy.target(
            forCodec: track.codec ?? track.contentType,
            bitRateKbps: track.bitRateKbps,
            // Ogg Vorbis is played, not converted: the app decodes it itself.
            bundledDecoders: true
        ) else { return .original }
        return StreamOptions(
            maxBitRateKbps: policy.targetBitRateKbps,
            transcodeTo: TranscodeCodec(rawValue: target) ?? .aac
        )
    }

    /// Asks the server what became of a track it will not serve.
    private func recoverMissingItem(_ track: Track, using provider: any MusicServerProvider, token: Int) async {
        guard let albumID = track.albumID else { return }
        // Still the run this question was asked for, and still its song.
        func stale() -> Bool {
            Task.isCancelled || token != runToken || currentTrack?.id != track.id
        }
        do {
            let detail = try await provider.album(id: albumID)
            guard !stale() else { return }
            let match = detail.tracks.first {
                $0.title == track.title && $0.trackNumber == track.trackNumber
            } ?? detail.tracks.first { $0.title == track.title }

            guard let match else {
                report("\(track.title) is no longer on \(detail.album.name) — the album lists \(detail.tracks.count) other songs.")
                onStaleLibrary?()
                return
            }
            guard match.id != track.id else {
                report("The server lists \(track.title) as \(match.id.rawValue) — the same id it just refused. That is a server-side contradiction, not a stale library.")
                return
            }
            report("\(track.title) has moved to id \(match.id.rawValue) — playing it and re-reading the library.")
            if let index = currentIndex, queue.indices.contains(index) {
                queue[index].track = match
                await startCurrentTrack()
            }
            onStaleLibrary?()
        } catch {
            // A fetch cancelled by a skip is not "the album is gone", and must
            // not start a forced full sync.
            if stale() || error.isCancelledFetch { return }
            let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            report("The album is missing too (\(albumID.rawValue)): \(message)")
            onStaleLibrary?()
        }
    }

    private func report(_ message: String) {
        lastError = message
        onPlaybackProblem?(message)
    }

    /// Asks the server what a track's loudness is when the track we have does not say, and
    /// remembers the answer against that track's id.
    private func prefetchLoudnessIfNeeded(for track: Track, from provider: any MusicServerProvider) async {
        guard settingsForGain.replayGainMode.isEnabled,
              track.replayGain == nil,
              fetchedGainByTrack[track.id] == nil
        else { return }
        guard let detailed = try? await provider.track(id: track.id),
              let gain = detailed.replayGain
        else { return }
        fetchedGainByTrack[track.id] = gain
        if currentTrack?.id == track.id {
            applyReplayGain(for: currentTrack, settings: settingsForGain)
        }
    }

    /// The streaming policy for the connection in use — the wi-fi one at home, the mobile one on a
    /// train.
    private var streamPolicy: TranscodePolicy {
        settingsForGain.streamingTranscode(expensiveNetwork: streamsWithMobilePolicy)
    }

    /// Whether the copy already on the phone is the one to play, rather than asking the server for
    /// a stream.
    private func shouldPlayDownloadedCopy(of track: Track) -> Bool {
        TranscodePolicy.prefersDownloadedCopy(
            isOffline: isOffline || serverUnreachable,
            downloadIsConverted: downloads?.downloadedConversion(for: track.id) != nil,
            streamWouldConvert: Self.streamOptions(for: track, policy: streamPolicy).transcodeTo != nil
        )
    }

    /// Whether this phone is reaching the server somewhere other than home.
    /// Set by the app model, which knows which address the connection is
    /// using; a closure so it is read as each song starts, not remembered.
    @ObservationIgnored var isAwayFromHome: @MainActor () -> Bool = { false }

    /// Whether streaming follows the mobile-data policy: on cellular or a hotspot, or on Wi-Fi away
    /// from the server's own network when `awayWiFiUsesMobilePolicy` is on.
    var streamsWithMobilePolicy: Bool {
        network.isExpensive || (settingsForGain.awayWiFiUsesMobilePolicy && isAwayFromHome())
    }

    /// - Parameter keepingRetryCount: set only when this *is* the retry, so
    ///   a dropped connection cannot start a loop that never gives up.
    private func startCurrentTrack(keepingRetryCount: Bool = false) async {
        if !keepingRetryCount {
            networkRetries = 0
            runToken += 1
            resumeOnReconnect = false
        }
        // Captured once, up front: a retry re-enters this same function for the same attempt and
        // must see the token it was given at the top of the very first call, not a fresh read that
        // could only ever match itself.
        let myToken = runToken
        guard let track = currentTrack else { return }
        if !keepingRetryCount {
            arrivedAutomatically = pendingAutomaticArrival
            pendingAutomaticArrival = false
            if !arrivedAutomatically { consecutiveSkips = 0 }
            loadingToken = myToken
            wantsPlaybackWhenLoaded = true
        }
        // The load is over, one way or another, when this returns. Only the
        // run that owns the token clears it: a superseded run finishing late
        // must not mark the newer run's load as done.
        defer { if loadingToken == myToken { loadingToken = nil } }
        TranscodeLog.record("startCurrentTrack: \(track.title) (\(keepingRetryCount ? "retry \(networkRetries)" : "new track")), token \(myToken)")
        // Only for a genuinely new current track — a retry after a dropped connection re-enters
        // here for the *same* track, and a listener hearing this callback (a DJ counting Journey's
        // steps, in particular) needs to know a song actually started, not…
        if !keepingRetryCount {
            onTrackStarted?(track)
            if let index = currentIndex, queue.indices.contains(index) {
                noteInHistory(queue[index])
            }
        }
        // The song that was playing is over as far as the server is concerned, and this is where to
        // say so: `currentTrack` has moved on by the time anything else runs, so the report has to
        // be built from what it *was*.
        if !keepingRetryCount { reportStoppedForPreviousTrack(newTrack: track) }
        // Every way of reaching a new song comes through here, so this is the
        // one place the queue needs checking for room at the end.
        topUpIfRunningLow()
        guard let provider else {
            // No connection: say so rather than appearing to do nothing.
            // Browsing keeps working from the local index, so this is
            // reachable with a full-looking library on screen.
            lastError = String(localized: "Not connected to your server — check Settings.")
            onPlaybackProblem?(lastError ?? "")
            isPlaying = false
            needsReload = true
            return
        }
        lastError = nil
        scrobbleSubmitted = false
        listened.reset()
        hasTriedRecovery = false
        // The badge names what is playing, and until this track's file is
        // opened nothing is: fall back to the prediction rather than showing
        // the previous song's format over a song still loading.
        playingFormat = nil
        // "Sleep at the end of this song" named the song that was playing.
        // A deliberate jump elsewhere leaves it pointing at nothing, and it
        // would stop the next song instead.
        if !keepingRetryCount, sleepsAtEndOfTrack { clearSleepState() }
        // A stall belonged to the song that stalled.
        stalledSince = nil
        isBuffering = false
        currentTime = 0
        engineDuration = nil
        configureAudioSessionIfNeeded()
        // Applied immediately, from whatever is already known — the track's own tag, or a loudness
        // already cached for it from an earlier play.
        applyReplayGain(for: track, settings: settingsForGain)
        Task { [weak self] in
            await self?.prefetchLoudnessIfNeeded(for: track, from: provider)
        }

        // Silence what is playing before going to fetch the next file.
        stoppingForNewTrack = true
        engine.stop()
        stoppingForNewTrack = false
        // Stopping empties the engine, joins included.
        armedNext = nil
        preloadedFile = nil
        // Lock screen, AirPods and CarPlay name this song now, not when its file has finished
        // arriving — which on a slow link or a conversion is tens of seconds later, during which
        // they kept showing the previous song's title and art over the new…
        publishNowPlaying(track)
        // Stopping empties the engine, and an empty engine ignores `play()`.
        needsReload = true
        discardUnwantedConversion(unless: track.id)

        do {
            // A download is asked about first, and answers without the network at all: no stream
            // request, no cache lookup, nothing to fail if the server is not there.
            if let kept = downloads?.fileURL(for: track.id), shouldPlayDownloadedCopy(of: track) {
                await playLocalFile(kept, track: track, token: myToken)
                return
            }

            // What the policy would ask for, and then what the disk already has to say about it: a
            // file here costs no data, so converting to save data is beside the point once the
            // original is cached.
            TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — checking local files")
            let local = await mediaStore?.localFiles(for: track.id)
            TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — local files checked")
            // A newer run may have started while that was in flight — see `runToken`.
            guard myToken == runToken else { return }
            var options = Self.streamOptions(for: track, policy: streamPolicy)
            if options.transcodeTo != nil, local?.hasOriginal == true,
               NativeAudioSupport.canDecode(track.codec ?? track.contentType, includingBundled: true) {
                options = .original
            }
            let variant = Self.variant(for: options)

            // The cache, before the server rather than after it.
            if let cached = local?.cached(variant: variant) {
                // The lookup is async — a skip while it was in flight moves `currentTrack` on, and
                // this answer belongs to the track that was current when it was asked, not the one
                // now.
                guard myToken == runToken, currentTrack?.id == track.id else { return }
                await playLocalFile(cached, track: track, token: myToken)
                return
            }

            TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — asking server for a stream source")
            let source = try await provider.streamSource(for: track.id, options: options)
            TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — stream source received")
            // Another run may have taken over while that round trip was in
            // flight, same as above.
            guard myToken == runToken else { return }
            let authenticated = proxySessions?.authenticating(source.request) ?? source.request

            if let mediaStore {
                // The streaming engine plays local files, so the fetch runs
                // through the app's transport — which is what finally makes
                // pinning, mTLS and the proxy cookie apply to audio.
                let alreadyCached = await mediaStore.isCached(
                    track.id,
                    request: authenticated,
                    variant: variant
                )
                // Checked *before* the mutation this time, not after: fused into the same statement
                // as the await, this was written the moment a stale run woke up rather than the
                // moment it found out it was stale, so it stuck the spinner on over a track that…
                guard myToken == runToken else { return }
                isBuffering = !alreadyCached
                // Only this run's own spinner: a superseded run unwinding late
                // used to wipe the spinner of the song that replaced it.
                defer { if myToken == runToken { isBuffering = false } }

                // A conversion is assembled piece by piece, and waiting for the last piece would
                // mean waiting for the transcoder to reach the end of the track.
                growToken &+= 1
                growingFile = nil
                let token = growToken
                let started: @Sendable (URL) -> Void = { [weak self] partial in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.runToken == myToken,
                              self.growToken == token,
                              self.currentTrack?.id == track.id
                        else { return }
                        self.growingFile = partial
                        self.isBuffering = false
                        // Before the load, which reports the format it opened and has the badge
                        // look this file up.
                        self.currentTrackFile = partial
                        self.engine.loadGrowing(
                            partial,
                            expectedDuration: track.duration,
                            autoplay: self.wantsPlaybackWhenLoaded,
                            // An original in FLAC, ALAC, AIFF or CAF reports its whole length from
                            // its header while most of it is still on its way: the engine reads
                            // what it schedules instead of trusting the length.
                            declaresLength: GrowingFile.declaresLength(
                                head: AudioResponseCheck.head(ofFileAt: partial),
                                isConversion: !variant.isOriginal
                            )
                        )
                        self.needsReload = false
                        self.updatePlaybackInfo()
                    }
                }
                // Somebody is waiting to hear this.
                var holdingDownloads = false
                defer {
                    if holdingDownloads {
                        fetchesForPlayback -= 1
                        // Only the last one out lets the downloads go: another
                        // run may still be waiting on a conversion of its own.
                        if fetchesForPlayback == 0 {
                            downloads?.playbackFinishedFetching()
                        }
                    }
                }
                if !variant.isOriginal {
                    fetchesForPlayback += 1
                    holdingDownloads = true
                    TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — yielding to playback")
                    await downloads?.yieldToPlayback()
                    TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — yielded")
                    guard myToken == runToken else { return }
                } else if !alreadyCached {
                    // An original on its way is the same demand on the same connection: with
                    // downloads carrying six files at once, the song somebody tapped came back as
                    // its first few seconds and then "the network connection was lost".
                    fetchesForPlayback += 1
                    holdingDownloads = true
                    TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — holding downloads for the original")
                    await downloads?.yieldToPlayback(cancellingConversions: false)
                    guard myToken == runToken else { return }
                }
                TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — asking the store for the file")
                let file = try await mediaStore.file(
                    for: track.id,
                    request: authenticated,
                    variant: variant,
                    // The song the listener chose: whatever else is
                    // arriving gives way to it.
                    priority: .playingNow,
                    // Whatever the kind.
                    expectedDuration: track.duration,
                    bitRateKbps: track.bitRateKbps,
                    // A file the app decodes itself is read whole, and cannot
                    // be played as it arrives.
                    onPartial: Self.isBundledDecoded(track) ? nil : started
                )
                TranscodeLog.record("startCurrentTrack: \(track.title) token \(myToken) — store returned the file")
                // The full-quality file retires the conversions of the same song: they existed only
                // because it had not arrived yet.
                if variant.isOriginal {
                    Task { await mediaStore.dropConversions(for: track.id) }
                } else {
                    // See the read-ahead: the file is here, so the session that produced it is
                    // finished with.
                    TranscodeLog.record("endPlayback: \(track.title) (current track)")
                    Task { await provider.endPlayback(for: track.id) }
                    if !settingsForGain.keepsConvertedFiles {
                        // Kept only for as long as it is being played, then gone — dropped on the
                        // way *out* of the track rather than here, where the file is still in the
                        // engine's hands.
                        if myToken == runToken {
                            conversionToDiscard = track.id
                        }
                    }
                }
                // `runToken` as well as the id: a revisit of the very same
                // song passes the id check on its own, and that is exactly
                // the pattern a fast skip back and forth produces.
                guard myToken == runToken, currentTrack?.id == track.id else { return }
                // Ogg Vorbis, which iOS cannot read, is decoded as it plays.
                if VorbisFile.isVorbis(at: file) {
                    await playLocalFile(file, track: track, token: myToken)
                    return
                }
                let engineURL = file
                // Past this point the fetch is done, so no partial callback
                // still in flight may take the engine over.
                growToken &+= 1
                if growingFile != nil {
                    growingFile = nil
                    engine.growthFinished(at: file)
                    // A gapless join could not be armed while this track was
                    // still arriving; now that it is whole, the next one can
                    // go on behind it.
                    if let index = currentIndex, queue.indices.contains(index + 1),
                       let next = nextTrackFile(for: queue[index + 1]) {
                        armNext(queue[index + 1], file: next)
                    }
                } else {
                    engineFailedLoad = false
                    // Set before the load, which reports the format it opened
                    // and has the badge look this file up.
                    currentTrackFile = engineURL
                    engine.load(URLRequest(url: engineURL), autoplay: wantsPlaybackWhenLoaded)
                    if engineFailedLoad {
                        needsReload = true
                        return
                    }
                }
                needsReload = false
                // Kept so this track's ending can be measured when the join
                // to the next one comes to be decided.
                currentTrackFile = engineURL
                warmWaveform(for: track.id, file: engineURL)
            } else {
                engineFailedLoad = false
                engine.load(authenticated, autoplay: wantsPlaybackWhenLoaded)
                needsReload = engineFailedLoad
                if engineFailedLoad { return }
            }
            prefetchNext()
            publishNowPlaying(track)
            // "Now playing" report; failures must never interrupt playback.
            if !isOffline {
                Task {
                    try? await provider.scrobble(id: track.id, at: Date(), submission: false)
                }
            }
        } catch {
            // Cut off because the listener tapped something else: the song this fetch was for is
            // not the song any more, and the one that is has its own fetch under way.
            if myToken != runToken || currentTrack?.id != track.id { return }
            // The fetch failed, but the engine is already playing what arrived before it did.
            let underlyingError: any Error
            if case .cutOff(_, let underlying)? = error as? MediaFileStore.Refusal {
                underlyingError = underlying
            } else {
                underlyingError = error
            }

            // Whether a second go could cure this, and whether there is one
            // left. The same test the retries below make.
            let worthRetrying = Self.wasCutOff(underlyingError)
                || (underlyingError as? ProviderError)?.isWorthRetrying == true
            let mayRetry = worthRetrying && networkRetries < Self.networkRetryLimit

            if case .cutOff(let partial, _)? = error as? MediaFileStore.Refusal,
               growingFile != nil {
                // Measured before the engine is told anything: at the very start, with next to
                // nothing heard, the song is fetched again rather than played out as the few
                // seconds that arrived — see `CutOffPlan`.
                let arrivedAlready = MediaFileStore.arrivedDuration(of: partial)
                if CutOffPlan.action(
                    heard: currentTime,
                    arrived: arrivedAlready,
                    expected: track.duration,
                    canRetry: mayRetry
                ) == .fetchAgain {
                    TranscodeLog.record(
                        "startCurrentTrack: \(track.title) cut off \(String(format: "%.1f", currentTime))s in, "
                            + "\(arrivedAlready.map { "\(Int($0))s" } ?? "?") arrived — "
                            + "\(TranscodeLog.describe(underlyingError)) — fetching it again"
                    )
                    // This attempt's file is no longer the one being grown, and
                    // nothing it still has in flight may touch the engine.
                    growToken &+= 1
                    growingFile = nil
                } else {
                    TranscodeLog.record(
                        "startCurrentTrack: \(track.title) cut off \(String(format: "%.1f", currentTime))s in — "
                            + "\(TranscodeLog.describe(underlyingError)) — playing out what arrived"
                    )
                    growingFile = nil
                    // What could be read, where the file declares a length it
                    // does not have.
                    let readable = engine.growthCutOff(at: partial)
                    needsReload = false
                    currentTrackFile = partial
                    // The song after this one is still wanted when this one ends early.
                    prefetchNext()
                    // Only if something is actually missing.
                    let arrived = readable ?? MediaFileStore.arrivedDuration(of: partial)
                    let expected = track.duration
                    if let arrived, let expected, expected > 0,
                       arrived >= expected - max(1, expected * 0.02) {
                        TranscodeLog.record(
                            "startCurrentTrack: \(track.title) cut off on the last of it — "
                                + "\(Int(arrived))s of \(Int(expected))s arrived, saying nothing"
                        )
                        return
                    }
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    lastError = "\(track.title): \(message)"
                    onPlaybackProblem?(lastError ?? "")
                    return
                }
            }
            // A blip is not a failure.
            if Self.wasCutOff(underlyingError) || (underlyingError as? ProviderError)?.isWorthRetrying == true,
               networkRetries < Self.networkRetryLimit {
                networkRetries += 1
                let wait = Self.networkRetryBackoff[networkRetries - 1]
                TranscodeLog.record("startCurrentTrack: \(track.title) — \(TranscodeLog.describe(underlyingError)) — retry \(networkRetries) in \(wait)s")
                try? await Task.sleep(for: .seconds(wait))
                // `runToken` again: this sleep is exactly the window a fast skip back and forth
                // lands in, and the recursive call below silences the engine at its own top — see
                // `engine.stop()` near the start of this function.
                guard myToken == runToken, currentTrack?.id == track.id else { return }
                await startCurrentTrack(keepingRetryCount: true)
                return
            }

            // Named, because "could not find the requested item" on its own
            // says nothing about *which* item and sent one diagnosis down the
            // wrong path already.
            var message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            message = "\(track.title): \(message)"
            lastError = message
            needsReload = true
            resumeOnReconnect = Self.wasCutOff(underlyingError)
                || (underlyingError as? ProviderError)?.isWorthRetrying == true
            TranscodeLog.record("startCurrentTrack: giving up on \(track.title) — \(TranscodeLog.describe(underlyingError))")
            onPlaybackProblem?(message)
            // A 404 for an id that came out of our own index is worth one question back to the
            // server: ask the album what it holds now.
            if case .serverError(let code, _, _) = error as? ProviderError ?? .notFound,
               code == 404,
               !hasTriedRecovery
            {
                hasTriedRecovery = true
                await recoverMissingItem(track, using: provider, token: myToken)
            }
            skipBadTrackIfUnattended(track, networkClass: Self.wasCutOff(underlyingError)
                || (underlyingError as? ProviderError)?.isWorthRetrying == true, token: myToken)
        }
    }

    /// Carries on to the next song after one that cannot be played, when
    /// nobody chose it — see `BadTrackPolicy`. The problem has already been
    /// posted as a banner; this only stops one bad entry ending the queue.
    private func skipBadTrackIfUnattended(_ track: Track, networkClass: Bool, token: Int) {
        // Not if the recovery above found the song under a new id and started
        // it, or the listener moved on meanwhile.
        guard token == runToken, currentTrack?.id == track.id, needsReload else { return }
        let hasNext = (currentIndex ?? 0) + 1 < queue.count
        guard BadTrackPolicy.shouldSkip(
            arrivedAutomatically: arrivedAutomatically,
            isNetworkClass: networkClass,
            isOffline: isOffline,
            hasNextInQueue: hasNext,
            consecutiveSkips: consecutiveSkips,
            repeatingOne: repeatMode == .one
        ) else { return }
        consecutiveSkips += 1
        TranscodeLog.record("skipping \(track.title): unplayable (\(consecutiveSkips) in a row)")
        next(automatic: true)
    }

    // MARK: Engine events

    private func handle(_ event: AudioEngineEvent) {
        switch event {
        case .readyToPlay(let duration):
            // A non-positive duration is "unknown". Believing a zero here made
            // the seek bar, the settle step and the scrobble halfway mark all
            // work from a track that was zero seconds long.
            if let duration, duration > 0 {
                engineDuration = duration
            }
            updatePlaybackInfo()
        case .loadedFormat(let format):
            // A decoded Ogg Vorbis copy is plain PCM; the badge is told what
            // the original was.
            if var format, let file = currentTrackFile, let source = decodedSources[file] {
                format.codec = "VORBIS"
                format.bitDepth = nil
                format.sampleRate = source.sampleRate
                format.bitRateKbps = source.bitRateKbps
                playingFormat = format
            } else {
                playingFormat = format
            }
        case .progress(let time):
            // Moving again. The engine reports the position it has audio
            // for, so a position that has advanced is proof the wait is
            // over — where it has not, the stall is still on.
            var stallCleared = false
            if isBuffering, stalledSince != nil, time > currentTime {
                stalledSince = nil
                isBuffering = false
                stallCleared = true
            }
            // Listening time and the last known position for the stopped
            // report, before `currentTime` moves.
            listened.tick(position: time)
            lastProgress = (currentTrack?.id, time, duration)
            if time >= 1 { consecutiveSkips = 0 }
            currentTime = time
            // The lock screen extrapolates from the last snapshot, so it has
            // to hear that a stall ended as well as that it began.
            if stallCleared { updatePlaybackInfo() }
            // A seek or a rebuild throws the engine's join away (an overlap
            // cannot be re-armed by the engine on its own). Notice, so it is
            // decided again while there is still room.
            if armedNext != nil, !engine.hasArmedNext { engineDroppedArmedNext() }
            reportPlayback()
            submitScrobbleIfDue()
            settleTransitionIfDue(at: time)
        case .rateChanged(let rate):
            isPlaying = rate > 0
            // Not when this is only the engine being emptied for the song that has just replaced
            // the last: `reportedTrack` has already moved, and a "paused" report for a song that
            // has not started sent the server a state change on every explicit skip.
            if !stoppingForNewTrack { reportPlayback() }
            updatePlaybackInfo()
        case .stalled:
            // The engine has run out of audio on a song still arriving.
            stalledSince = stalledSince ?? Date()
            if !isBuffering {
                isBuffering = true
                // The position freezes here; the lock screen would go on
                // counting.
                updatePlaybackInfo()
            }
        case .advancedToPreloaded:
            // The audio has already moved on, so the queue follows it rather
            // than starting anything: loading here would restart the track
            // that is mid-first-bar.
            submitScrobbleIfDue(force: true)
            scrobbleSubmitted = false
            listened.reset()
            arrivedAutomatically = true
            if let index = currentIndex {
                // Follow the audio: the entry that was armed is the one now playing, wherever the
                // queue has since put it.
                let armed = armedNext
                armedNext = nil
                resetPosition()
                if let armed {
                    currentIndex = QueueJoin.adopt(&queue, currentIndex: index, armed: armed)
                    topUpIfRunningLow()
                } else if index + 1 < queue.count {
                    currentIndex = index + 1
                    // A gapless join never goes through `startCurrentTrack`, so
                    // without this the queue would only ever be topped up on the
                    // joins that were not seamless.
                    topUpIfRunningLow()
                }
            }
            currentTime = 0
            // What the engine is now playing is what was preloaded behind the last track — a
            // gapless advance never goes through `startCurrentTrack`, so nothing else would say so,
            // and the next join would be measured from the song before last.
            currentTrackFile = preloadedFile
            preloadedFile = nil
            currentTime = 0
            if let track = currentTrack {
                // A seamless join never passes through `startCurrentTrack`, so without this the
                // server is never told the song before it ended — and a whole album played
                // gaplessly reports one song starting and nothing ever finishing.
                reportStoppedForPreviousTrack(newTrack: track)
                if let index = currentIndex, queue.indices.contains(index) {
                    noteInHistory(queue[index])
                }
                publishNowPlaying(track)
                onTrackStarted?(track)
                Task { [provider] in
                    try? await provider?.scrobble(id: track.id, at: Date(), submission: false)
                }
                applyReplayGain(for: track, settings: settingsForGain)
                // A gapless join or a smart-crossfade handover never goes through
                // `startCurrentTrack`, so without this a track reached this way whose own listing
                // carries no gain (every Plex track) was never fetched for itself —
                // `applyReplayGain` just above…
                if let provider {
                    Task { [weak self] in
                        await self?.prefetchLoudnessIfNeeded(for: track, from: provider)
                    }
                }
            }
            // "Sleep at the end of this song": the join was armed before the sleep was set, or
            // could not be taken back, and carried on into the next song without ever reporting the
            // end.
            if sleepsAtEndOfTrack {
                clearSleepState()
                engine.pause()
                isPlaying = false
            }
            prefetchNext()
        case .didFinish:
            submitScrobbleIfDue(force: true)
            // The engine ended with nothing behind it, so nothing is armed.
            armedNext = nil
            preloadedFile = nil
            if sleepsAtEndOfTrack {
                clearSleepState()
                engine.pause()
                isPlaying = false
            } else if hasNext {
                next(automatic: true)
            } else {
                stop()
            }
        case .failed(let message):
            TranscodeLog.record("engine failed: \(message)")
            lastError = message
            isPlaying = false
            // Whatever the engine was holding is gone, so there is nothing
            // for the play button to resume. Say so, and it will fetch the
            // song again instead.
            needsReload = true
            engineFailedLoad = true
            onPlaybackProblem?(message)
            if let track = currentTrack {
                // A file that will not open is the song's problem, not the
                // connection's. After a hop, so the load that raised this has
                // finished unwinding before the queue moves under it.
                let token = runToken
                Task { @MainActor [weak self] in
                    self?.skipBadTrackIfUnattended(track, networkClass: false, token: token)
                }
            }
        }
    }

    /// Tells the server what is playing, for its own dashboard.
    private func reportStoppedForPreviousTrack(newTrack: Track) {
        guard let previous = reportedTrack, previous.id != newTrack.id,
              let provider, !isOffline
        else {
            reportedTrack = newTrack
            return
        }
        reportedTrack = newTrack
        // Where the previous song stopped, as last seen. `currentTime` and
        // `duration` describe the new song by now: the stopped report went out
        // at position 0 with the wrong length for every skip and advance.
        let known = lastProgress?.id == previous.id ? lastProgress : nil
        let report = PlaybackReport(
            id: previous.id,
            state: .stopped,
            position: known?.position ?? currentTime,
            duration: known?.duration ?? duration
        )
        guard playbackSchedule.shouldSend(report, now: Date()) else { return }
        guard TranscodeDebugSettings.reportsPositionToPlex else { return }
        TranscodeLog.record("timeline report: stopped \(previous.title)")
        Task { try? await provider.report(report) }
    }

    private func reportPlayback(state: PlaybackReport.State? = nil) {
        guard let track = currentTrack, let provider, !isOffline else { return }
        let report = PlaybackReport(
            id: track.id,
            state: state ?? (isPlaying ? .playing : .paused),
            position: currentTime,
            duration: duration
        )
        guard playbackSchedule.shouldSend(report, now: Date()) else { return }
        guard TranscodeDebugSettings.reportsPositionToPlex else {
            TranscodeLog.record("timeline report suppressed (debug switch off): \(report.state.rawValue) at \(Int(report.position))s")
            return
        }
        TranscodeLog.record("timeline report: \(report.state.rawValue) at \(Int(report.position))s")
        Task { try? await provider.report(report) }
    }

    private func submitScrobbleIfDue(force: Bool = false) {
        guard !scrobbleSubmitted, let track = currentTrack else { return }
        // Counted from time actually listened, not from where the play head is: seeking past the
        // middle used to count as a play.
        if force {
            guard listened.countsAsPlayed(duration: duration) else { return }
        } else {
            guard let duration, duration > 0, listened.countsAsPlayed(duration: duration) else { return }
        }
        // Above the provider check on purpose: what was put on is worth remembering whether or not
        // there is a server to tell about it.
        recordSourceIfDue(at: Date())
        guard provider != nil else { return }
        scrobbleSubmitted = true
        try? libraryIndex?.mirrorPlay(trackID: track.id)
        onPlaySubmitted?(track.id, Date())
    }

    /// Writes what this queue was started from into Recently Played, once.
    private func recordSourceIfDue(at date: Date) {
        guard !sourceRecorded, let source = queueOrigin.playedSource else { return }
        sourceRecorded = true
        onSourcePlayed?(source, date)
    }

    // MARK: System integration

    private func configureAudioSessionIfNeeded() {
        try? configureAudioSession()
    }

    /// The throwing entry point Remote Control's target session calls before starting sound from
    /// the background: the same session setup as `configureAudioSessionIfNeeded()`, without the
    /// `try?` swallowing a failure it needs to see, so it can…
    func prepareSessionForRemoteStart() throws {
        try configureAudioSession()
    }

    private func configureAudioSession() throws {
        guard !sessionConfigured else {
            try AVAudioSession.sharedInstance().setActive(true)
            return
        }
        sessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        // Asked for before the session is activated, because afterwards it is a request the system
        // is free to ignore.
        try session.setPreferredIOBufferDuration(0.023)
        try session.setActive(true)
    }

    /// Nonisolated so the handler closures carry no MainActor assumption —
    /// the system may invoke them off-main, and Swift 6 traps on isolation
    /// mismatches. Each handler hops to the main actor explicitly.
    private nonisolated static func registerRemoteCommands(for player: PlayerModel) {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in player?.seek(to: position) }
            return .success
        }
    }

    private func publishNowPlaying(_ track: Track) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
        ]
        if let artist = track.artistName {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = track.albumName {
            // The year beside the record's name, where it is known.
            let year = track.year ?? albumYear(for: track)
            info[MPMediaItemPropertyAlbumTitle] = year.map { "\(album) (\($0))" } ?? album
        }
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        let artworkID = track.artwork
        let bucket = 640
        // Same sleeve as the track just playing (typically the next song on
        // the same album) — hand CarPlay the exact `MPMediaItemArtwork` it
        // already has rather than a new one, so it has no reason to flash.
        if let artworkID, let published = publishedArtwork,
           published.id == artworkID, published.bucket == bucket {
            info[MPMediaItemPropertyArtwork] = published.artwork
        } else if let artworkID, let artwork,
                  let cached = artwork.cachedImage(for: artworkID, bucket: bucket) {
            // A different sleeve, but already decoded in memory — set it
            // synchronously instead of leaving artwork blank for a frame
            // while the async path below re-fetches what is already here.
            let systemArtwork = Self.makeSystemArtwork(cached)
            info[MPMediaItemPropertyArtwork] = systemArtwork
            publishedArtwork = (artworkID, bucket, systemArtwork)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        nowPlayingTrackID = track.id

        guard let artworkID, let artwork else { return }
        if let published = publishedArtwork, published.id == artworkID, published.bucket == bucket {
            return // already published above, from the cache or the previous track
        }
        Task {
            guard let image = await artwork.image(for: artworkID, bucket: bucket),
                  self.currentTrack?.id == track.id
            else { return }
            let systemArtwork = Self.makeSystemArtwork(image)
            var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            current[MPMediaItemPropertyArtwork] = systemArtwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            publishedArtwork = (artworkID, bucket, systemArtwork)
        }
    }

    /// The record's year, read from the library where the song does not
    /// carry one.
    private func albumYear(for track: Track) -> Int? {
        guard let albumID = track.albumID else { return nil }
        return (try? libraryIndex?.album(id: albumID))??.year
    }

    /// Deliberately nonisolated: MediaPlayer invokes the request handler on its own background
    /// queue, so the closure must not be formed in a MainActor context — Swift 6's runtime
    /// isolation check would trap (this exact crash was captured on device…
    private nonisolated static func makeSystemArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { requested in
            // The handler is contracted to return an image of the size it was asked for.
            guard requested != image.size else { return image }
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: requested, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: requested))
            }
        }
    }

    private func updatePlaybackInfo() {
        // The dictionary edited below must belong to the song that is current.
        if let track = currentTrack, nowPlayingTrackID != track.id {
            publishNowPlaying(track)
            return
        }
        let center = MPNowPlayingInfoCenter.default()
        var info = center.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        // A stall freezes the position but not the lock screen's clock, which
        // runs on from the last snapshot at the rate it was given.
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying && !isBuffering ? 1.0 : 0.0
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        center.nowPlayingInfo = info
        // The rate in the dictionary is not enough.
        center.playbackState = currentTrack == nil ? .stopped : (isPlaying ? .playing : .paused)
    }
}
