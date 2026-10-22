import Foundation

/// A ten-band graphic equaliser, described independently of AVFoundation so the settings, the
/// presets and their arithmetic can be tested anywhere.
public enum Equalizer {
    public static let bandFrequencies: [Double] = [
        32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000,
    ]

    public static let bandCount = bandFrequencies.count

    /// Bands are cut or boosted within this range, in decibels.
    public static let minimumGainDB: Double = -12
    public static let maximumGainDB: Double = 12

    /// Bandwidth in octaves. One octave per band is the standard choice for
    /// a ten-band graphic: narrow enough to shape, wide enough that adjacent
    /// bands overlap into a smooth curve rather than a comb.
    public static let bandwidthInOctaves: Float = 1.0

    public static func clamp(_ gainDB: Double) -> Double {
        // Swift's min and max pass a NaN through, and a corrupt saved preset
        // would then hand one to the filters.
        guard !gainDB.isNaN else { return 0 }
        return min(max(gainDB, minimumGainDB), maximumGainDB)
    }

    /// A label for a band centre: "32", "1k", "16k".
    public static func label(forFrequency frequency: Double) -> String {
        guard frequency >= 1_000 else { return String(Int(frequency)) }
        let thousands = frequency / 1_000
        let rounded = thousands.rounded()
        if abs(thousands - rounded) < 0.05 {
            return "\(Int(rounded))k"
        }
        return String(format: "%.1fk", thousands)
    }
}

/// One named curve across the ten bands.
public struct EqualizerPreset: Hashable, Sendable, Identifiable, Codable {
    public var id: String { name }
    public let name: String
    /// One gain per band, in the order of `Equalizer.bandFrequencies`.
    public let gainsDB: [Double]

    public init(name: String, gainsDB: [Double]) {
        self.name = name
        // Clamped and padded on the way in, so a preset from anywhere — a
        // file, a future import — can never produce a graph that misbehaves.
        var normalised = gainsDB.prefix(Equalizer.bandCount).map(Equalizer.clamp)
        while normalised.count < Equalizer.bandCount { normalised.append(0) }
        self.gainsDB = normalised
    }

    public var isFlat: Bool {
        gainsDB.allSatisfy { $0 == 0 }
    }

    public static let flat = EqualizerPreset(
        name: "Flat",
        gainsDB: Array(repeating: 0, count: Equalizer.bandCount)
    )

    /// Deliberately gentle. Presets that swing ±10 dB sound impressive for a
    /// second and fatiguing after a minute, and they leave no headroom.
    public static let builtIn: [EqualizerPreset] = [
        .flat,
        EqualizerPreset(name: "Bass Boost", gainsDB: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: "Bass Cut", gainsDB: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: "Treble Boost", gainsDB: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        EqualizerPreset(name: "Vocal", gainsDB: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        EqualizerPreset(name: "Loudness", gainsDB: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
        EqualizerPreset(name: "Podcast", gainsDB: [-4, -3, 0, 3, 4, 4, 3, 2, 0, -2]),
        EqualizerPreset(name: "Classical", gainsDB: [3, 2, 0, 0, 0, 0, -1, -1, 0, 2]),
    ]
}
