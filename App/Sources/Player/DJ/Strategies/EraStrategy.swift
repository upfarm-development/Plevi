import Foundation
import PleviDomain
import PleviLibraryIndex

/// Endless continuation constrained to the decade of the track playing when this DJ was turned on,
/// resolved the same era-aware way the rest of the app resolves a decade — so a 1970s song filed on
/// a 2010s compilation still anchors a 1970s…
struct EraStrategy: DJStrategy {
    let kind: DJStrategyKind = .era
    let queuePolicy: DJQueuePolicy = .sustain
    let anchorPolicy: DJAnchorPolicy = .sticky

    func nextBatch(
        anchor: Track, excluding: Set<MediaID>, count: Int, context: DJContext
    ) async -> DJBatch {
        guard let decade = Self.resolveDecade(for: anchor, index: context.index) else { return .empty }
        let pool = (try? context.index.djEraCandidates(
            decade: decade, excluding: excluding, limit: max(count * 3, 30), downloadedOnly: context.isOffline
        )) ?? []
        // Within the decade, ordered by how closely a candidate otherwise
        // matches the anchor — genre first, since two songs from the same
        // decade can still sound nothing alike.
        let ranked = DJSimilarityScore.rank(pool, against: anchor, genre: \.genre, year: \.year)
        return DJBatch(tracks: Array(ranked.prefix(count)), degraded: false)
    }

    /// Resolves one track's decade the way `LibraryIndex.decadeTracks` resolves thousands at once,
    /// but for a single anchor: fetch its album, assemble `TrackEra.Signals`, ask the same
    /// resolver.
    static func resolveDecade(for anchor: Track, index: LibraryIndex) -> Int? {
        let album = anchor.albumID.flatMap { try? index.albumDetail(id: $0)?.album }
        let looksLikeACompilation = CompilationHeuristics.isCompilation(
            serverFlag: album?.isCompilation ?? false,
            releaseTypes: album?.releaseTypes ?? [],
            albumTitle: album?.name,
            albumArtist: album?.artistName
        )
        let estimate: Int? = looksLikeACompilation
            ? anchor.artistName.flatMap { (try? index.activeEraByArtist())?[$0] }
            : nil
        let signals = TrackEra.Signals(track: anchor, album: album, artistEstimate: estimate)
        let classification = TrackEra.resolve(signals)
        // A low-confidence classification is exactly the case the era pipeline elsewhere drops
        // rather than guesses at — an anchor Era cannot place with any confidence has no decade
        // this DJ can honestly claim to be staying inside of.
        guard !classification.isLowConfidence else { return nil }
        return classification.decade
    }
}
