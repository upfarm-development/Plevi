import Foundation

/// Where a Journey is headed.
public enum DJDestination: Sendable, Hashable {
    case genre(String)
    case decade(Int)
    /// A specific track — or an artist, named by one representative track
    /// of theirs, `title`/`artist` carried along only so the destination
    /// can be shown back to the listener without a fresh lookup.
    case track(MediaID, title: String, artist: String?)
}

/// The bridge from a currently playing track to a Journey's destination: how much each step should
/// weigh "still sounds like where we started" against "sounds like where we are going," and the
/// destination-match score for the two destination…
public enum DJJourneyPath {
    /// How much step `k` of `n` should weigh the destination over the anchor — `k / n`, so step 0
    /// is entirely the anchor and step `n` (the last one) is almost entirely the destination.
    public static func destinationWeight(step: Int, of n: Int) -> Double {
        guard n > 0 else { return 1 }
        let clamped = max(0, min(step, n))
        return Double(clamped) / Double(n)
    }

    public static func anchorWeight(step: Int, of n: Int) -> Double {
        1 - destinationWeight(step: step, of: n)
    }

    /// The blended score a candidate earns at step `k` of `n`, given how well it already matches
    /// the anchor and how well it matches the destination.
    public static func blendedScore(
        anchorMatch: Double, destinationMatch: Double, step: Int, of n: Int
    ) -> Double {
        anchorMatch * anchorWeight(step: step, of: n) + destinationMatch * destinationWeight(step: step, of: n)
    }

    /// Local-data destination match for the two kinds that need no network call — `.genre` and
    /// `.decade`.
    public static func localDestinationMatch(
        _ destination: DJDestination, candidateGenre: String?, candidateYear: Int?
    ) -> Double? {
        switch destination {
        case .genre(let target):
            guard let candidateGenre, !candidateGenre.isEmpty else { return 0.5 }
            return GenreFamily.key(candidateGenre) == GenreFamily.key(target) ? 1 : 0
        case .decade(let target):
            guard let candidateYear else { return 0.5 }
            let candidateDecade = (candidateYear / 10) * 10
            guard candidateDecade != target else { return 1 }
            // Softens rather than cutting off at the decade line: a track one year either side of
            // the boundary is not "wrong," and a hard 0 there would make the last step of a Journey
            // land on a candidate that is arguably closer than one the score…
            let distance = abs(candidateDecade - target)
            return max(0, 1 - Double(distance) / 30)
        case .track:
            return nil
        }
    }
}
