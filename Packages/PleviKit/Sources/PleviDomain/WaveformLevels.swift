import Foundation

/// How a measured level becomes a height in the seek bar.
public enum WaveformLevels {
    /// Stored as measured, with no lift: the amplitude *is* the level, and
    /// how tall that draws is the view's business. Keeping the stored shape
    /// honest means the look can be tuned without re-analysing every track.
    public static func forDisplay(_ amplitude: Float) -> Float {
        min(1, max(0, amplitude))
    }
}
