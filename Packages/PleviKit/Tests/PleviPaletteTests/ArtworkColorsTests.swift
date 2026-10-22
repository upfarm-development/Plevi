import Foundation
import Testing
@testable import PleviPalette

@Suite struct ContrastGuaranteeTests {
    /// The whole point of the adjustment: whatever the artwork, the text on the resulting page must
    /// be readable.
    @Test func everyColourProducesReadableText() {
        for hueStep in 0..<24 {
            for saturationStep in 0...4 {
                for brightnessStep in 0...4 {
                    let source = ArtworkColorAnalyzer.rgb(
                        hue: Double(hueStep) / 24,
                        saturation: Double(saturationStep) / 4,
                        brightness: 0.2 + Double(brightnessStep) / 5
                    )
                    let colors = ArtworkColorAnalyzer.readableColors(from: source)
                    #expect(
                        colors.textContrast >= ArtworkColorAnalyzer.minimumContrast,
                        """
                        hue \(hueStep)/24 sat \(saturationStep)/4 bri \(brightnessStep)/5 \
                        produced contrast \(colors.textContrast)
                        """
                    )
                }
            }
        }
    }

    @Test func brightArtworkKeepsALightPageWithDarkText() {
        // A pale yellow sleeve should not be forced into a dark page.
        let paleYellow = RGBColor(red: 0.97, green: 0.94, blue: 0.62)
        let colors = ArtworkColorAnalyzer.readableColors(from: paleYellow)
        #expect(colors.prefersDarkText)
        #expect(ArtworkColorAnalyzer.relativeLuminance(colors.background) > 0.5)
    }

    @Test func ordinaryArtworkLandsDarkWithWhiteText() {
        let midRed = RGBColor(red: 0.72, green: 0.16, blue: 0.18)
        let colors = ArtworkColorAnalyzer.readableColors(from: midRed)
        #expect(!colors.prefersDarkText)
        #expect(ArtworkColorAnalyzer.relativeLuminance(colors.background) < 0.2)
    }

    @Test func hueIsPreservedThroughAdjustment() {
        let sourceHue = ArtworkColorAnalyzer.hsb(RGBColor(red: 0.1, green: 0.3, blue: 0.8)).hue
        let adjusted = ArtworkColorAnalyzer.readableColors(
            from: RGBColor(red: 0.1, green: 0.3, blue: 0.8)
        )
        let resultHue = ArtworkColorAnalyzer.hsb(adjusted.background).hue
        #expect(abs(resultHue - sourceHue) < 0.02, "the page should keep the artwork's hue")
    }

    @Test func neutralSchemeIsAlsoReadable() {
        #expect(ArtworkColorAnalyzer.neutral.textContrast >= ArtworkColorAnalyzer.minimumContrast)
    }
}

/// Real covers that produced poor results, kept as regression cases.
@Suite struct RealArtworkCaseTests {
    /// Roughly the dominant colour of each sleeve.
    private let orangeSleeve = RGBColor(red: 0.82, green: 0.41, blue: 0.12)   // Ed Sheeran "+"
    private let amberSleeve = RGBColor(red: 0.91, green: 0.60, blue: 0.22)    // Coldplay single
    private let yellowSleeve = RGBColor(red: 0.95, green: 0.90, blue: 0.20)   // Ed Sheeran "-"
    private let redSleeve = RGBColor(red: 0.85, green: 0.10, blue: 0.08)      // Ed Sheeran "="
    private let monochrome = RGBColor(red: 0.42, green: 0.42, blue: 0.43)     // band photo

