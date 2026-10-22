import Foundation
import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// The live agent behind the DJ feature: owns which DJ (if any) is active, watches playback through
/// the hooks `PlayerModel` exposes for exactly this, and keeps the upcoming queue topped up
/// according to whichever strategy is running.
@MainActor
@Observable
final class DJEngine {
    private(set) var active: DJStrategyKind?
    /// True once any part of the current session has had to fall back to genre/era scoring — never
    /// cleared back to false mid-session, since "some of this ran on the coarser signal" stays true
    /// even if the next pick happens to come back sonic.
    private(set) var isDegraded = false
    private(set) var journeyDestination: DJDestination?
    private(set) var journeyLength: Int?
    private(set) var journeySteps = 0
    private(set) var hasArrivedAtJourneyDestination = false
    /// A message worth showing once, right after activation — the toast this feature's own spec
    /// calls for.
    private(set) var activationMessage: String?
    /// Told to the listener once, when a rating-locked pool has genuinely
    /// run dry — Gold's "if the pool runs dry, tell the user rather than
    /// silently relaxing the constraint."
    private(set) var poolExhaustedMessage: String?

    private var index: LibraryIndex
    private var provider: any MusicServerProvider
    private let player: PlayerModel
    private let settings: AppSettings
    private let isOfflineNow: () -> Bool

    private var repeatWindow = DJRepeatWindow()
    private var artistCooldown = DJArtistCooldown()
    private var manuallyExcludedTrackIDs: Set<MediaID> = []
    /// Fixed at activation for `.sticky` strategies (Era, Purist); read but
    /// never reassigned for `.live` ones, which use `player.currentTrack`
    /// directly instead.
    private var stickyAnchor: Track?
    /// So a top-up already in flight is not started twice for the same
    /// stretch of queue — the same guard shape `PlayerModel.isToppingUp`
    /// already uses for its own, unrelated top-up.
    private var pendingTopUp = false
    /// Bumped on every activation, switch, deactivation and `stop()`.
    private var generation = 0

    /// Ends whatever top-up is in flight: bumps the generation its result is checked against and
    /// frees the "already topping up" flag with it.
    private func invalidateTopUps() {
        generation += 1
        pendingTopUp = false
    }
    /// What was authored the last time the queue was inspected, so a user
    /// edit can be recognised as a *removal* of one of these rather than
    /// requiring the queue to be diffed against nothing.
    private var lastKnownAuthoredTrackIDs: Set<MediaID> = []
    /// What a queue-replacing DJ (Drift, Journey) displaced on activation — put back automatically
    /// the moment that DJ turns off, so nothing outside this engine needs to know it was ever held.
    private var stashedQueue: [QueueItem]?

    private let strategies: [DJStrategyKind: any DJStrategy] = [
        .moody: MoodyStrategy(),
        .drift: DriftStrategy(),
        .era: EraStrategy(),
        .purist: PuristStrategy(),
        .deepCuts: DeepCutsStrategy(),
        .gold: GoldStrategy(),
        .fresh: FreshStrategy(),
    ]

    init(
        index: LibraryIndex,
        provider: any MusicServerProvider,
        player: PlayerModel,
        settings: AppSettings,
        isOffline: @escaping () -> Bool
    ) {
        self.index = index
        self.provider = provider
        self.player = player
        self.settings = settings
        self.isOfflineNow = isOffline
        player.onTrackStarted = { [weak self] track in self?.trackDidStart(track) }
        player.onQueueEditedByUser = { [weak self] in self?.userEditedQueue() }
        // A DJ is turned on for one particular queue, never a standing
        // default that follows a listener into the next one — see
        // `PlayerModel.onNewQueueStarted`'s own doc comment.
        player.onNewQueueStarted = { [weak self] in self?.stop() }
    }

    /// Points a running engine at a rebuilt connection to the *same* library — a retry, a proxy
    /// sign-in, an address repair.
    func rebind(index: LibraryIndex, provider: any MusicServerProvider) {
        self.index = index
        self.provider = provider
    }

