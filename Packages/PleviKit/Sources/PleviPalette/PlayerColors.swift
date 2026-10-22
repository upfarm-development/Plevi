/// The two colours a playing screen adds to the page it is drawn on.
/// Both are the record's own hue at a fixed lightness, so a warm cover gives a warm tan and a cold
/// one gives the same screen in blue.
public struct PlayerColors: Hashable, Sendable {
    /// The one bright colour: the played part of the scrubber, the stars, an
    /// active repeat, the output pill's fill.
    public var accent: RGBColor
    /// The play button's fill. Near-white with the record's warmth in it on a
    /// dark page; near-black on a light one, where a cream disc would vanish.
    public var button: RGBColor

    public init(accent: RGBColor, button: RGBColor) {
        self.accent = accent
        self.button = button
    }
}

extension ArtworkColorAnalyzer {
    /// How colourful the accent is allowed to get.
    static let playerAccentSaturation = 0.50
    /// The button carries only a trace of the hue; more and it reads as
    /// tinted rather than warm.
    static let playerButtonSaturation = 0.09

    /// The player's two colours for a record whose own colour is `seed`.
    public static func playerColors(from seed: RGBColor, isDarkPage: Bool = true) -> PlayerColors {
        let (hue, saturation, _) = hsb(seed)
        func shade(_ sat: Double, _ brightness: Double) -> RGBColor {
            rgb(hue: hue, saturation: sat, brightness: brightness)
        }
        return PlayerColors(
            accent: shade(min(saturation, playerAccentSaturation), isDarkPage ? 0.88 : 0.42),
            button: shade(min(saturation, playerButtonSaturation), isDarkPage ? 0.97 : 0.14)
        )
    }
}