    /// The reported failure: vivid orange sleeves came out as muddy brown
    /// because every dark page was forced to the same low brightness.
    @Test func warmSleevesKeepTheirColour() {
        for sleeve in [orangeSleeve, amberSleeve] {
            let colors = ArtworkColorAnalyzer.readableColors(from: sleeve)
            let result = ArtworkColorAnalyzer.hsb(colors.background)
            let source = ArtworkColorAnalyzer.hsb(sleeve)

            #expect(abs(result.hue - source.hue) < 0.03, "hue drifted")
            #expect(result.saturation > 0.55, "washed out to brown: \(result.saturation)")
            #expect(
                result.brightness > 0.30,
                "crushed too dark to read as orange: \(result.brightness)"
            )
            #expect(colors.textContrast >= ArtworkColorAnalyzer.minimumContrast)
        }
    }

    @Test func brightYellowSleeveGoesLightWithDarkText() {
        let colors = ArtworkColorAnalyzer.readableColors(from: yellowSleeve)
        // Yellow is too luminous to carry white text at any useful
        // brightness, so the page goes light instead.
        #expect(colors.prefersDarkText)
        #expect(colors.textContrast >= ArtworkColorAnalyzer.minimumContrast)
    }

    @Test func redSleeveStaysRed() {
        let colors = ArtworkColorAnalyzer.readableColors(from: redSleeve)
        let result = ArtworkColorAnalyzer.hsb(colors.background)
        #expect(!colors.prefersDarkText)
        #expect(result.saturation > 0.6)
        #expect(colors.background.red > colors.background.green * 2)
        #expect(colors.textContrast >= ArtworkColorAnalyzer.minimumContrast)
    }

    /// Zara Larsson "1": a mostly-white sleeve whose only strong colours are
    /// blonde hair and skin. Judging lightness from those alone produced a
    /// dark brown page for an obviously bright cover.
    @Test func paleSleeveWithWarmDetailStaysLight() {
        let tan = RGBColor(red: 0.72, green: 0.58, blue: 0.38)
        let colors = ArtworkColorAnalyzer.readableColors(
            from: tan,
            // Mostly white artwork.
            artworkLuminance: 0.71
        )
        #expect(colors.prefersDarkText, "a predominantly white sleeve should not go dark")
        #expect(ArtworkColorAnalyzer.relativeLuminance(colors.background) > 0.5)
        #expect(colors.textContrast >= ArtworkColorAnalyzer.minimumContrast)
    }

    /// The same hue on a genuinely dark cover must still go dark — the
    /// lightness decision has to come from the artwork, not the hue.
    @Test func sameHueOnADarkSleeveStillGoesDark() {
        let tan = RGBColor(red: 0.72, green: 0.58, blue: 0.38)
        let colors = ArtworkColorAnalyzer.readableColors(from: tan, artworkLuminance: 0.18)
        #expect(!colors.prefersDarkText)
    }

    /// Coldplay "Parachutes": a black sleeve with a glowing orange globe. The
    /// globe covers a fraction of the cover but was deciding the page colour,
    /// because black is discounted when picking a hue.
    @Test func mostlyBlackSleeveGivesANearBlackPage() {
        let globeOrange = RGBColor(red: 0.85, green: 0.52, blue: 0.08)
        let colors = ArtworkColorAnalyzer.readableColors(
            from: globeOrange,
            artworkLuminance: 0.09,
            darkFraction: 0.72
        )
        #expect(!colors.prefersDarkText)
        #expect(
            ArtworkColorAnalyzer.relativeLuminance(colors.background) < 0.03,
            "should be near black, not an orange page"
        )
        // A trace of the artwork's warmth is welcome; a full orange is not.
        #expect(colors.background.red > colors.background.blue)
        #expect(colors.textContrast >= ArtworkColorAnalyzer.minimumContrast)
    }

    /// The same orange on a sleeve that is *not* mostly black must still give
    /// a proper orange page — the black rule must not swallow everything.
    @Test func orangeSleeveWithoutBlackIsUnaffected() {
        let globeOrange = RGBColor(red: 0.85, green: 0.52, blue: 0.08)
        let colors = ArtworkColorAnalyzer.readableColors(
            from: globeOrange,
            artworkLuminance: 0.30,
            darkFraction: 0.05
        )
        let result = ArtworkColorAnalyzer.hsb(colors.background)
        #expect(result.brightness > 0.30, "still a real orange page")
    }

    @Test func monochromePhotoGivesANeutralPage() {
        let colors = ArtworkColorAnalyzer.readableColors(from: monochrome)
        let result = ArtworkColorAnalyzer.hsb(colors.background)
        // Nothing to be colourful about; it must not invent a tint.
        #expect(result.saturation < 0.35)
        #expect(colors.textContrast >= ArtworkColorAnalyzer.minimumContrast)
    }
}

@Suite struct EdgeColorTests {
    /// Builds row-ordered pixels for a `side`×`side` image whose top half is
    /// one colour and bottom half another.
    private func splitImage(top: RGBColor, bottom: RGBColor, side: Int) -> [RGBColor] {
        (0..<(side * side)).map { index in
            index < (side * side) / 2 ? top : bottom
        }
    }

    @Test func readsTheColourAlongTheBottom() {
        let sky = RGBColor(red: 0.2, green: 0.4, blue: 0.9)
        let sand = RGBColor(red: 0.9, green: 0.8, blue: 0.4)
        let pixels = splitImage(top: sky, bottom: sand, side: 48)
        let edge = try! #require(ArtworkColorAnalyzer.bottomEdgeColor(in: pixels, side: 48))
        // The bottom band only, not an average of the whole image.
        #expect(abs(edge.red - sand.red) < 0.02)
        #expect(abs(edge.blue - sand.blue) < 0.02)
    }