    private var context: DJContext {
        DJContext(index: index, provider: provider, isOffline: isOfflineNow())
    }

    /// Runs a strategy's own pick off the main actor — its work is a synchronous library query and
    /// CPU-bound scoring, and neither belongs on the thread the UI is drawn on.
    private func pick(
        _ strategy: any DJStrategy, anchor: Track, excluding: Set<MediaID>, count: Int
    ) async -> DJBatch {
        let context = self.context
        let batch = await Task.detached {
            await strategy.nextBatch(anchor: anchor, excluding: excluding, count: count, context: context)
        }.value
        // A query can only ever exclude ids it has itself seen played or queued — it has no way to
        // know which *other* catalog rows are secretly the same recording under a different id, the
        // way a compilation-heavy library constantly produces.
        let songKeys = excludedSongKeys
        guard !songKeys.isEmpty else { return batch }
        let filtered = batch.tracks.filter { track in
            let keys = DJRepeatWindow.songKeys(for: track)
            guard !keys.isEmpty else { return true }
            return keys.isDisjoint(with: songKeys)
        }
        return DJBatch(tracks: filtered, degraded: batch.degraded)
    }

    /// `JourneyStrategy`'s own equivalent of `pick(_:anchor:excluding:count:)` — off the main actor
    /// for the same reason, one step of the bridge at a time.
    private func pickJourneyStep(
        anchor: Track, destination: DJDestination, step: Int, of length: Int,
        excluding: Set<MediaID>, excludingSongs alsoExcluding: Set<String> = []
    ) async -> (track: Track?, degraded: Bool) {
        let context = self.context
        let songKeys = excludedSongKeys.union(alsoExcluding)
        return await Task.detached {
            await JourneyStrategy.nextTrack(
                anchor: anchor, destination: destination, step: step, of: length,
                excluding: excluding, excludingSongs: songKeys, context: context
            )
        }.value
    }

    // MARK: Activation

    /// Turns on one of the seven non-Journey DJs, anchored on whatever is
    /// currently playing. Switching from another DJ deactivates it first —
    /// no stacking, ever.
    func activate(_ kind: DJStrategyKind) {
        guard kind != .journey, let strategy = strategies[kind] else { return }
        deactivateInternal()
        invalidateTopUps()
        let thisGeneration = generation
        active = kind
        isDegraded = false
        poolExhaustedMessage = nil
        seedForActivation()
        activationMessage = strategy.queuePolicy == .replace
            ? "Playing what \(kind.label) picks. Your queue picks back up automatically when you turn it off."
            : nil
        // Set here too, not only in `scheduleTopUp()` — this is itself a top-up in flight, and
        // without this flag `trackDidStart`, firing for an unrelated reason while this one is still
        // out fetching, would see `pendingTopUp` still false and start a…
        pendingTopUp = true
        Task { [weak self] in
            await self?.topUp(isInitialActivation: true, generation: thisGeneration)
            self?.finishTopUp(generation: thisGeneration)
        }
    }

    /// Turns on Journey with a chosen destination and bridge length — the
    /// whole bridge is worked out and queued in one pass, so it is visible
    /// in Up Next immediately rather than arriving one song at a time.
    func activateJourney(destination: DJDestination, length: Int) {
        deactivateInternal()
        invalidateTopUps()
        let thisGeneration = generation
        active = .journey
        isDegraded = false
        poolExhaustedMessage = nil
        journeyDestination = destination
        journeyLength = max(1, length)
        journeySteps = 0
        hasArrivedAtJourneyDestination = false
        seedForActivation()
        activationMessage = "Bridging to your destination over \(journeyLength ?? length) songs. Your queue picks back up automatically when you turn it off."
        Task { await buildFullJourney(generation: thisGeneration) }
    }

