import Foundation

/// A colour as plain components, so this module stays free of UI frameworks
/// and can be tested on any platform.
public struct RGBColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The colour scheme derived from a piece of artwork.
public struct ArtworkColors: Hashable, Sendable, Codable {
    /// The page colour the artwork fades into.
    public var background: RGBColor
    /// True when the page is light enough to want black text; false for the
    /// dark pages that take white text.
    public var prefersDarkText: Bool
    /// Achieved contrast ratio between `background` and its text colour.
    public var textContrast: Double

    public init(background: RGBColor, prefersDarkText: Bool, textContrast: Double) {
        self.background = background
        self.prefersDarkText = prefersDarkText
        self.textContrast = textContrast
    }
}

public enum ArtworkColorAnalyzer {
    /// Minimum contrast ratio for white body text (WCAG AA).
    public static let minimumContrast = 4.5

    /// Picks the artwork's *dominant* colour rather than its average.
    public static func dominantColor(in pixels: [RGBColor]) -> RGBColor? {
        struct Bucket {
            var count = 0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var score = 0.0
        }
        var buckets: [Int: Bucket] = [:]

        for pixel in pixels {
            let color = hsb(pixel)
            if color.brightness < 0.10 { continue }
            if color.brightness > 0.95 && color.saturation < 0.12 { continue }

            // Three bits per channel groups shades of one colour without
            // merging genuinely different hues.
            let key = (Int(pixel.red * 7) << 6) | (Int(pixel.green * 7) << 3) | Int(pixel.blue * 7)
            var bucket = buckets[key] ?? Bucket()
            bucket.count += 1
            bucket.red += pixel.red
            bucket.green += pixel.green
            bucket.blue += pixel.blue
            let brightnessWeight = 1 - abs(color.brightness - 0.55) * 0.9
            bucket.score += (0.35 + color.saturation) * max(0.2, brightnessWeight)
            buckets[key] = bucket
        }

        guard let best = buckets.values.max(by: { $0.score < $1.score }), best.count > 0 else {
            return nil
        }
        return RGBColor(
            red: best.red / Double(best.count),
            green: best.green / Double(best.count),
            blue: best.blue / Double(best.count)
        )
    }

    /// Above this mean luminance the artwork reads as bright overall, and the
    /// page follows it rather than being forced dark.
    static let brightArtworkLuminance = 0.55

    /// Keeps the artwork's hue and commits to one side or the other: dark pages for most artwork,
    /// light pages for genuinely bright artwork.
    static let blackSleeveFraction = 0.5

    public static func readableColors(
        from color: RGBColor,
        artworkLuminance: Double? = nil,
        darkFraction: Double = 0
    ) -> ArtworkColors {
        let source = hsb(color)

        // A predominantly black sleeve gets a near-black page carrying only a
        // trace of the artwork's hue, rather than being coloured by whatever
        // bright object happens to sit on the black.
        if darkFraction > blackSleeveFraction {
            let adjusted = rgb(
                hue: source.hue,
                saturation: min(source.saturation, 0.50),
                brightness: 0.11
            )
            return ArtworkColors(
                background: adjusted,
                prefersDarkText: false,
                textContrast: contrastWithWhite(adjusted)
            )
        }

        let lightness = artworkLuminance ?? relativeLuminance(color)
        return lightness > brightArtworkLuminance
            ? lightScheme(hue: source.hue, saturation: source.saturation)
            : darkScheme(
                hue: source.hue,
                saturation: source.saturation,
                sourceBrightness: source.brightness
            )
    }

    /// The deepest a page starts before contrast is considered.
    static let darkSchemeCeiling = 0.55

    private static func darkScheme(
        hue: Double,
        saturation: Double,
        sourceBrightness: Double
    ) -> ArtworkColors {
        let saturation = min(max(saturation, 0.20), 0.85)
        // Start near the artwork's own brightness (capped) and come down only
        // as far as readable text demands, so the page keeps the colour's
        // character instead of being crushed to a uniform darkness.
        var brightness = min(sourceBrightness, darkSchemeCeiling)
        var adjusted = rgb(hue: hue, saturation: saturation, brightness: brightness)
        while contrastWithWhite(adjusted) < minimumContrast, brightness > 0.08 {
            brightness -= 0.02
            adjusted = rgb(hue: hue, saturation: saturation, brightness: brightness)
        }
        return ArtworkColors(
            background: adjusted,
            prefersDarkText: false,
            textContrast: contrastWithWhite(adjusted)
        )
    }