    @Test func monochromeArtworkEdgeMatchesItExactly() {
        // The case that showed a seam: the fade must land on precisely this
        // colour before moving to the adjusted page colour.
        let flat = RGBColor(red: 0.36, green: 0.52, blue: 0.44)
        let pixels = Array(repeating: flat, count: 48 * 48)
        let edge = try! #require(ArtworkColorAnalyzer.bottomEdgeColor(in: pixels, side: 48))
        #expect(abs(edge.red - flat.red) < 0.001)
        #expect(abs(edge.green - flat.green) < 0.001)
        #expect(abs(edge.blue - flat.blue) < 0.001)
    }

    @Test func handlesTooFewPixels() {
        #expect(ArtworkColorAnalyzer.bottomEdgeColor(in: [], side: 48) == nil)
        #expect(ArtworkColorAnalyzer.bottomEdgeColor(in: [RGBColor(red: 1, green: 1, blue: 1)], side: 0) == nil)
    }

    /// "NOW 64": a collage of clashing colours. Averaging its bottom edge
    /// gives a muddy tone matching neither the artwork nor the page, so the
    /// transition passed through a colour that belongs to nothing.
    @Test func busyEdgeReportsNoSingleColour() {
        let side = 48
        let palette = [
            RGBColor(red: 0.90, green: 0.10, blue: 0.10),
            RGBColor(red: 0.10, green: 0.45, blue: 0.95),
            RGBColor(red: 0.95, green: 0.85, blue: 0.10),
            RGBColor(red: 0.15, green: 0.75, blue: 0.35),
            RGBColor(red: 0.95, green: 0.95, blue: 0.95),
        ]
        let pixels = (0..<(side * side)).map { palette[$0 % palette.count] }
        #expect(
            ArtworkColorAnalyzer.bottomEdgeColor(in: pixels, side: side) == nil,
            "a collage edge has no colour to blend through"
        )
    }

    @Test func gentlyVariedEdgeStillHasAColour() {
        let side = 48
        // Sea texture: many shades, one colour.
        let pixels = (0..<(side * side)).map { index -> RGBColor in
            let wobble = Double(index % 7) / 100
            return RGBColor(red: 0.14 + wobble, green: 0.52 + wobble, blue: 0.48 + wobble)
        }
        let edge = ArtworkColorAnalyzer.bottomEdgeColor(in: pixels, side: side)
        #expect(edge != nil, "ordinary texture should not be mistaken for a collage")
    }

    /// Ryan Adams "1989": a printed white border around the picture. Sampling
    /// it drags the edge colour toward white and the transition no longer
    /// matches the artwork.
    @Test func printedBorderIsExcludedFromTheEdgeColour() {
        let side = 48
        let border = RGBColor(red: 1, green: 1, blue: 1)
        let teal = RGBColor(red: 0.16, green: 0.55, blue: 0.50)
        let borderWidth = 2

        var pixels: [RGBColor] = []
        for row in 0..<side {
            for column in 0..<side {
                let isBorder = row < borderWidth || row >= side - borderWidth
                    || column < borderWidth || column >= side - borderWidth
                pixels.append(isBorder ? border : teal)
            }
        }

        let edge = try! #require(ArtworkColorAnalyzer.bottomEdgeColor(in: pixels, side: side))
        // Should read the picture, not the frame around it.
        #expect(abs(edge.red - teal.red) < 0.05, "border leaked in: \(edge)")
        #expect(abs(edge.green - teal.green) < 0.05)
        #expect(abs(edge.blue - teal.blue) < 0.05)
    }
}

@Suite struct DominantColorTests {
    private func pixels(_ color: RGBColor, _ count: Int) -> [RGBColor] {
        Array(repeating: color, count: count)
    }