    private func seedForActivation() {
        // What it has already steered around is kept across a switch or a re-activation, and only
        // `stop()` forgets it.
        manuallyExcludedTrackIDs = []
        lastKnownAuthoredTrackIDs = []
        repeatWindow.setQueued(player.upNextTracks)
        if let track = player.currentTrack { repeatWindow.recordPlayed(track) }
        stickyAnchor = player.currentTrack
    }

    /// Turns the active DJ off.
    func deactivate() {
        deactivateInternal()
    }

    private func deactivateInternal() {
        guard let wasActive = active else { return }
        invalidateTopUps()
        removeNotYetPlayedEntries(authoredBy: wasActive)
        // A queue-replacing DJ's displaced queue comes straight back the moment it turns off — no
        // second, separate step.
        if let stashed = stashedQueue, !stashed.isEmpty {
            withAnimation { player.djRestoreStashed(stashed) }
        }
        stashedQueue = nil
        active = nil
        isDegraded = false
        journeyDestination = nil
        journeyLength = nil
        journeySteps = 0
        hasArrivedAtJourneyDestination = false
        activationMessage = nil
        poolExhaustedMessage = nil
        stickyAnchor = nil
    }

    private func removeNotYetPlayedEntries(authoredBy kind: DJStrategyKind) {
        let currentIndex = player.currentIndex ?? -1
        var authoredIDs: Set<UUID> = []
        var playedIDs: Set<UUID> = []
        for (offset, item) in player.queue.enumerated() where item.djOrigin == kind {
            authoredIDs.insert(item.id)
            if offset <= currentIndex { playedIDs.insert(item.id) }
        }
        let toRemove = DJQueueBookkeeping.idsToRemoveOnDeactivation(authoredIDs: authoredIDs, playedIDs: playedIDs)
        guard !toRemove.isEmpty else { return }
        withAnimation { player.djRemoveEntries(withIDs: toRemove) }
    }

    func dismissActivationMessage() {
        activationMessage = nil
    }

    func dismissPoolExhaustedMessage() {
        poolExhaustedMessage = nil
    }

    /// Torn down alongside the rest of `connectActive()`'s rebuilt objects — see
    /// `DownloadManager.stop()` for the identical reasoning — and also what runs every time a brand
    /// new queue starts playing, DJ or not; see `PlayerModel.onNewQueueStarted`.
    func stop() {
        invalidateTopUps()
        active = nil
        isDegraded = false
        journeyDestination = nil
        journeyLength = nil
        journeySteps = 0
        hasArrivedAtJourneyDestination = false
        stashedQueue = nil
        activationMessage = nil
        poolExhaustedMessage = nil
        repeatWindow = DJRepeatWindow()
        artistCooldown = DJArtistCooldown()
        manuallyExcludedTrackIDs = []
        lastKnownAuthoredTrackIDs = []
        stickyAnchor = nil
    }

    // MARK: Playback hooks

    private func trackDidStart(_ track: Track) {
        repeatWindow.recordPlayed(track)
        guard active != nil else { return }
        if active == .journey, player.currentItem?.djOrigin == .journey {
            journeySteps += 1
            if let journeyLength, JourneyStrategy.hasArrived(step: journeySteps, of: journeyLength) {
                handOffJourneyArrival()
            }
        }
        scheduleTopUp()
    }

    private func userEditedQueue() {
        // The guard first.
        guard active != nil else { return }
        repeatWindow.setQueued(player.upNextTracks)
        let currentAuthored = Set(player.queue.filter { $0.djOrigin != nil }.map(\.track.id))
        let removed = lastKnownAuthoredTrackIDs.subtracting(currentAuthored)
        if !removed.isEmpty {
            manuallyExcludedTrackIDs.formUnion(removed)
        }
        lastKnownAuthoredTrackIDs = currentAuthored
        // The user's own edit may itself have thinned the queue enough to
        // be worth topping up again — a manual removal is exactly the kind
        // of edit that can leave a weaving DJ under its own cap.
        scheduleTopUp()
    }