    private static func lightScheme(hue: Double, saturation: Double) -> ArtworkColors {
        // A saturated hue stays too dark for black text however bright it is,
        // so saturation comes down as brightness goes up.
        var saturation = min(saturation, 0.38)
        var brightness = 0.90
        var adjusted = rgb(hue: hue, saturation: saturation, brightness: brightness)
        while contrastWithBlack(adjusted) < minimumContrast, saturation > 0.04 {
            saturation -= 0.03
            brightness = min(0.98, brightness + 0.01)
            adjusted = rgb(hue: hue, saturation: saturation, brightness: brightness)
        }
        return ArtworkColors(
            background: adjusted,
            prefersDarkText: true,
            textContrast: contrastWithBlack(adjusted)
        )
    }

    /// The artwork's true colour along its bottom edge, unadjusted.
    public static func bottomEdgeColor(
        in pixels: [RGBColor],
        side: Int,
        bottomFraction: Double = 0.12,
        inset: Double = 0.07
    ) -> RGBColor? {
        guard side > 0, pixels.count >= side * side else { return nil }
        let margin = min(Int(Double(side) * inset), side / 4)
        let rows = max(1, Int(Double(side) * bottomFraction))
        let endRow = max(1, side - margin)
        let startRow = max(0, endRow - rows)
        let firstColumn = margin
        let lastColumn = max(firstColumn + 1, side - margin)

        var sample: [RGBColor] = []
        for row in startRow..<endRow {
            for column in firstColumn..<lastColumn {
                sample.append(pixels[row * side + column])
            }
        }
        guard !sample.isEmpty else { return nil }

        // A plain mean is right here: this must match what the eye sees at
        // the edge, not what the cover is "about".
        let count = Double(sample.count)
        let mean = RGBColor(
            red: sample.reduce(0) { $0 + $1.red } / count,
            green: sample.reduce(0) { $0 + $1.green } / count,
            blue: sample.reduce(0) { $0 + $1.blue } / count
        )

        // A busy edge — a collage, a crowd of colours — has no single colour to blend through, and
        // averaging one produces a muddy intermediate that matches neither the artwork nor the
        // page.
        let deviation = sample.reduce(0.0) { total, pixel in
            total + abs(pixel.red - mean.red)
                + abs(pixel.green - mean.green)
                + abs(pixel.blue - mean.blue)
        } / (count * 3)
        return deviation > maximumEdgeDeviation ? nil : mean
    }

    /// Mean absolute deviation above which a bottom edge counts as too varied
    /// to have a single colour.
    public static let maximumEdgeDeviation = 0.10

    /// Proportion of the artwork that is essentially black.
    public static func darkFraction(of pixels: [RGBColor], threshold: Double = 0.05) -> Double {
        guard !pixels.isEmpty else { return 0 }
        let dark = pixels.reduce(0) { $0 + (relativeLuminance($1) < threshold ? 1 : 0) }
        return Double(dark) / Double(pixels.count)
    }

    /// Mean luminance of the whole artwork, whites included.
    public static func meanLuminance(of pixels: [RGBColor]) -> Double {
        guard !pixels.isEmpty else { return 0 }
        return pixels.reduce(0.0) { $0 + relativeLuminance($1) } / Double(pixels.count)
    }

    /// Scheme for artwork with no usable colour.
    public static var neutral: ArtworkColors {
        let background = RGBColor(red: 0.13, green: 0.13, blue: 0.14)
        return ArtworkColors(
            background: background,
            prefersDarkText: false,
            textContrast: contrastWithWhite(background)
        )
    }

    // MARK: Colour maths

    public static func contrastWithWhite(_ color: RGBColor) -> Double {
        1.05 / (relativeLuminance(color) + 0.05)
    }

