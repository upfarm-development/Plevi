import Foundation
import PleviDomain
import PleviLibraryIndex

/// Endless continuation constrained to the current track's genre.
struct PuristStrategy: DJStrategy {
    let kind: DJStrategyKind = .purist
    let queuePolicy: DJQueuePolicy = .sustain
    let anchorPolicy: DJAnchorPolicy = .sticky

    func nextBatch(
        anchor: Track, excluding: Set<MediaID>, count: Int, context: DJContext
    ) async -> DJBatch {
        guard let anchorGenre = anchor.genre, !anchorGenre.isEmpty else { return .empty }
        let family = GenreFamily.key(anchorGenre)
        let spellings = ((try? context.index.genres()) ?? [])
            .map(\.name)
            .filter { GenreFamily.key($0) == family }
        guard !spellings.isEmpty else { return .empty }

        let pool = (try? context.index.djGenreCandidates(
            matchingAnyOf: spellings, excluding: excluding, limit: max(count * 3, 30),
            downloadedOnly: context.isOffline
        )) ?? []
        let ranked = DJSimilarityScore.rank(pool, against: anchor, genre: \.genre, year: \.year)
        return DJBatch(tracks: Array(ranked.prefix(count)), degraded: false)
    }
}