    /// Once Journey's step counter reaches its length, it keeps playing at the destination rather
    /// than stopping — the hand-off to Drift the spec calls for, done by letting `topUpJourney()`
    /// keep picking with `step` pinned at `length`, which is…
    private func handOffJourneyArrival() {
        hasArrivedAtJourneyDestination = true
    }

    private func scheduleTopUp() {
        guard active != nil, !pendingTopUp else { return }
        pendingTopUp = true
        let thisGeneration = generation
        Task { [weak self] in
            await self?.topUp(isInitialActivation: false, generation: thisGeneration)
            self?.finishTopUp(generation: thisGeneration)
        }
    }

    /// Frees the top-up flag, but only for the top-up that set it. One that
    /// was overtaken (`invalidateTopUps`) leaves the flag to whoever owns it
    /// now.
    private func finishTopUp(generation finished: Int) {
        guard generation == finished else { return }
        pendingTopUp = false
    }

    // MARK: Topping up

    private var excludedTrackIDs: Set<MediaID> {
        repeatWindow.excludedIDs.union(manuallyExcludedTrackIDs)
    }

    /// The song-identity half of repeat avoidance — every recording, by artist and title, already
    /// playing, queued, or recently played under some catalog id.
    private var excludedSongKeys: Set<String> {
        repeatWindow.excludedSongKeys
    }

    private func topUp(isInitialActivation: Bool, generation: Int) async {
        guard let active else { return }
        if active == .journey {
            await topUpJourney(generation: generation)
            return
        }
        guard let strategy = strategies[active] else { return }
        switch strategy.queuePolicy {
        case .weave:
            await topUpWeaving(strategy, generation: generation)
        case .sustain:
            await topUpSustaining(strategy, generation: generation)
        case .replace:
            await topUpReplacing(strategy, isInitialActivation: isInitialActivation, generation: generation)
        }
        lastKnownAuthoredTrackIDs = Set(player.queue.filter { $0.djOrigin != nil }.map(\.track.id))
    }

    /// Moody, Fresh, Gold, Deep Cuts: a batch is woven in right after the playing track, once per
    /// gap.
    private func topUpWeaving(_ strategy: any DJStrategy, generation: Int) async {
        let upNext = player.upNext
        guard !upNext.isEmpty else {
            // Nothing queued at all — fall back to Drift's endless append
            // regardless of what is playing right now, since there is no
            // "next original song" left to wait for.
            if let drift = strategies[.drift] {
                await topUpReplacing(
                    drift, isInitialActivation: false, actingAs: active ?? strategy.kind, generation: generation
                )
            }
            return
        }
        // Still mid-batch: the playing track is itself one of this DJ's own
        // picks, so the last gap has not actually been played through yet,
        // whatever `upNext` looks like.
        guard let current = player.currentItem, current.djOrigin == nil else { return }
        guard upNext[0].djOrigin == nil else { return }
        let anchor = current.track

        let insertionCount = max(1, settings.djInsertionCount)
        // Asked for well beyond what will actually be inserted: the cooldown below needs real
        // variety to choose from, and a batch barely bigger than what it is picking often ranks out
        // as one strongly-matching album with nothing else in it to fall…
        let batch = await pick(strategy, anchor: anchor, excluding: excludedTrackIDs, count: insertionCount * 6)
        // Checked immediately after the only suspension point in this function, before anything
        // below touches the queue or either exclusion tracker — a DJ turned off (or switched) while
        // this was in flight gets none of its stale pick applied, and…
        guard self.generation == generation else { return }
        artistCooldown.record(DJArtistCooldown.key(for: anchor))
        if batch.degraded { isDegraded = true }
        if batch.tracks.isEmpty {
            if strategy.kind == .gold {
                poolExhaustedMessage = "No more songs clear Gold's four-star line without repeating."
            }
            return
        }
        if strategy.kind == .gold { poolExhaustedMessage = nil }

        let picked = artistCooldown.diversePick(from: batch.tracks, limit: insertionCount)
        guard !picked.isEmpty else { return }
        player.djInsertNext(picked, by: strategy.kind)
        for track in picked {
            repeatWindow.recordPlayed(track)
            artistCooldown.record(DJArtistCooldown.key(for: track))
        }
        repeatWindow.setQueued(player.upNextTracks)
    }