    public static func contrastWithBlack(_ color: RGBColor) -> Double {
        (relativeLuminance(color) + 0.05) / 0.05
    }

    /// WCAG contrast ratio between two arbitrary colours — the general form
    /// `contrastWithWhite`/`contrastWithBlack` are the fixed-colour cases of.
    public static func contrastRatio(_ first: RGBColor, _ second: RGBColor) -> Double {
        let lighter = relativeLuminance(first) + 0.05
        let darker = relativeLuminance(second) + 0.05
        return lighter > darker ? lighter / darker : darker / lighter
    }

    /// Minimum contrast for a marker against its background.
    public static let minimumMarkerContrast = 2.6

    /// Orange-red. What "hot" looks like.
    static let warmMarkerHue = 0.045
    /// Azure, most of the way round the wheel from `warmMarkerHue`.
    static let coolMarkerHue = 0.55
    /// Below this saturation a page has no hue of its own to clash with.
    static let markerClashSaturation = 0.15
    /// How close in hue a page has to be before the warm marker is lost in it.
    static let markerClashHueWindow = 0.09

    /// A vivid colour to mark something out against `background`, guaranteed legible rather than
    /// merely picked.
    public static func vividMarker(against background: RGBColor) -> RGBColor {
        let page = hsb(background)
        let clashes = page.saturation >= markerClashSaturation
            && hueDistance(warmMarkerHue, page.hue) < markerClashHueWindow
        let hue = clashes ? coolMarkerHue : warmMarkerHue

        // Lighter is the one to want — a hot track's number should look lit rather than burnt — but
        // a page in the middle of the luminance range has no light colour far enough from it, white
        // included.
        let lit = legible(hue: hue, against: background, goingLighter: true)
        if contrastRatio(lit, background) >= minimumMarkerContrast { return lit }
        let deep = legible(hue: hue, against: background, goingLighter: false)
        return contrastRatio(deep, background) > contrastRatio(lit, background) ? deep : lit
    }

    /// One hue taken as far towards the page's opposite end as it has to go to be read — lighter
    /// against a dark page, deeper against a light one.
    private static func legible(
        hue: Double,
        against background: RGBColor,
        goingLighter: Bool
    ) -> RGBColor {
        var saturation = 0.95
        var brightness = goingLighter ? 1.0 : 0.85
        var candidate = rgb(hue: hue, saturation: saturation, brightness: brightness)
        var steps = 0
        while contrastRatio(candidate, background) < minimumMarkerContrast, steps < 30 {
            if goingLighter {
                // Towards white, which the page already contrasts with.
                saturation = max(0.10, saturation - 0.04)
            } else {
                // Towards black, for the same reason.
                brightness = max(0.06, brightness - 0.035)
                saturation = min(1, saturation + 0.02)
            }
            candidate = rgb(hue: hue, saturation: saturation, brightness: brightness)
            steps += 1
        }
        return candidate
    }

    /// Distance round the hue circle, where 0.5 is opposite.
    static func hueDistance(_ first: Double, _ second: Double) -> Double {
        let raw = abs(first - second).truncatingRemainder(dividingBy: 1)
        return min(raw, 1 - raw)
    }

    /// WCAG relative luminance.
    public static func relativeLuminance(_ color: RGBColor) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red)
            + 0.7152 * channel(color.green)
            + 0.0722 * channel(color.blue)
    }

    public static func hsb(_ color: RGBColor) -> (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == color.red {
                hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == color.green {
                hue = (color.blue - color.red) / delta + 2
            } else {
                hue = (color.red - color.green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maximum == 0 ? 0 : delta / maximum, maximum)
    }

    public static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGBColor {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return RGBColor(red: brightness, green: t, blue: p)
        case 1: return RGBColor(red: q, green: brightness, blue: p)
        case 2: return RGBColor(red: p, green: brightness, blue: t)
        case 3: return RGBColor(red: p, green: q, blue: brightness)
        case 4: return RGBColor(red: t, green: p, blue: brightness)
        default: return RGBColor(red: brightness, green: p, blue: q)
        }
    }
}

