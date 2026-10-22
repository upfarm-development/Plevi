import Foundation
import PleviDomain

/// Abandons the plan: clears the upcoming queue and endlessly appends one track at a time, each
/// maximally similar to the last.
struct DriftStrategy: DJStrategy {
    let kind: DJStrategyKind = .drift
    let queuePolicy: DJQueuePolicy = .replace
    let anchorPolicy: DJAnchorPolicy = .live

    func nextBatch(
        anchor: Track, excluding: Set<MediaID>, count: Int, context: DJContext
    ) async -> DJBatch {
        await DJSimilarity.rank(anchor: anchor, excluding: excluding, count: count, context: context)
    }
}