    /// Era, Purist: up to two tracks kept queued immediately after the playing one, topped up by
    /// one the instant either is consumed — never clearing what already follows the buffer, just
    /// never letting the buffer itself run dry while the DJ is on.
    private func topUpSustaining(_ strategy: any DJStrategy, generation: Int) async {
        let cap = 2
        let upNext = player.upNext
        let existing = upNext.filter { $0.djOrigin == strategy.kind }
        guard existing.count < cap else { return }
        let anchor = strategy.anchorPolicy == .sticky ? (stickyAnchor ?? player.currentTrack) : player.currentTrack
        guard let anchor else { return }
        let want = cap - existing.count
        let batch = await pick(strategy, anchor: anchor, excluding: excludedTrackIDs, count: want)
        guard self.generation == generation else { return }
        if batch.degraded { isDegraded = true }
        guard !batch.tracks.isEmpty else { return }
        // `existing` is a snapshot from before the `await` above — if the user removed that very
        // entry while this was in flight, `djInsertAfter` is a documented no-op, and the batch must
        // not be recorded as played or queued when it was never actually…
        let inserted: Bool
        if let lastID = existing.last?.id {
            inserted = player.djInsertAfter(lastID, tracks: batch.tracks, by: strategy.kind)
        } else {
            player.djInsertNext(batch.tracks, by: strategy.kind)
            inserted = true
        }
        guard inserted else { return }
        for track in batch.tracks { repeatWindow.recordPlayed(track) }
        repeatWindow.setQueued(player.upNextTracks)
    }

    /// Drift: a small rolling buffer, each addition anchored on the one
    /// before it (or, for the very first batch, on whatever was playing
    /// when Drift turned on).
    private func topUpReplacing(
        _ strategy: any DJStrategy, isInitialActivation: Bool, actingAs actingKind: DJStrategyKind? = nil,
        generation: Int
    ) async {
        let kind = actingKind ?? strategy.kind
        if isInitialActivation {
            let displaced = player.djReplaceUpcoming(with: [], by: kind)
            if !displaced.isEmpty { stashedQueue = displaced }
            // What was queued is not queued any more, so it is not excluded for being queued.
            repeatWindow.setQueued(player.upNextTracks)
        }
        let bufferTarget = 5
        // Only this DJ's own entries count toward its buffer — a track the user manually queued
        // during a Drift session sits alongside it and is never touched, but it also never counts
        // as part of the buffer Drift is trying to keep full.
        let have = player.upNext.filter { $0.djOrigin == kind }.count
        guard have < bufferTarget else {
            if isInitialActivation { restoreStashIfNothingReplacedIt(reason: nil) }
            return
        }
        let anchor = player.queue.last?.track ?? player.currentTrack
        guard let anchor else { return }
        let batch = await pick(strategy, anchor: anchor, excluding: excludedTrackIDs, count: bufferTarget - have)
        guard self.generation == generation else { return }
        if batch.degraded { isDegraded = true }
        guard !batch.tracks.isEmpty else {
            // Nothing to put in the queue's place. Emptying the queue and
            // leaving it empty stops the music after this song; put it back
            // and say why the DJ has nothing to add.
            if isInitialActivation {
                restoreStashIfNothingReplacedIt(reason: "\(kind.label) found nothing to play in place of your queue, so it is back as it was.")
            }
            return
        }
        // Re-read after the await: a second top-up or the user may have added
        // to the buffer meanwhile, and appending the whole batch on top would
        // overshoot it.
        let haveNow = player.upNext.filter { $0.djOrigin == kind }.count
        let room = bufferTarget - haveNow
        guard room > 0 else { return }
        let batchTracks = Array(batch.tracks.prefix(room))
        player.djAppend(batchTracks, by: kind)
        for track in batchTracks { repeatWindow.recordPlayed(track) }
        repeatWindow.setQueued(player.upNextTracks)
    }

