import Foundation
import AVFoundation
import CryptoKit
import Synchronization
import PleviAudio
import PleviDomain
import PleviTransport

/// Fetches media through the app's own transport and keeps it on disk.
actor MediaFileStore {
    private let directory: URL
    /// Replaced by `update(...)`: one store serves a library for as long as the
    /// app runs, however often the connection to it is set up again.
    private var transport: any HTTPTransport
    /// Runs per track so two requests for the same one share a single fetch — which happens the
    /// moment the player prefetches what it is already loading.
    private var inFlight: [String: Transfer] = [:]

    /// Hands the first playable piece of a fetch to everyone waiting on it.
    private final class PartialRelay: Sendable {
        private struct State {
            var announced: URL?
            var observers: [@Sendable (URL) -> Void] = []
            /// Whether an announcement has actually reached an observer — the one thing that means
            /// the engine may be holding this file open.
            var observed = false
        }
        private let state = Mutex(State())

        func announce(_ url: URL) {
            let waiting = state.withLock { state -> [@Sendable (URL) -> Void] in
                guard state.announced == nil else { return [] }
                state.announced = url
                state.observed = state.observed || !state.observers.isEmpty
                defer { state.observers = [] }
                return state.observers
            }
            for observer in waiting { observer(url) }
        }

        func observe(_ observer: @escaping @Sendable (URL) -> Void) {
            let already = state.withLock { state -> URL? in
                if let announced = state.announced {
                    state.observed = true
                    return announced
                }
                state.observers.append(observer)
                return nil
            }
            if let already { observer(already) }
        }

        /// Whether the file this fetch produces really was handed to
        /// somebody — see `observed` above.
        var wasObserved: Bool { state.withLock { $0.observed } }
    }

    /// A fetch in progress, and whose it is.
    private struct Transfer {
        let id: MediaID
        /// The name the finished file will have; its scratch file is this
        /// plus `.partial`.
        let key: String
        let priority: Priority
        let task: Task<URL, any Error>
        /// Where this transfer's playable prefix is announced, so a caller
        /// that joins it late still hears about it.
        let relay: PartialRelay
        /// When bytes last arrived, so the watchdog can tell a slow transfer
        /// from a silent one. Shared by everyone who joins the transfer.
        let activity: ActivityClock
        /// Everyone waiting on it, so it can be called off when the last one
        /// goes — see `TransferWaiters`.
        let waiters: TransferWaiters
        /// Whether the server is making this as it goes, and so holds a
        /// session that has to be ended if the transfer is abandoned.
        let isConversion: Bool
        /// Tells this transfer apart from a later one under the same name,
        /// so a stale entry is only ever removed by the one that made it.
        let token = UUID()
    }

    /// Who is asking — and so who gives way when two want the one lane.
    enum Priority: Sendable {
        /// The song the listener chose. Whatever else is arriving is cut off.
        case playingNow
        /// A guess at what comes next. Waits its turn, and gives way to a tap.
        case readAhead
    }

    /// What a tap is clearing the lane for, and which tap it is — from the moment it starts
    /// clearing until its own transfer is under way.
    private struct Claim: Equatable {
        let key: String
        let tap: Int
    }
    private var claimedFor: Claim?
    /// Read-aheads waiting for a claim to be settled.
    private var claimWaiters: [CheckedContinuation<Void, Never>] = []
    /// Counts taps, so one that was waiting can tell a newer one has come
    /// and stand down rather than cut off the song the listener chose last.
    private var tapsSeen = 0

    /// Tells the server that a conversion cut off part-way is finished with.
    private var releaseConversion: (@Sendable (MediaID) async -> Void)?

    /// How much may be kept, in bytes. Set from the user's choice — a
    /// lossless track is 25–35 MB, so the old fixed 600 MB held about twenty
    /// songs and evicted an album while you were still listening to it.
    private var cacheLimit: Int64

    static let defaultLimit: Int64 = 4 * 1024 * 1024 * 1024

    /// Tracks that are playing or about to, as the prefixes their files share.
    private var protectedPrefixes: Set<String> = []
    private var inUseSequence = 0
    /// Prefixes whose converted files were spared by `dropAllConversions`
    /// because the track was in use. They go when it stops being.
    private var conversionsToDrop: Set<String> = []
    /// When each file was last played in this process.
    private var lastPlayed: [String: Date] = [:]

    /// Where every library's play cache folder lives. Each store keeps its
    /// own folder beneath it; the limit, the usage shown and Clear are the
    /// app's, so they are worked out over this whole folder — see `CacheTree`.
    static var rootDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Media", directoryHint: .isDirectory)
    }

    /// Nothing is swept here.
    init(
        transport: any HTTPTransport,
        serverID: ServerID,
        limit: Int64 = MediaFileStore.defaultLimit,
        releaseConversion: (@Sendable (MediaID) async -> Void)? = nil
    ) {
        self.directory = Self.rootDirectory
            .appending(path: serverID.rawValue.uuidString, directoryHint: .isDirectory)
        self.transport = transport
        self.cacheLimit = limit
        self.releaseConversion = releaseConversion
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Points the store at a fresh connection to the same library, leaving what it is doing alone.
    func update(
        transport: any HTTPTransport,
        limit: Int64,
        releaseConversion: (@Sendable (MediaID) async -> Void)?
    ) {
        self.transport = transport
        self.releaseConversion = releaseConversion
        setLimit(limit)
    }

    /// Directories already swept by this process. Keyed by path, not a bare
    /// flag: each library has a directory of its own, and a flag would have
    /// skipped every library but the first opened.
    private static let sweptDirectories = Mutex<Set<String>>([])

    /// Clears out what a previous launch left behind, once per directory per process: half-written
    /// files, files from before names were stable, and any "song" that is really an error page an
    /// earlier version filed.
    func sweepOncePerLaunch() {
        let first = Self.sweptDirectories.withLock { $0.insert(directory.path).inserted }
        guard first else { return }
        Self.removeUnreadableFiles(in: directory)
    }

    /// How much of a plain file has to be on disk before it is worth starting.
    private static let playableBytes: Int64 = 1_500_000

    /// The local file for a track, fetching it if it is not already here.
    enum Refusal: LocalizedError {
        case tooShort(arrived: TimeInterval, expected: TimeInterval)
        /// The fetch failed, but the engine is already playing what arrived,
        /// so the file is still here — see `file(for:...)`.
        case cutOff(partial: URL, underlying: any Error)
        /// A fetch someone was waiting to hear produced nothing at all for
        /// too long — see `playingNowWatchdogSeconds`.
        case stalled
        /// A 2xx that was not a song: a server's error, a sign-in page, an
        /// empty body. Refused before it is filed under the song's name, where
        /// it would have been played from the cache, and failed, ever after.
        case notAudio(NotAudioReason)

        var errorDescription: String? {
            switch self {
            case .tooShort(let arrived, let expected):
                "The server sent \(Int(arrived.rounded())) seconds of a "
                    + "\(Int(expected.rounded()))-second track."
            case .cutOff(_, let underlying):
                (underlying as? LocalizedError)?.errorDescription
                    ?? underlying.localizedDescription
            case .stalled:
                "That took too long to answer."
            case .notAudio:
                "The server answered with an error instead of the song."
            }
        }
    }

    /// Deletes a half-written file, unless something is playing it.
    private static func keepingWhatIsPlaying(
        _ scratch: URL,
        isPlaying: Bool,
        error: any Error
    ) -> any Error {
        guard isPlaying else {
            try? FileManager.default.removeItem(at: scratch)
            return error
        }
        return Refusal.cutOff(partial: scratch, underlying: error)
    }

    /// How much music a file actually holds, or nil where that cannot be read — the same
    /// measurement `refuseIfShort` makes, offered on its own so a caller can tell a song that was
    /// cut short from one that merely lost its connection on the last…
    static func arrivedDuration(of url: URL) -> TimeInterval? {
        guard let opened = try? AVAudioFile(forReading: url) else { return nil }
        let rate = opened.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        let seconds = Double(opened.length) / rate
        return seconds > 0 ? seconds : nil
    }

    /// Throws when a file that arrived intact holds far less music than the track is known to have.
    private static func refuseIfShort(_ url: URL, expected: TimeInterval?) throws {
        guard let expected, expected > 0,
              let opened = try? AVAudioFile(forReading: url)
        else { return }
        let rate = opened.processingFormat.sampleRate
        guard rate > 0 else { return }
        let arrived = Double(opened.length) / rate
        guard arrived > 0, arrived < expected / 2 else { return }
        throw Refusal.tooShort(arrived: arrived, expected: expected)
    }

    /// Throws when what arrived is not audio at all, before it is filed as a song.
    private static func refuseIfNotAudio(_ url: URL) throws {
        let size = AudioResponseCheck.size(ofFileAt: url)
        let head = AudioResponseCheck.head(ofFileAt: url)
        // Only opened where the answer could change the verdict.
        let canOpen = size >= AudioResponseCheck.smallestPlausibleSong
            || (try? AVAudioFile(forReading: url)) != nil
            // Ogg Vorbis, which iOS cannot open but the app decodes itself.
            || VorbisFile.isVorbis(head: head)
        if let reason = AudioResponseCheck.verdictForCachedStream(
            size: size, head: head, canOpen: canOpen
        ) {
            throw Refusal.notAudio(reason)
        }
    }

    /// How long a fetch for the song someone is waiting to hear right now may go without a single
    /// byte arriving before something else is more likely wrong than merely slow.
    private static let playingNowWatchdogSeconds: TimeInterval = 45

    /// The most a fetch that keeps trickling may take, so a transfer that
    /// makes progress but never finishes is still ended in the end.
    private static let playingNowTotalSeconds: TimeInterval = 3600

    /// How many turns a read-ahead will wait for the lane before deciding
    /// nobody is going to give it one — see `takeTheLane`.
    private static let readAheadPatience = 10_000

    /// Waits for a fetch on the listener's own behalf, giving up after `playingNowWatchdogSeconds`
    /// rather than waiting on it forever.
    private func awaited(
        _ transfer: Transfer,
        key: String,
        priority: Priority
    ) async throws -> URL {
        let task = transfer.task
        let token = transfer.token
        let activity = transfer.activity
        // Every wait on a transfer goes through this, so the transfer knows how
        // many are left and is called off when the last one goes: cancelling
        // the caller used to stop at the caller.
        let wait: @Sendable () async throws -> URL = {
            try await TransferWaiting.wait(
                on: task,
                waiters: transfer.waiters,
                onAbandoned: { Task { await self.abandoned(transfer) } }
            )
        }
        guard priority == .playingNow else { return try await wait() }
        // What the group below decided: the file arrived, or the transfer
        // went quiet.
        enum Outcome: Sendable { case arrived(URL), quiet(InactivityWatchdog.Expiry) }
        var stalled: InactivityWatchdog.Expiry?
        do {
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { .arrived(try await wait()) }
                group.addTask {
                    // Nothing has arrived for the whole window.
                    let expiry = try await InactivityWatchdog.expiry(
                        of: activity,
                        idleLimit: .seconds(Self.playingNowWatchdogSeconds),
                        totalLimit: .seconds(Self.playingNowTotalSeconds)
                    )
                    // The fetch itself, not merely this group.
                    task.cancel()
                    return .quiet(expiry)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                switch first {
                case .arrived(let url):
                    return url
                case .quiet(let why):
                    stalled = why
                    // The cancelled fetch has to unwind before this group can return, and how it
                    // unwinds says whether the engine is already playing its file:
                    // `keepingWhatIsPlaying` wraps the failure in `cutOff` then.
                    do {
                        // Finished in the same instant: nothing to give up on.
                        if case .arrived(let url)? = try await group.next() { return url }
                    } catch Refusal.cutOff(let partial, _) {
                        throw Refusal.cutOff(partial: partial, underlying: Refusal.stalled)
                    } catch {}
                    throw Refusal.stalled
                }
            }
        } catch {
            if let why = stalled {
                let what = why == .idle
                    ? "produced nothing in \(Int(Self.playingNowWatchdogSeconds))s"
                    : "was still running after \(Int(Self.playingNowTotalSeconds))s"
                TranscodeLog.record("watchdog: \(key) \(what), giving up on it")
                if inFlight[key]?.token == token { inFlight[key] = nil }
            }
            throw error
        }
    }

    func file(
        for id: MediaID,
        request: URLRequest,
        variant: MediaVariant = .original,
        priority: Priority = .readAhead,
        markPlayed: Bool = true,
        /// How long the library says this track is, where the caller knows.
        /// Checked against what arrives — see `refuseIfShort`.
        expectedDuration: TimeInterval? = nil,
        /// The track's own bit rate where the library knows it, for sizing how
        /// much of an original has to arrive before it is started.
        bitRateKbps: Int? = nil,
        onPartial: (@Sendable (URL) -> Void)? = nil
    ) async throws -> URL {
        let key = Self.fileName(for: id, request: request, variant: variant)
        let destination = directory.appending(path: key)

        if FileManager.default.fileExists(atPath: destination.path) {
            if markPlayed { used(destination) }
            return destination
        }
        // A guess joins whatever is already arriving.
        if priority == .readAhead, let running = await liveTransfer(key) {
            if let onPartial { running.relay.observe(onPartial) }
            return try await awaited(running, key: key, priority: priority)
        }
        try await takeTheLane(for: key, as: priority)
        // Waiting is a suspension, and the world moves on during one: the
        // song may have landed meanwhile, or a tap may have started it.
        if FileManager.default.fileExists(atPath: destination.path) {
            if markPlayed { used(destination) }
            return destination
        }
        if let running = await liveTransfer(key) {
            if let onPartial { running.relay.observe(onPartial) }
            // A same-song re-tap joins whatever is already arriving rather than restarting it —
            // which is right when that fetch is merely slow, and exactly the case that went silent
            // forever when it was not: nothing here was ever watching how long…
            return try await awaited(running, key: key, priority: priority)
        }

        // Not a transfer for a caller that has already been cancelled: nobody
        // would be waiting for it.
        try Task.checkCancellation()
        let relay = PartialRelay()
        let activity = ActivityClock()
        let isConversion = !variant.isOriginal
        // How much has to have arrived before the engine is handed the file still being written: a
        // few seconds of this stream's own bit rate, not a fixed byte count — see `GrowingFile`.
        let startBytes: Int64 = {
            switch variant {
            case .original: GrowingFile.startBytes(kbps: bitRateKbps)
            case .converted(_, let kbps): GrowingFile.startBytes(kbps: kbps ?? 128)
            }
        }()
        if let onPartial { relay.observe(onPartial) }
        // Detached, and that word is the whole point of this line.
        let task = Task<URL, any Error>.detached(
            priority: priority == .playingNow ? .userInitiated : .utility
        ) { [transport, directory] in
            // Written to a scratch name and moved into place, so a fetch that
            // fails halfway can never leave a truncated file looking cached.
            let scratch = directory.appending(path: key + CacheMaintenance.scratchSuffix)
            try? FileManager.default.removeItem(at: scratch)
            do {
                do {
                    // Start on the first part of the file rather than the last.
                    let told = Mutex(false)
                    try await transport.download(request, to: scratch) { written, total in
                        activity.touch()
                        guard written >= startBytes else { return }
                        // Never on a file that is nearly here anyway: the
                        // handover costs a re-open and a re-schedule, and
                        // saving twenty milliseconds is not worth it.
                        if GrowingFile.isNearlyComplete(total: total, startBytes: startBytes) { return }
                        let first = told.withLock { fired -> Bool in
                            defer { fired = true }
                            return !fired
                        }
                        guard first else { return }
                        let head = AudioResponseCheck.head(ofFileAt: scratch)
                        // Never a page or an error envelope, whatever it was
                        // labelled.
                        guard !AudioResponseCheck.startsLikeMarkup(head) else { return }
                        relay.announce(scratch)
                    }
                }
            } catch {
                throw Self.keepingWhatIsPlaying(
                    scratch, isPlaying: relay.wasObserved, error: error
                )
            }
            do {
                try Self.refuseIfNotAudio(scratch)
                try Self.refuseIfShort(scratch, expected: expectedDuration)
            } catch {
                throw Self.keepingWhatIsPlaying(
                    scratch, isPlaying: relay.wasObserved, error: error
                )
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: scratch, to: destination)
            } catch {
                // The scratch file is gone — Clear cache, or a store that swept it — or cannot be
                // moved.
                throw Self.keepingWhatIsPlaying(
                    scratch, isPlaying: relay.wasObserved, error: error
                )
            }
            return destination
        }
        let transfer = Transfer(
            id: id,
            key: key,
            priority: priority,
            task: task,
            relay: relay,
            activity: activity,
            waiters: TransferWaiters(),
            isConversion: isConversion
        )
        inFlight[key] = transfer
        // Only its own entry: a tap may have cut this transfer off and
        // removed it already, and by now the name could belong to a newer one.
        defer { if inFlight[key]?.token == transfer.token { inFlight[key] = nil } }

        let url = try await awaited(transfer, key: key, priority: priority)
        evictIfNeeded()
        return url
    }

    /// The transfer under this name, if there is one to join.
    private func liveTransfer(_ key: String) async -> Transfer? {
        while let running = inFlight[key], running.waiters.isAbandoned {
            _ = try? await running.task.value
            if inFlight[key]?.token == running.token { inFlight[key] = nil }
        }
        return inFlight[key]
    }

    /// The last of a transfer's waiters left and none came back: the transfer has been cancelled,
    /// and what it leaves is tidied up.
    private var lastCleanup: Task<Void, Never>?

    private func abandoned(_ transfer: Transfer) {
        TranscodeLog.record("abandoned \(transfer.key): nobody is waiting for it any more")
        let previous = lastCleanup
        lastCleanup = Task { [weak self] in
            await previous?.value
            // A transfer that finished before anyone noticed nobody was
            // waiting has left nothing to tidy.
            if case .success = await transfer.task.result { return }
            await self?.finishAbandoned(transfer)
        }
    }

    private func finishAbandoned(_ transfer: Transfer) async {
        if inFlight[transfer.key]?.token == transfer.token { inFlight[transfer.key] = nil }
        removeScratchUnlessInUse(transfer.key, ifNotReplacedBy: transfer.token)
        // Not if the song has been asked for again meanwhile: the conversion
        // running now is the new one's, and the server would stop it.
        if transfer.isConversion, inFlight[transfer.key] == nil { await release(transfer.id) }
    }

    /// Deletes the half-written file of a transfer that has ended without finishing, unless a newer
    /// transfer has taken the name or the track is the one being played.
    private func removeScratchUnlessInUse(_ key: String, ifNotReplacedBy token: UUID) {
        if let current = inFlight[key], current.token != token { return }
        let scratch = directory.appending(path: key + CacheMaintenance.scratchSuffix)
        guard !CacheMaintenance.isProtected(scratch.lastPathComponent, prefixes: protectedPrefixes)
        else { return }
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Waits for, or clears, whatever else is being fetched.
    private func takeTheLane(for key: String, as priority: Priority) async throws {
        switch priority {
        case .playingNow:
            tapsSeen &+= 1
            let mine = tapsSeen
            // Two taps on the same song: the second lets the first do the
            // clearing and joins whatever it starts, rather than both
            // starting a conversion under the one name.
            while let claimed = claimedFor, claimed.key == key {
                await withCheckedContinuation { claimWaiters.append($0) }
                guard mine == tapsSeen else { throw CancellationError() }
            }
            claimedFor = Claim(key: key, tap: mine)
            defer {
                // Only its own claim, by which tap made it rather than by
                // key alone: a different tap, clearing for a different
                // song, may have taken the one shared slot in the meantime.
                if claimedFor?.tap == mine {
                    claimedFor = nil
                    let waiting = claimWaiters
                    claimWaiters = []
                    for waiter in waiting { waiter.resume() }
                }
            }
            while let (otherKey, other) = inFlight.first(where: { $0.key != key }) {
                TranscodeLog.record("cutting off \(other.id.rawValue) (\(other.priority)) for \(key)")
                // Called off here, and released below: the waiters leaving
                // afterwards must not do it a second time.
                other.waiters.forceAbandon()
                other.task.cancel()
                _ = try? await other.task.value
                if inFlight[otherKey]?.token == other.token { inFlight[otherKey] = nil }
                // The store called this one off, so nothing is going to use what it had written: a
                // fetch cut off while the engine was on its scratch file leaves that file in place,
                // and nothing else would ever remove it.
                removeScratchUnlessInUse(otherKey, ifNotReplacedBy: other.token)
                await release(other.id)
                // A newer tap came while the server was being told: the
                // song this was clearing for is not the song any more, and
                // starting it now would only cut off the one that is.
                guard mine == tapsSeen else { throw CancellationError() }
            }
            // A conversion let go by the last of its waiters is being ended
            // at the server too; this one's own starts after.
            await lastCleanup?.value
        case .readAhead:
            // A guess waits its turn — but never by spinning, and not for ever.
            var rounds = 0
            while true {
                if let (_, other) = inFlight.first(where: { $0.key != key }) {
                    _ = try? await other.task.value
                } else if claimedFor != nil {
                    // A tap is clearing the lane — for this very song,
                    // possibly, in which case what it starts is joined.
                    await withCheckedContinuation { claimWaiters.append($0) }
                } else {
                    return
                }
                // A guess nobody wants any more has no turn to wait for.
                try Task.checkCancellation()
                // Unconditionally, and this is the whole fix: hand the
                // store back before looking again.
                await Task.yield()
                rounds += 1
                if rounds > Self.readAheadPatience {
                    TranscodeLog.record("read-ahead gave up waiting its turn for \(key)")
                    throw CancellationError()
                }
            }
        }
    }

    /// Tells the server a cut-off conversion is over, and waits for the answer — but not for ever.
    private func release(_ id: MediaID) async {
        guard let releaseConversion else { return }
        let told = Task { await releaseConversion(id) }
        // `told` is its own task, not a child of the group below — so `group.cancelAll()` marks the
        // *wrapper* around it cancelled and stops there.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await told.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                told.cancel()
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Changes how much may be kept, and evicts straight away if the new
    /// figure is smaller than what is already there.
    func setLimit(_ bytes: Int64) {
        guard bytes != cacheLimit else { return }
        cacheLimit = bytes
        evictIfNeeded()
    }

    /// Bytes currently held, for the settings screen to report.
    func usage() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// True when the track is already on disk, so the player can start it
    /// without showing a buffering state.
    func isCached(_ id: MediaID, request: URLRequest, variant: MediaVariant = .original) -> Bool {
        FileManager.default.fileExists(
            atPath: directory
                .appending(path: Self.fileName(for: id, request: request, variant: variant))
                .path
        )
    }

    /// The finished file for a track, if one is already on the disk.
    func cachedFile(for id: MediaID, variant: MediaVariant) -> URL? {
        files(for: id, matching: { $0.contains("-\(variant.tag).") }).first
    }

    /// Whether the untouched file is already here.
    func hasOriginal(for id: MediaID) -> Bool {
        !files(for: id, matching: { $0.contains("-orig.") }).isEmpty
    }

    /// What is already on disk for a track, from one directory listing — for a caller that is about
    /// to ask both whether the original is here and whether some variant is, the way starting a
    /// track does.
    func ping() -> Int {
        pings &+= 1
        return pings
    }
    private var pings = 0

    func localFiles(for id: MediaID) -> LocalFiles {
        LocalFiles(files: files(for: id, matching: { _ in true }))
    }

    /// A track's files, answering the same questions `hasOriginal(for:)` and
    /// `cachedFile(for:variant:)` do, off a listing already taken.
    struct LocalFiles {
        fileprivate let files: [URL]

        var hasOriginal: Bool {
            files.contains { $0.lastPathComponent.contains("-orig.") }
        }

        func cached(variant: MediaVariant) -> URL? {
            files.first { $0.lastPathComponent.contains("-\(variant.tag).") }
        }
    }

    /// Says which tracks are playing or armed to follow, so maintenance leaves their files alone —
    /// see `protectedPrefixes`.
    func setInUse(_ ids: Set<MediaID>, sequence: Int) {
        guard sequence > inUseSequence else { return }
        inUseSequence = sequence
        let prefixes = Set(ids.map { Self.trackPrefix(for: $0) })
        guard prefixes != protectedPrefixes else { return }
        protectedPrefixes = prefixes
        let due = CacheMaintenance.dueAfterProtection(
            deferred: conversionsToDrop, nowProtected: prefixes
        )
        guard !due.isEmpty else { return }
        conversionsToDrop.subtract(due)
        for name in fileNames() where !name.contains("-orig.") && !CacheMaintenance.isScratch(name)
            && due.contains(where: { name.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Records that a file was played, so that what is played is kept longer than what was merely
    /// fetched.
    func used(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        else { return }
        lastPlayed[url.lastPathComponent] = Date()
    }

    /// Drops every converted copy of a track.
    func dropConversions(for id: MediaID) {
        for url in files(for: id, matching: { !$0.contains("-orig.") }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Clears out files from before names were stable and variant-tagged.
    private static func removeUnreadableFiles(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            // A half-written file belongs to one fetch in one session.
            if name.hasSuffix(".partial") {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard !name.contains("-orig."), !name.contains("-c-") else {
                // A "song" that is really an error page or nothing at all, filed by a version that
                // took any 2xx for audio: replayed from the cache, it failed for good.
                if AudioResponseCheck.size(ofFileAt: url) < AudioResponseCheck.smallestPlausibleSong,
                   AudioResponseCheck.verdictForCachedStream(
                       size: AudioResponseCheck.size(ofFileAt: url),
                       head: AudioResponseCheck.head(ofFileAt: url),
                       canOpen: true
                   ) != nil {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Throws away every converted file, everywhere.
    func dropAllConversions() {
        let sweep = CacheMaintenance.conversionSweep(fileNames(), protectedPrefixes: protectedPrefixes)
        for name in sweep.drop {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        conversionsToDrop.formUnion(sweep.deferred)
    }

    /// Files belonging to one track, by the prefix its id hashes to.
    private func files(for id: MediaID, matching: (String) -> Bool) -> [URL] {
        let prefix = Self.trackPrefix(for: id)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(prefix) && matching(name) && !name.hasSuffix(".partial")
        }
    }

    /// Empties the cache — except what is in use.
    func clear() {
        let doomed = CacheMaintenance.clearable(
            fileNames(),
            inFlightKeys: Set(inFlight.keys),
            protectedPrefixes: protectedPrefixes
        )
        for name in doomed {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        lastPlayed = lastPlayed.filter { FileManager.default.fileExists(atPath: directory.appending(path: $0.key).path) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Every name in the cache directory.
    private func fileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: Housekeeping

    /// Least recently *used* first, where a play is a use.
    private func evictIfNeeded() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return }

        var entries: [CacheMaintenance.Entry] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize
            else { continue }
            let name = url.lastPathComponent
            entries.append(.init(
                name: name,
                size: Int64(size),
                modified: values.contentModificationDate ?? .distantPast,
                lastPlayed: lastPlayed[name]
            ))
        }
        // The limit is the app's, and the other libraries' folders count against it: this folder
        // alone was held to the whole figure, so with anything left in another library the total,
        // which is what Settings shows, ran over it.
        let share = CacheTree.share(of: cacheLimit, root: Self.rootDirectory, for: directory.lastPathComponent)
        let plan = CacheMaintenance.eviction(
            entries,
            limit: share,
            inFlightKeys: Set(inFlight.keys),
            protectedPrefixes: protectedPrefixes
        )
        for name in plan.staleScratch + plan.evict {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
            lastPlayed[name] = nil
        }
    }

    /// Keyed by track, then by what the file *is*.
    private static func fileName(
        for id: MediaID,
        request: URLRequest,
        variant: MediaVariant
    ) -> String {
        let ext = request.url?.pathExtension.isEmpty == false
            ? request.url!.pathExtension
            : "audio"
        return "\(trackPrefix(for: id))\(variant.tag).\(ext)"
    }

    /// A stable name for a track.
    private static func trackPrefix(for id: MediaID) -> String {
        let digest = SHA256.hash(data: Data(id.rawValue.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + "-"
    }
}
