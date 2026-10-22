import Foundation

/// The loudness metadata a file can carry, in the ReplayGain 2.0 sense.
public struct ReplayGainTags: Hashable, Sendable {
    public var trackGainDB: Double?
    public var trackPeak: Double?
    public var albumGainDB: Double?
    public var albumPeak: Double?

    public init(
        trackGainDB: Double? = nil,
        trackPeak: Double? = nil,
        albumGainDB: Double? = nil,
        albumPeak: Double? = nil
    ) {
        self.trackGainDB = trackGainDB
        self.trackPeak = trackPeak
        self.albumGainDB = albumGainDB
        self.albumPeak = albumPeak
    }

    public var isEmpty: Bool {
        trackGainDB == nil && albumGainDB == nil
    }
}

/// Which loudness reference to level to.
public enum ReplayGainMode: String, CaseIterable, Sendable {
    /// Every track to the same loudness. Right for shuffling.
    case track
    /// The album's own dynamics preserved; quiet interludes stay quiet.
    case album
    case off

    /// Album mode falls back to the track value, because plenty of files
    /// carry one and not the other.
    public var isEnabled: Bool { self != .off }
}

/// Works out the gain to apply so tracks play at a consistent loudness.
public enum ReplayGain {
    /// Applied on top of the tags, so material mastered quietly does not
    /// leave the whole app sounding timid. Matches the usual default.
    public static let defaultPreampDB: Double = 0

    /// What a file with no tags at all gets. Silence would be wrong and full
    /// gain would be inconsistent, so it plays untouched.
    public static let untaggedGainDB: Double = 0

    /// The most the peak limiter is asked to hold back, so a badly tagged
    /// file cannot mute itself.
    public static let minimumGainDB: Double = -24
    public static let maximumGainDB: Double = 24

    /// The gain in decibels for these tags.
    public static func gainDB(
        for tags: ReplayGainTags,
        mode: ReplayGainMode,
        preampDB: Double = defaultPreampDB,
        preventClipping: Bool = true
    ) -> Double {
        guard mode.isEnabled else { return 0 }

        // Album mode prefers the album gain but takes the track's when the file only carries one —
        // better than levelling nothing.
        let tagged: Double?
        let peak: Double?
        switch mode {
        case .album:
            tagged = firstNumber(tags.albumGainDB, tags.trackGainDB)
            peak = firstNumber(tags.albumPeak, tags.trackPeak)
        case .track, .off:
            tagged = firstNumber(tags.trackGainDB, tags.albumGainDB)
            peak = firstNumber(tags.trackPeak, tags.albumPeak)
        }

        guard let tagged else { return untaggedGainDB }

        var gain = tagged + (preampDB.isNaN ? 0 : preampDB)
        if preventClipping, let peak, peak > 0 {
            // The headroom left above the loudest sample, in dB. A peak of
            // 1.0 leaves none, so any positive gain has to come back off.
            let headroomDB = -20 * log10(peak)
            gain = min(gain, headroomDB)
        }
        // +inf plus -inf is NaN however each was clamped on the way in.
        guard !gain.isNaN else { return untaggedGainDB }
        return min(max(gain, minimumGainDB), maximumGainDB)
    }

    /// The first of these that is a number at all. Infinities are numbers here:
    /// the final clamp holds them to the documented floor and ceiling.
    private static func firstNumber(_ first: Double?, _ second: Double?) -> Double? {
        if let first, !first.isNaN { return first }
        if let second, !second.isNaN { return second }
        return nil
    }

    /// The same figure as a linear multiplier, which is what a mixer wants.
    public static func linearGain(
        for tags: ReplayGainTags,
        mode: ReplayGainMode,
        preampDB: Double = defaultPreampDB,
        preventClipping: Bool = true
    ) -> Float {
        let db = gainDB(for: tags, mode: mode, preampDB: preampDB, preventClipping: preventClipping)
        return Float(pow(10, db / 20))
    }

    /// Parses the tag values servers hand back, which are strings like
    /// `"-7.30 dB"` or plain numbers depending on where they came from.
    public static func parseGain(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "dB", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        // `Double("nan")` and `Double("inf")` both succeed; neither is a gain.
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    public static func parsePeak(_ raw: String?) -> Double? {
        guard let value = parseGain(raw), value > 0 else { return nil }
        return value
    }
}
