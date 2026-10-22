import Foundation

/// Whether two artists' records come from close enough eras to belong in the same mix, judged by
/// when they actually made the music rather than when a label last pressed it.
public enum EraAffinity {
    /// How many years apart two artists' eras may sit and still belong together.
    public static let toleranceYears = 20

    /// Whether a candidate's era sits close enough to a seed's.
    public static func belongs(candidate: Int?, withSeed seed: Int?) -> Bool {
        guard let seed, let candidate else { return true }
        return abs(candidate - seed) <= toleranceYears
    }
}
