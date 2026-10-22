import Foundation
import PleviDomain
import PleviLibraryIndex

/// The one DJ that does not conform to `DJStrategy`, deliberately: every other strategy answers one
/// question — "given this anchor, what plays next" — and Journey answers a genuinely different one
/// — "given this anchor, this destination, and…
enum JourneyStrategy {
    /// One track for one step of the bridge.
    static func nextTrack(
        anchor: Track,
        destination: DJDestination,
        step: Int,
        of length: Int,
        excluding: Set<MediaID>,
        excludingSongs: Set<String> = [],
        context: DJContext
    ) async -> (track: Track?, degraded: Bool) {
        var degraded = false
        func passesFilter(_ track: Track) -> Bool {
            guard !excluding.contains(track.id) else { return false }
            let keys = DJRepeatWindow.songKeys(for: track)
            if !keys.isEmpty, !keys.isDisjoint(with: excludingSongs) { return false }
            return DJRatingFloor.passes(track, atLeast: LibraryIndex.favoriteRatingThreshold)
        }
        var pool: [Track] = []
        if context.provider.capabilities.contains(.similarItems) {
            let fetched = (try? await context.provider.similarTracks(to: anchor.id, limit: 30)) ?? []
            pool = fetched.filter(passesFilter)
        }
        // Widened with the local pool rather than left thin — a bridge this close to its
        // destination often wants candidates a sonic lookup on the *anchor* alone would never
        // surface, since by then the destination should be weighing far more than the…
        if pool.count < DJSimilarity.thinResultThreshold {
            degraded = true
            let fallback = (try? context.index.djFallbackPool(
                excluding: excluding.union(pool.map(\.id)), limit: 60, downloadedOnly: context.isOffline
            )) ?? []
            pool += fallback.filter(passesFilter)
        }
        guard !pool.isEmpty else { return (nil, degraded) }

        func anchorMatch(_ candidate: Track) -> Double {
            DJSimilarityScore.score(
                candidateGenre: candidate.genre, candidateYear: candidate.year,
                anchorGenre: anchor.genre, anchorYear: anchor.year
            )
        }

        let destinationMatch = await Self.destinationMatcher(for: destination, context: context)

        let best = pool.max { a, b in
            DJJourneyPath.blendedScore(anchorMatch: anchorMatch(a), destinationMatch: destinationMatch(a), step: step, of: length)
                < DJJourneyPath.blendedScore(anchorMatch: anchorMatch(b), destinationMatch: destinationMatch(b), step: step, of: length)
        }
        return (best, degraded)
    }

    /// A scorer for one destination, built once per call rather than once per candidate — a
    /// `.track` destination's own similarity neighbours are fetched a single time and reused as a
    /// lookup set for the whole pool.
    private static func destinationMatcher(
        for destination: DJDestination, context: DJContext
    ) async -> (Track) -> Double {
        switch destination {
        case .genre, .decade:
            return { candidate in
                DJJourneyPath.localDestinationMatch(
                    destination, candidateGenre: candidate.genre, candidateYear: candidate.year
                ) ?? 0.5
            }
        case .track(let destinationID, _, _):
            let destinationTrack = try? context.index.track(id: destinationID)
            var neighbourIDs: Set<MediaID> = []
            if context.provider.capabilities.contains(.similarItems) {
                let neighbours = (try? await context.provider.similarTracks(to: destinationID, limit: 60)) ?? []
                neighbourIDs = Set(neighbours.map(\.id))
            }
            return { candidate in
                if candidate.id == destinationID { return 1 }
                if neighbourIDs.contains(candidate.id) { return 0.8 }
                guard let destinationTrack else { return 0.5 }
                // No sonic signal for this particular candidate against the destination — genre/era
                // against the destination track itself stands in, the same fallback every other
                // similarity question in this feature uses.
                return DJSimilarityScore.score(
                    candidateGenre: candidate.genre, candidateYear: candidate.year,
                    anchorGenre: destinationTrack.genre, anchorYear: destinationTrack.year
                )
            }
        }
    }

    static func hasArrived(step: Int, of length: Int) -> Bool {
        step >= length
    }
}
