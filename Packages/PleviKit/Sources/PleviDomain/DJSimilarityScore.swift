import Foundation

/// How close two tracks are, when nothing has told us how they actually sound.
public enum DJSimilarityScore {
    /// Roughly a generation, matching `EraAffinity.toleranceYears` — not reused directly because
    /// that type compares an *artist's* median era against another artist's, and this compares two
    /// already-resolved *track* years (from `TrackEra.resolve`)…
    public static let eraToleranceYears = 20

    /// 0 (nothing in common) to 1 (same genre family, same year).
    public static func score(
        candidateGenre: String?, candidateYear: Int?,
        anchorGenre: String?, anchorYear: Int?
    ) -> Double {
        let genreScore: Double
        if let candidateGenre, let anchorGenre,
           !candidateGenre.isEmpty, !anchorGenre.isEmpty {
            genreScore = GenreFamily.key(candidateGenre) == GenreFamily.key(anchorGenre) ? 1 : 0
        } else {
            genreScore = 0.5
        }

        let eraScore: Double
        if let candidateYear, let anchorYear {
            let distance = abs(candidateYear - anchorYear)
            eraScore = distance >= eraToleranceYears
                ? 0
                : 1 - (Double(distance) / Double(eraToleranceYears))
        } else {
            eraScore = 0.5
        }

        return (genreScore + eraScore) / 2
    }

    /// Highest score first.
    public static func rank<T>(
        _ candidates: [T], against anchor: T, genre: (T) -> String?, year: (T) -> Int?
    ) -> [T] {
        let anchorGenre = genre(anchor)
        let anchorYear = year(anchor)
        return candidates.sorted { a, b in
            score(candidateGenre: genre(a), candidateYear: year(a), anchorGenre: anchorGenre, anchorYear: anchorYear)
                > score(candidateGenre: genre(b), candidateYear: year(b), anchorGenre: anchorGenre, anchorYear: anchorYear)
        }
    }
}
