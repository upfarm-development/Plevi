import Foundation

/// How much of a file that is still arriving the engine may hand to the node, for a file whose
/// reported length cannot be believed (`GrowingFile.declaresLength`).
public enum GrowthPlan {
    /// How far ahead of the play head audio is decoded and held, in seconds.
    /// Decoded audio sits in memory until it plays, so this is bounded.
    public static let lookaheadSeconds: Double = 30
    /// The most decoded in one look, in seconds.
    public static let passSeconds: Double = 15
    /// The file is looked at again only once this many new bytes have arrived.
    public static let minimumNewBytes: Int64 = 32 * 1024

    /// The frame the incomplete file may be scheduled up to, at most.
    public static func decodeLimit(declared: Int64, holdFrames: Int64, sampleRate: Double) -> Int64 {
        guard declared > 0 else { return 0 }
        guard holdFrames > 0, declared > holdFrames * 2 else { return declared }
        let margin = Int64(sampleRate.rounded(.up))
        return max(0, declared - holdFrames * 2 - margin)
    }

    /// How many frames to try to read now, from `cursor`, towards `limit`:
    /// nothing while enough is already held ahead of the play head.
    public static func readBudget(
        cursor: Int64,
        limit: Int64,
        playhead: TimeInterval,
        sampleRate: Double
    ) -> Int64 {
        guard sampleRate > 0, cursor < limit else { return 0 }
        let ahead = Double(cursor) / sampleRate - playhead
        guard ahead < lookaheadSeconds else { return 0 }
        return min(limit - cursor, Int64(passSeconds * sampleRate))
    }

    /// Whether a look is worth making: the last one found the end of the
    /// bytes, and nothing new has arrived since.
    public static func shouldLook(size: Int64, lastLookSize: Int64?, lastLookNeededData: Bool) -> Bool {
        guard lastLookNeededData, let lastLookSize else { return true }
        return size - lastLookSize >= minimumNewBytes
    }

    /// The furthest a seek may land in a file that is still arriving, in
    /// frames: what has been decoded, or — once the file is complete — the
    /// declared end.
    public static func seekCeiling(decodedThrough: Int64, declared: Int64, complete: Bool) -> Int64 {
        complete ? declared : min(decodedThrough, declared)
    }
}
