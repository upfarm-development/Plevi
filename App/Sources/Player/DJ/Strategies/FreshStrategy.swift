import Foundation
import PleviDomain
import PleviLibraryIndex

/// Weaves recently added tracks between familiar queue entries, choosing new tracks that match the
/// adjacent songs.
struct FreshStrategy: DJStrategy {
    let kind: DJStrategyKind = .fresh
    let queuePolicy: DJQueuePolicy = .weave
    let anchorPolicy: DJAnchorPolicy = .live

    /// Six months, not three.
    static let addedWithinDays = 180

    func nextBatch(
        anchor: Track, excluding: Set<MediaID>, count: Int, context: DJContext
    ) async -> DJBatch {
        let pool = (try? context.index.djFreshCandidates(
            addedWithinDays: Self.addedWithinDays, excluding: excluding, limit: max(count * 3, 30),
            downloadedOnly: context.isOffline
        )) ?? []
        let ranked = DJSimilarityScore.rank(pool, against: anchor, genre: \.genre, year: \.year)
        return DJBatch(tracks: Array(ranked.prefix(count)), degraded: false)
    }
}
