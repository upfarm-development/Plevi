import Foundation
import PleviDomain
import PleviLibraryIndex

/// The current vibe, but only tracks rated four stars or better.
struct GoldStrategy: DJStrategy {
    let kind: DJStrategyKind = .gold
    let queuePolicy: DJQueuePolicy = .weave
    let anchorPolicy: DJAnchorPolicy = .live

    static let threshold = 4.0

    func nextBatch(
        anchor: Track, excluding: Set<MediaID>, count: Int, context: DJContext
    ) async -> DJBatch {
        let pool = (try? context.index.djGoldCandidates(
            atLeast: Self.threshold, excluding: excluding, limit: max(count * 3, 30),
            downloadedOnly: context.isOffline
        )) ?? []
        // If the pool has run dry, that is reported up rather than silently relaxed — see
        // DJEngine.topUp(), which is what actually tells the listener rather than quietly falling
        // back to a looser floor Gold does not claim to have.
        let ranked = DJSimilarityScore.rank(pool, against: anchor, genre: \.genre, year: \.year)
        return DJBatch(tracks: Array(ranked.prefix(count)), degraded: false)
    }
}
