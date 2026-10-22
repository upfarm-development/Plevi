import SwiftUI
import UIKit
import PleviPalette

/// What the two artwork-led playing screens add to the page they sit on.
struct PlayerPalette: Equatable {
    /// The one bright colour on the screen.
    var accent: Color
    /// The play button's disc, and the glyph cut out of it.
    var buttonFill: Color
    var buttonGlyph: Color
    /// Guaranteed to be readable on the page, whatever the page turned out
    /// to be — this is the album pages' own answer to that question.
    var text: Color
    /// What the bleeding artwork lands on when the page is a flat colour.
    var ground: Color
    /// Whether the page is dark, which is what decides the two colours above
    /// and how heavily the text can be thinned.
    var isDark: Bool

    /// Title.
    var primaryText: Color { text }
    /// Artist, and anything else a step behind the title.
    var secondaryText: Color { text.opacity(0.72) }
    /// Album, year, times, the technical chip — read when looked for.
    var tertiaryText: Color { text.opacity(isDark ? 0.56 : 0.66) }

    /// The unplayed part of the seek bar.
    var quietFill: Color { text.opacity(isDark ? 0.44 : 0.58) }

    /// - Parameters:
    ///   - page: the palette the page is already drawn in, contrast and all.
    ///   - artwork: the record's own analysed colour, for its hue.
    init(page: ArtworkPalette, artwork: ArtworkPalette) {
        let isDark = page.chromeScheme != .light
        let colors = ArtworkColorAnalyzer.playerColors(
            from: Self.components(of: artwork.background),
            isDarkPage: isDark
        )
        self.isDark = isDark
        accent = Color(colors.accent)
        buttonFill = Color(colors.button)
        buttonGlyph = page.background
        text = page.foreground
        ground = page.background
    }

    /// A palette that draws the scrubber and the stars in the player's colours, for the components
    /// that take one.
    func asArtworkPalette(foreground: Color? = nil) -> ArtworkPalette {
        ArtworkPalette(
            background: ground,
            foreground: foreground ?? accent,
            secondaryForeground: quietFill,
            chromeScheme: isDark ? .dark : .light
        )
    }

    /// Pulls a colour apart into components the analysis can work on.
    private static func components(of color: Color) -> RGBColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return RGBColor(red: 0.3, green: 0.3, blue: 0.3)
        }
        return RGBColor(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

extension Color {
    init(_ rgb: RGBColor) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