    /// Journey's upfront build: the whole bridge, one step at a time, each step anchored on the one
    /// before it (the first on whatever is actually playing) — the same sequential logic the old
    /// incremental version used, just run in one pass at…
    private func buildFullJourney(generation: Int) async {
        guard let destination = journeyDestination, let length = journeyLength else { return }
        let displaced = player.djReplaceUpcoming(with: [], by: .journey)
        stashedQueue = displaced.isEmpty ? nil : displaced
        // See `topUpReplacing`: what was stashed is no longer queued.
        repeatWindow.setQueued(player.upNextTracks)

        var anchor = player.currentTrack
        var picked: [Track] = []
        // Kept here rather than written into `repeatWindow` a step at a time.
        var pickedIDs: Set<MediaID> = []
        var pickedSongs: Set<String> = []
        for step in 1...length {
            guard let currentAnchor = anchor else { break }
            let (track, degraded) = await pickJourneyStep(
                anchor: currentAnchor, destination: destination, step: step, of: length,
                excluding: excludedTrackIDs.union(pickedIDs), excludingSongs: pickedSongs
            )
            // Checked after every step's own suspension point, not just once at the end — the
            // bridge is built across `length` awaits, any one of which can outlast this Journey
            // being turned off or switched away from mid-build.
            guard self.generation == generation else { return }
            if degraded { isDegraded = true }
            guard let track else { break }
            picked.append(track)
            pickedIDs.insert(track.id)
            pickedSongs.formUnion(DJRepeatWindow.songKeys(for: track))
            anchor = track
        }
        guard self.generation == generation else { return }
        guard !picked.isEmpty else {
            restoreStashIfNothingReplacedIt(reason: "No bridge to your destination could be built, so your queue is back as it was.")
            return
        }
        player.djAppend(picked, by: .journey)
        repeatWindow.setQueued(player.upNextTracks)
        lastKnownAuthoredTrackIDs = Set(player.queue.filter { $0.djOrigin != nil }.map(\.track.id))
    }

    /// Puts a displaced queue back when the DJ that displaced it had nothing to
    /// put in its place.
    private func restoreStashIfNothingReplacedIt(reason: String?) {
        guard let stashed = stashedQueue, !stashed.isEmpty else { return }
        guard !player.upNext.contains(where: { $0.djOrigin == active }) else { return }
        withAnimation { player.djRestoreStashed(stashed) }
        stashedQueue = nil
        repeatWindow.setQueued(player.upNextTracks)
        if let reason { poolExhaustedMessage = reason }
    }

    /// Journey after arrival: the endless continuation the spec calls for, anchored at the
    /// destination in every way but name — `step` pinned at `length` so
    /// `DJJourneyPath.blendedScore` weighs the destination at its maximum on every pick.
    private func topUpJourney(generation: Int) async {
        guard hasArrivedAtJourneyDestination else { return }
        guard let destination = journeyDestination, let length = journeyLength else { return }
        let bufferTarget = 3
        // Only Journey's own entries count toward its buffer — a manually
        // queued track during a Journey session is never mistaken for part
        // of the endless tail past the destination.
        let journeyEntriesQueued = player.upNext.filter { $0.djOrigin == .journey }
        guard journeyEntriesQueued.count < bufferTarget else { return }
        guard let anchor = player.queue.last?.track ?? player.currentTrack else { return }
        let (picked, degraded) = await pickJourneyStep(
            anchor: anchor, destination: destination, step: length, of: length, excluding: excludedTrackIDs
        )
        guard self.generation == generation else { return }
        if degraded { isDegraded = true }
        guard let picked else { return }
        player.djAppend([picked], by: .journey)
        repeatWindow.recordPlayed(picked)
        repeatWindow.setQueued(player.upNextTracks)
        lastKnownAuthoredTrackIDs = Set(player.queue.filter { $0.djOrigin != nil }.map(\.track.id))
    }
}
