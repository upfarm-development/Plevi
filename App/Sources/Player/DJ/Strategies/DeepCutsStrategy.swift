import Foundation
import PleviDomain
import PleviLibraryIndex

/// Stays close to the current vibe, but only offers what is barely played.
struct DeepCutsStrategy: DJStrategy {
    let kind: DJStrategyKind = .deepCuts
    let queuePolicy: DJQueuePolicy = .weave
    let anchorPolicy: DJAnchorPolicy = .live

    /// Two plays or fewer — "songs you never play," a little more forgiving
    /// than the app's existing Deep Cuts radio (barely played, default 1),
    /// since this DJ is meant to keep finding them for as long as it runs.
    static let playsAtMost = 2

    func nextBatch(
        anchor: Track, excluding: Set<MediaID>, count: Int, context: DJContext
    ) async -> DJBatch {
        let pool = (try? context.index.djDeepCutsCandidates(
            playsAtMost: Self.playsAtMost, excluding: excluding, limit: max(count * 3, 30),
            downloadedOnly: context.isOffline
        )) ?? []
        let ranked = DJSimilarityScore.rank(pool, against: anchor, genre: \.genre, year: \.year)
        return DJBatch(tracks: Array(ranked.prefix(count)), degraded: false)
    }
}