    @Test func picksTheColourThatCoversTheArtwork() {
        let red = RGBColor(red: 0.8, green: 0.1, blue: 0.1)
        let blue = RGBColor(red: 0.1, green: 0.1, blue: 0.7)
        let dominant = try! #require(
            ArtworkColorAnalyzer.dominantColor(in: pixels(red, 300) + pixels(blue, 60))
        )
        #expect(dominant.red > dominant.blue, "the red majority should win")
    }

    @Test func ignoresBlackBordersAndWhiteBackgrounds() {
        // A common sleeve: a wide black border around a small coloured image.
        let black = RGBColor(red: 0.01, green: 0.01, blue: 0.01)
        let white = RGBColor(red: 0.99, green: 0.99, blue: 0.99)
        let teal = RGBColor(red: 0.1, green: 0.6, blue: 0.55)
        let dominant = try! #require(
            ArtworkColorAnalyzer.dominantColor(
                in: pixels(black, 500) + pixels(white, 400) + pixels(teal, 90)
            )
        )
        #expect(dominant.green > 0.3 && dominant.blue > 0.3, "should find the teal, not the border")
    }

    @Test func prefersColourfulOverDrab() {
        // Grey covers slightly more area, but the vivid orange is what the
        // sleeve reads as.
        let grey = RGBColor(red: 0.45, green: 0.45, blue: 0.46)
        let orange = RGBColor(red: 0.95, green: 0.45, blue: 0.05)
        let dominant = try! #require(
            ArtworkColorAnalyzer.dominantColor(in: pixels(grey, 200) + pixels(orange, 170))
        )
        #expect(dominant.red - dominant.blue > 0.3, "the saturated colour should win")
    }

    @Test func greyscaleArtworkHasNoDominantColour() {
        let mono = (0..<50).map { step in
            let value = Double(step) / 50
            return RGBColor(red: value, green: value, blue: value)
        }
        // Nothing colourful to find, so the caller falls back to neutral
        // rather than inventing a hue.
        let dominant = ArtworkColorAnalyzer.dominantColor(in: mono)
        if let dominant {
            let saturation = ArtworkColorAnalyzer.hsb(dominant).saturation
            #expect(saturation < 0.1)
        }
    }
}

@Suite struct UltraBlurTests {
    private let side = 48

    /// Paints `fill` everywhere, then a centred disc of `disc`.
    private func sleeve(fill: RGBColor, disc: RGBColor?, discRadius: Double = 0.28) -> [RGBColor] {
        var pixels = [RGBColor](repeating: fill, count: side * side)
        guard let disc else { return pixels }
        let centre = Double(side - 1) / 2
        let radius = Double(side) * discRadius
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) - centre
                let dy = Double(y) - centre
                if (dx * dx + dy * dy).squareRoot() <= radius {
                    pixels[y * side + x] = disc
                }
            }
        }
        return pixels
    }

    private func hue(_ color: RGBColor) -> Double {
        ArtworkColorAnalyzer.hsb(color).hue
    }

    private func brightness(_ color: RGBColor) -> Double {
        ArtworkColorAnalyzer.hsb(color).brightness
    }

    /// Warm hues sit at either end of the 0...1 wheel.
    private func isWarm(_ color: RGBColor) -> Bool {
        let h = hue(color)
        return h <= 0.11 || h >= 0.95
    }

    @Test func gridHasOneColourPerCell() {
        let pixels = sleeve(fill: RGBColor(red: 0.3, green: 0.4, blue: 0.6), disc: nil)
        let palette = ArtworkColorAnalyzer.ultraBlurPalette(in: pixels, side: side)
        #expect(palette?.colors.count == 9)
        #expect(palette?.columns == 3)
        #expect(palette?.rows == 3)
    }

    @Test func rejectsAPixelCountThatIsNotTheStatedSide() {
        #expect(ArtworkColorAnalyzer.ultraBlurPalette(in: [], side: side) == nil)
    }

    /// Parachutes: a black frame around a glowing orange globe. Blurring the
    /// bitmap gives black; the cover reads as orange.
    @Test func blackSleeveWithABrightObjectTintsTowardsThatObject() throws {
        let pixels = sleeve(
            fill: RGBColor(red: 0.02, green: 0.02, blue: 0.03),
            disc: RGBColor(red: 0.92, green: 0.52, blue: 0.10)
        )
        let colors = try #require(ArtworkColorAnalyzer.ultraBlurPalette(in: pixels, side: side)).colors

        for color in colors {
            #expect(isWarm(color), "expected a warm cell, got hue \(hue(color))")
            // Nothing should come out as a black rectangle.
            #expect(brightness(color) >= ArtworkColorAnalyzer.ultraBlurFloor - 0.001)
        }
        // The middle of the cover is still the brightest part of the page.
        #expect(brightness(colors[4]) > brightness(colors[0]))
    }

    /// Live in Buenos Aires: a saturated purple sleeve keeps its own colour
    /// rather than being pulled anywhere.
    @Test func aSaturatedSleeveKeepsItsOwnHue() throws {
        let purple = RGBColor(red: 0.36, green: 0.16, blue: 0.55)
        let pixels = sleeve(fill: purple, disc: RGBColor(red: 0.52, green: 0.28, blue: 0.70))
        let colors = try #require(ArtworkColorAnalyzer.ultraBlurPalette(in: pixels, side: side)).colors

        let expected = hue(purple)
        for color in colors {
            #expect(abs(hue(color) - expected) < 0.06, "hue drifted to \(hue(color))")
        }
    }

    /// A greyscale cover has no hue to borrow, so it stays grey rather than
    /// being tinted at random.
    @Test func greyscaleArtworkIsNotGivenAColour() throws {
        let pixels = sleeve(fill: RGBColor(red: 0.4, green: 0.4, blue: 0.4), disc: nil)
        let colors = try #require(ArtworkColorAnalyzer.ultraBlurPalette(in: pixels, side: side)).colors
        for color in colors {
            #expect(ArtworkColorAnalyzer.hsb(color).saturation < 0.05)
        }
    }

    @Test func brightnessNeverReachesEitherExtreme() throws {
        for fill in [RGBColor(red: 0, green: 0, blue: 0), RGBColor(red: 1, green: 1, blue: 1)] {
            let colors = try #require(
                ArtworkColorAnalyzer.ultraBlurPalette(in: sleeve(fill: fill, disc: nil), side: side)
            ).colors
            for color in colors {
                #expect(brightness(color) >= ArtworkColorAnalyzer.ultraBlurFloor - 0.001)
                #expect(brightness(color) <= ArtworkColorAnalyzer.ultraBlurCeiling + 0.001)
            }
        }
    }
}