/// Colours for an "ultrablurred" page background: the artwork reduced to a small grid of colours,
/// to be drawn as a smooth gradient rather than as a blurred copy of the bitmap.
public struct UltraBlurPalette: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    /// Row-major, `columns * rows` entries.
    public let colors: [RGBColor]

    public init(columns: Int, rows: Int, colors: [RGBColor]) {
        self.columns = columns
        self.rows = rows
        self.colors = colors
    }
}

extension ArtworkColorAnalyzer {
    /// Below this saturation a cell counts as having no colour of its own.
    static let ultraBlurChromaReference = 0.30
    /// Below this brightness a cell is too dark to carry a colour.
    static let ultraBlurLightReference = 0.22
    /// A dominant colour flatter than this is not a colour anyone would name,
    /// so nothing borrows its hue.
    static let ultraBlurMinimumDominantSaturation = 0.12
    /// The band every cell's brightness is compressed into.
    public static let ultraBlurFloor = 0.22
    public static let ultraBlurCeiling = 0.68

    /// Reduces artwork to a grid of colours for the ultrablurred background.
    public static func ultraBlurPalette(
        in pixels: [RGBColor],
        side: Int,
        columns: Int = 3,
        rows: Int = 3
    ) -> UltraBlurPalette? {
        guard side > 0, columns > 0, rows > 0, pixels.count == side * side else { return nil }

        let dominant = dominantColor(in: pixels)
        let dominantHSB = dominant.map(hsb)

        var colors: [RGBColor] = []
        colors.reserveCapacity(columns * rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let xRange = (column * side / columns)..<max(column * side / columns + 1, (column + 1) * side / columns)
                let yRange = (row * side / rows)..<max(row * side / rows + 1, (row + 1) * side / rows)

                var sum = RGBColor(red: 0, green: 0, blue: 0)
                var count = 0
                for y in yRange {
                    for x in xRange {
                        let pixel = pixels[y * side + x]
                        sum = RGBColor(
                            red: sum.red + pixel.red,
                            green: sum.green + pixel.green,
                            blue: sum.blue + pixel.blue
                        )
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let mean = RGBColor(
                    red: sum.red / Double(count),
                    green: sum.green / Double(count),
                    blue: sum.blue / Double(count)
                )
                colors.append(tinted(mean, towards: dominantHSB))
            }
        }

        guard colors.count == columns * rows else { return nil }
        return UltraBlurPalette(columns: columns, rows: rows, colors: colors)
    }

    /// One cell's colour, pulled towards the artwork's dominant hue in
    /// proportion to how little colour of its own it has.
    private static func tinted(
        _ mean: RGBColor,
        towards dominant: (hue: Double, saturation: Double, brightness: Double)?
    ) -> RGBColor {
        let (hue, saturation, brightness) = hsb(mean)
        // Compressed hard, into a mid-dark band.
        let lifted = ultraBlurFloor + brightness * (ultraBlurCeiling - ultraBlurFloor)
        let own = rgb(
            hue: hue,
            saturation: min(1, saturation * 1.5),
            brightness: lifted
        )

        // A cover with no colour of its own has no hue to lend. Without this
        // a greyscale sleeve came out tinted at the floor saturation below,
        // inventing a colour that is nowhere in the artwork.
        guard let dominant, dominant.saturation >= ultraBlurMinimumDominantSaturation else {
            return own
        }

        let chroma = min(1, saturation / ultraBlurChromaReference)
        let light = min(1, brightness / ultraBlurLightReference)
        // A cell keeps itself only if it is both light enough and colourful
        // enough to be worth keeping.
        let keep = min(chroma, light)
        let pull = 1 - keep
        guard pull > 0 else { return own }

        // Mixed at the same brightness, so borrowing the hue never changes
        // how light the cell is.
        let target = rgb(
            hue: dominant.hue,
            saturation: max(dominant.saturation, 0.5),
            brightness: lifted
        )
        return RGBColor(
            red: own.red + (target.red - own.red) * pull,
            green: own.green + (target.green - own.green) * pull,
            blue: own.blue + (target.blue - own.blue) * pull
        )
    }
}
