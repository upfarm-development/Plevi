import Foundation
import PleviDomain

/// Keeps the mood going by weaving a handful of similar tracks in right after whatever is playing.
struct MoodyStrategy: DJStrategy {
    let kind: DJStrategyKind = .moody
    let queuePolicy: DJQueuePolicy = .weave
    let anchorPolicy: DJAnchorPolicy = .live

    func nextBatch(
        anchor: Track, excluding: Set<MediaID>, count: Int, context: DJContext
    ) async -> DJBatch {
        await DJSimilarity.rank(anchor: anchor, excluding: excluding, count: count, context: context)
    }
}