@Suite struct VividMarkerTests {
    /// The whole point: whatever the background, the marker must actually be
    /// visible against it, swept the same way `everyColourProducesReadableText`
    /// sweeps the hue circle for page text.
    @Test func alwaysClearsTheMarkerContrastThreshold() {
        for hueStep in 0..<24 {
            for saturationStep in 0...4 {
                for brightnessStep in 0...4 {
                    let background = ArtworkColorAnalyzer.rgb(
                        hue: Double(hueStep) / 24,
                        saturation: Double(saturationStep) / 4,
                        brightness: 0.15 + Double(brightnessStep) / 5
                    )
                    let marker = ArtworkColorAnalyzer.vividMarker(against: background)
                    let contrast = ArtworkColorAnalyzer.contrastRatio(marker, background)
                    #expect(
                        contrast >= ArtworkColorAnalyzer.minimumMarkerContrast - 0.01,
                        """
                        hue \(hueStep)/24 sat \(saturationStep)/4 bri \(brightnessStep)/5 \
                        produced contrast \(contrast)
                        """
                    )
                }
            }
        }
    }

    /// A page with no hue of its own has nothing for a warm marker to clash
    /// with, so it keeps the warm one.
    @Test func aColourlessPageKeepsTheWarmMarker() {
        for grey in [RGBColor(red: 0.10, green: 0.10, blue: 0.11),
                     RGBColor(red: 0.93, green: 0.93, blue: 0.93)] {
            let marker = ArtworkColorAnalyzer.vividMarker(against: grey)
            let distance = ArtworkColorAnalyzer.hueDistance(
                ArtworkColorAnalyzer.hsb(marker).hue,
                ArtworkColorAnalyzer.warmMarkerHue
            )
            #expect(distance < 0.02, "hue drifted to \(ArtworkColorAnalyzer.hsb(marker).hue)")
        }
    }

    /// A page in the warm marker's own hue is the one case it cannot
    /// survive, brightness notwithstanding — that one goes cool instead.
    @Test func aWarmPageTakesTheCoolMarker() {
        let warmPage = RGBColor(red: 0.34, green: 0.13, blue: 0.06)
        let marker = ArtworkColorAnalyzer.vividMarker(against: warmPage)
        let distance = ArtworkColorAnalyzer.hueDistance(
            ArtworkColorAnalyzer.hsb(marker).hue,
            ArtworkColorAnalyzer.coolMarkerHue
        )
        #expect(distance < 0.02, "hue drifted to \(ArtworkColorAnalyzer.hsb(marker).hue)")
    }

    /// The marker keeps real colour rather than being washed to the page's
    /// own text colour — the point of the exercise.
    @Test func theMarkerStaysAColour() {
        for hueStep in 0..<12 {
            let page = ArtworkColorAnalyzer.readableColors(
                from: ArtworkColorAnalyzer.rgb(
                    hue: Double(hueStep) / 12,
                    saturation: 0.7,
                    brightness: 0.6
                )
            ).background
            let marker = ArtworkColorAnalyzer.vividMarker(against: page)
            #expect(
                ArtworkColorAnalyzer.hsb(marker).saturation > 0.25,
                "page hue \(hueStep)/12 left a marker at saturation \(ArtworkColorAnalyzer.hsb(marker).saturation)"
            )
        }
    }
}
