import Foundation
import Testing
@testable import PleviPalette

@Suite struct PlayerColorsTests {
    /// Hex, so a failure prints something you can paste into a colour picker
    /// rather than three fractions.
    private static func hex(_ color: RGBColor) -> String {
        String(
            format: "%02X%02X%02X",
            Int((color.red * 255).rounded()),
            Int((color.green * 255).rounded()),
            Int((color.blue * 255).rounded())
        )
    }

    /// Channels within `tolerance` of the target, counted in 0–255 steps so
    /// the number in the test means what it does in a colour picker.
    private static func expect(_ color: RGBColor, near target: String, within tolerance: Int = 3) {
        let produced = hex(color)
        let channels = { (value: String) in
            stride(from: 0, to: 6, by: 2).map {
                Int(value[value.index(value.startIndex, offsetBy: $0)...]
                    .prefix(2), radix: 16) ?? -1
            }
        }
        let a = channels(produced)
        let b = channels(target)
        let off = zip(a, b).map { abs($0 - $1) }.max() ?? 999
        #expect(off <= tolerance, "\(produced) is \(off) away from \(target)")
    }

    /// The screen was designed against one record — a warm brown cover — and these are the colours
    /// that design asks for.
    @Test func aWarmCoverGivesTheColoursTheDesignAsksFor() {
        // A dark warm brown, which is what the analysis returns for a sleeve
        // of that kind.
        let seed = ArtworkColorAnalyzer.rgb(hue: 0.058, saturation: 0.45, brightness: 0.30)
        let colors = ArtworkColorAnalyzer.playerColors(from: seed)

        // Wider than exact, and deliberately so: the design's own colours are
        // not quite on one hue — its grounds sit at 21° and its accent at
        // 27° — while these are struck from the record's single hue.
        Self.expect(colors.accent, near: "E0A97C", within: 12)
        Self.expect(colors.button, near: "F7ECE4", within: 6)
    }

    /// A grey record gets a grey screen. The saturations are ceilings on the
    /// cover's own rather than values of their own precisely so that nothing
    /// here paints a colour onto a sleeve that has none.
    @Test func aGreyCoverKeepsItsGrey() {
        let seed = RGBColor(red: 0.31, green: 0.31, blue: 0.31)
        for dark in [true, false] {
            let colors = ArtworkColorAnalyzer.playerColors(from: seed, isDarkPage: dark)
            for color in [colors.accent, colors.button] {
                #expect(color.red == color.green)
                #expect(color.green == color.blue)
            }
        }
    }

    /// Contrast ratio between two colours, WCAG's definition.
    private static func contrast(_ a: RGBColor, _ b: RGBColor) -> Double {
        let first = ArtworkColorAnalyzer.relativeLuminance(a) + 0.05
        let second = ArtworkColorAnalyzer.relativeLuminance(b) + 0.05
        return max(first, second) / min(first, second)
    }

    /// Both colours have to show on the page they are drawn on, and the page is not always dark:
    /// the album pages hand back a light one for a light cover, and the playing screen now sits on
    /// the same background.
    @Test func bothColoursShowOnThePageTheyAreDrawnOn() {
        for hueStep in 0..<24 {
            for saturationStep in 0...4 {
                let seed = ArtworkColorAnalyzer.rgb(
                    hue: Double(hueStep) / 24,
                    saturation: Double(saturationStep) / 4,
                    brightness: 0.5
                )
                let darkPage = RGBColor(red: 0.10, green: 0.10, blue: 0.10)
                let lightPage = RGBColor(red: 0.93, green: 0.93, blue: 0.93)

                let onDark = ArtworkColorAnalyzer.playerColors(from: seed, isDarkPage: true)
                #expect(Self.contrast(onDark.accent, darkPage) > 3,
                        "accent \(Self.hex(onDark.accent)) on a dark page")
                #expect(Self.contrast(onDark.button, darkPage) > 3,
                        "button \(Self.hex(onDark.button)) on a dark page")

                let onLight = ArtworkColorAnalyzer.playerColors(from: seed, isDarkPage: false)
                #expect(Self.contrast(onLight.accent, lightPage) > 3,
                        "accent \(Self.hex(onLight.accent)) on a light page")
                #expect(Self.contrast(onLight.button, lightPage) > 3,
                        "button \(Self.hex(onLight.button)) on a light page")
            }
        }
    }

    /// The button is a disc with a glyph cut out of it, and the glyph is the
    /// page's own colour — so the two ends have to stay at opposite ends.
    @Test func theButtonFlipsWithThePage() {
        let seed = ArtworkColorAnalyzer.rgb(hue: 0.058, saturation: 0.45, brightness: 0.30)
        let onDark = ArtworkColorAnalyzer.playerColors(from: seed, isDarkPage: true)
        let onLight = ArtworkColorAnalyzer.playerColors(from: seed, isDarkPage: false)
        #expect(ArtworkColorAnalyzer.hsb(onDark.button).brightness > 0.9)
        #expect(ArtworkColorAnalyzer.hsb(onLight.button).brightness < 0.2)
        #expect(ArtworkColorAnalyzer.hsb(onDark.accent).brightness
                > ArtworkColorAnalyzer.hsb(onLight.accent).brightness)
    }
}
