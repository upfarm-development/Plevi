import Foundation

/// What the end of the audio on a player node means, decided from a handful of facts about the
/// engine so it can be tested without one.
public enum TrackEnd {
    public enum FinishOutcome: Equatable, Sendable {
        /// A completion from a superseded segment or from the deck that is no
        /// longer the current one.
        case ignore
        /// The next track was queued behind this one and is now playing.
        case join
        /// The track ended while playing: report it.
        case ended
        /// The track ran out while not playing (a paused seek to the end):
        /// nothing to report yet, but remember it.
        case endedSilently
    }

    public static func onFinish(
        generationMatches: Bool,
        deckMatches: Bool,
        isPlaying: Bool,
        hasPendingNext: Bool
    ) -> FinishOutcome {
        guard generationMatches, deckMatches else { return .ignore }
        guard isPlaying else { return hasPendingNext ? .ignore : .endedSilently }
        return hasPendingNext ? .join : .ended
    }

    /// Whether the stretch that has just finished playing is the end of the track, for a file that
    /// was scheduled as it arrived.
    public static func stretchEndsTrack(
        growthComplete: Bool,
        pendingStretches: Int,
        tailHeld: Bool
    ) -> Bool {
        growthComplete && pendingStretches == 0 && !tailHeld
    }

    public enum PlayOutcome: Equatable, Sendable {
        case ignore
        /// Start the node.
        case resume
        /// The track has already ended: report that, do not start the node.
        case finishNow
    }

    public static func onPlay(hasFile: Bool, drained: Bool) -> PlayOutcome {
        guard hasFile else { return .ignore }
        return drained ? .finishNow : .resume
    }
}

/// Position arithmetic for the render clock.
public enum RenderClock {
    /// How many frames of the node's clock `fileFrames` frames of a file take up.
    public static func nodeFrames(
        fileFrames: Int64, fileRate: Double, nodeRate: Double
    ) -> Int64 {
        guard fileFrames > 0, fileRate > 0, nodeRate > 0 else { return max(0, fileFrames) }
        return Int64((Double(fileFrames) * nodeRate / fileRate).rounded())
    }
}

/// What a FLAC file says about itself in its first metadata block.
public enum FlacStreamInfo {
    public struct Info: Equatable, Sendable {
        public var sampleRate: Int
        public var channels: Int
        public var bitsPerSample: Int
    }

    /// Reads the start of a FLAC file — at least 22 bytes past any ID3 tag in
    /// front of it. Nil for anything that is not one, or is too short to say.
    public static func read(from data: Data) -> Info? {
        var bytes = [UInt8](data.prefix(4096))
        // An ID3v2 tag in front of the stream is allowed and skipped.
        if bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let size = (Int(bytes[6] & 0x7F) << 21) | (Int(bytes[7] & 0x7F) << 14)
                | (Int(bytes[8] & 0x7F) << 7) | Int(bytes[9] & 0x7F)
            let start = 10 + size
            guard start < bytes.count else { return nil }
            bytes = Array(bytes[start...])
        }
        // "fLaC", then a metadata block header whose type is 0 (STREAMINFO).
        guard bytes.count >= 22,
              bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43,
              bytes[4] & 0x7F == 0
        else { return nil }
        // Bytes 18...21 of the file hold: 20 bits of sample rate, 3 of channels
        // less one, 5 of bits per sample less one.
        let rate = (Int(bytes[18]) << 12) | (Int(bytes[19]) << 4) | (Int(bytes[20]) >> 4)
        let channels = Int((bytes[20] >> 1) & 0x07) + 1
        let bits = (Int(bytes[20] & 0x01) << 4 | Int(bytes[21] >> 4)) + 1
        guard rate > 0, (4...32).contains(bits) else { return nil }
        return Info(sampleRate: rate, channels: channels, bitsPerSample: bits)
    }
}
