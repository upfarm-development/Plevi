import Foundation

/// The same rule `LibraryIndex`'s `ratingFloorSQL` applies in SQL, written once more so a DJ
/// strategy filtering an already-fetched `[Track]` — a similarity result from a provider, say,
/// which never touched SQL — can apply it too.
public enum DJRatingFloor {
    /// Unrated always passes — most libraries are mostly unrated, and reading silence as a bad
    /// review would starve every strategy.
    public static func passes(_ rating: StarRating?, atLeast threshold: Double) -> Bool {
        guard let rating else { return true }
        return rating.value >= threshold
    }

    public static func passes(_ track: Track, atLeast threshold: Double) -> Bool {
        passes(track.rating, atLeast: threshold)
    }

    /// The stricter rule Gold's own line uses, and `.highlyRated`'s SQL already uses ahead of it:
    /// unrated does *not* pass.
    public static func requiresRating(_ rating: StarRating?, atLeast threshold: Double) -> Bool {
        guard let rating else { return false }
        return rating.value >= threshold
    }

    public static func requiresRating(_ track: Track, atLeast threshold: Double) -> Bool {
        requiresRating(track.rating, atLeast: threshold)
    }
}
