import Foundation
import PleviDomain
import PleviLibraryIndex

/// Where a DJ inserts what it picks — decided once per strategy, applied identically by `DJEngine`
/// for every DJ that shares it, so the mechanics of weaving or replacing are written once rather
/// than once per DJ.
enum DJAnchorPolicy: Sendable {
    /// Locked to whatever was playing when the DJ activated — Era's decade, Purist's genre.
    case sticky
    /// Follows the currently playing track as playback advances — Drift,
    /// Deep Cuts, Gold. "The current vibe" means the one playing now, not
    /// the one that was playing when the DJ turned on.
    case live
}

enum DJQueuePolicy: Sendable {
    /// Moody, Fresh, Gold, Deep Cuts: a batch of `AppSettings.djInsertionCount` tracks is woven in
    /// right after whatever is playing, once per gap — the next one is not opened until this one
    /// has been fully played through, so the user's own queue…
    case weave
    /// Era, Purist: up to two tracks are kept queued immediately after the playing one at all
    /// times, topped up by one the moment either is consumed — a standing takeover of what plays
    /// next, for as long as the DJ stays on, without ever clearing or…
    case sustain
    /// Drift, Journey: the upcoming queue is cleared once and stashed, put
    /// back automatically the moment the DJ is turned off.
    case replace
}

/// What a strategy needs to pick from — everything DJEngine already holds a
/// reference to, handed down rather than each strategy reaching for its own
/// copies.
struct DJContext {
    let index: LibraryIndex
    let provider: any MusicServerProvider
    let isOffline: Bool
}

/// What one call to a strategy returns: the tracks, in the order they should play, and whether
/// picking them had to fall back to genre/era scoring because sonic similarity had nothing to offer
/// — surfaced so the DJ sheet can say so, never to…
struct DJBatch {
    var tracks: [Track]
    var degraded: Bool

    static let empty = DJBatch(tracks: [], degraded: false)
}

/// One DJ.
protocol DJStrategy: Sendable {
    var kind: DJStrategyKind { get }
    var queuePolicy: DJQueuePolicy { get }
    /// Only consulted for `.sustain`/`.replace` policies — `.weave` strategies are always called
    /// with whatever is currently playing as the anchor, decided by `DJEngine` itself, so this is
    /// irrelevant to them.
    var anchorPolicy: DJAnchorPolicy { get }

    /// - Parameter anchor: the currently playing track — a strategy is free to ignore it (Gold does
    /// not care what is playing, only that it is rated well), but it is always the true "now." -
    /// Parameter excluding: the repeat-avoidance window's…
    func nextBatch(
        anchor: Track,
        excluding: Set<MediaID>,
        count: Int,
        context: DJContext
    ) async -> DJBatch
}

/// The one piece every similarity-leaning strategy shares: try sonic similarity, and when the
/// backend has none to give — no `.similarItems` capability, or a live call that came back thin —
/// fall back to genre and era scoring over a local…
enum DJSimilarity {
    /// Below this many results, a sonic answer is treated as too thin to trust on its own and the
    /// fallback pool is blended in behind it — an empty or near-empty result is a normal answer
    /// from an unanalysed library or an unwilling Navidrome…
    static let thinResultThreshold = 5

    /// Sonic neighbours of `anchor` where the backend has them, blended with a genre/era-scored
    /// local pool where it does not (or did not have enough) — always excluding `excluding`, always
    /// capped at `count`.
    static func rank(
        anchor: Track,
        excluding: Set<MediaID>,
        count: Int,
        context: DJContext
    ) async -> DJBatch {
        var sonic: [Track] = []
        var usedSonic = false
        if context.provider.capabilities.contains(.similarItems) {
            usedSonic = true
            let fetched = (try? await context.provider.similarTracks(to: anchor.id, limit: count * 3)) ?? []
            sonic = fetched.filter { !excluding.contains($0.id) && DJRatingFloor.passes($0, atLeast: LibraryIndex.favoriteRatingThreshold) }
        }

        guard sonic.count < Self.thinResultThreshold else {
            // Drawn from the list, not taken off the top of it.
            var generator = SystemRandomNumberGenerator()
            let places = Array(sonic.enumerated())
            let drawn = SmartShuffle.drawing(places, count: count, using: &generator) { place in
                Double(places.count - place.offset)
            }
            return DJBatch(tracks: drawn.map(\.element), degraded: false)
        }

        // Thin, or no sonic capability at all — fall back to the local
        // index, scored by genre family and era distance rather than left
        // unordered.
        let excludingSonic = excluding.union(sonic.map(\.id))
        let pool = (try? context.index.djFallbackPool(
            excluding: excludingSonic, limit: max(count * 4, 40), downloadedOnly: context.isOffline
        )) ?? []
        let ranked = DJSimilarityScore.rank(pool, against: anchor, genre: \.genre, year: \.year)
        let combined = sonic + ranked
        // Degraded whenever the fallback contributed anything at all — even a sonic-capable backend
        // that came back thin is a session running on a coarser signal for part of its picks, which
        // is exactly what the sheet's footnote exists to say honestly…
        let degraded = !ranked.isEmpty || !usedSonic
        return DJBatch(tracks: Array(combined.prefix(count)), degraded: degraded)
    }
}
