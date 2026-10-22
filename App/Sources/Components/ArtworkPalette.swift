import SwiftUI
import CoreGraphics
import UIKit
import PleviDomain
import PleviPalette

/// A colour scheme derived from a piece of artwork, used by the immersive
/// page style so a page takes on the character of the record it shows.
struct ArtworkPalette: Equatable {
    /// The colour the artwork fades down into.
    var background: Color
    /// Text colour guaranteed to be readable on `background`.
    var foreground: Color
    /// Softer variant for secondary text.
    var secondaryForeground: Color
    /// A vivid colour for marking something out — a standout track, say —
    /// guaranteed to read against `background` rather than merely likely to.
    /// See `ArtworkColorAnalyzer.vividMarker(against:)`.
    var hotAccent: Color = .orange
    /// The artwork's own colour at its bottom edge. The fade passes through
    /// this on its way to `background`, so a near-monochrome cover does not
    /// meet a different colour at a hard line.
    var edge: Color?

    /// Which appearance the system chrome over this page — status bar, back
    /// button, tab bar glass — should use. `nil` leaves it to the system,
    /// which is right only when the page keeps the system background.
    var chromeScheme: ColorScheme?

    /// Row-major 3×3 grid for the ultrablurred background. Empty when there
    /// is no artwork to draw one from.
    var mesh: [Color] = []

    /// For the blurred style: the scrim guarantees a dark backdrop, so text
    /// is always white regardless of what the artwork sampled to.
    static let overBlur = ArtworkPalette(
        background: .black,
        foreground: .white,
        secondaryForeground: Color.white.opacity(0.78),
        chromeScheme: .dark
    )

    /// Neutral fallback while artwork loads, or when there is none.
    static let neutral = ArtworkPalette(
        background: Color(.systemBackground),
        foreground: Color(.label),
        secondaryForeground: Color(.secondaryLabel)
    )

    /// The same, for a page that will be artwork-led once its colours arrive.
    static let neutralOverArtwork = ArtworkPalette(
        background: Color(red: 0.09, green: 0.09, blue: 0.10),
        foreground: .white,
        secondaryForeground: Color.white.opacity(0.75),
        chromeScheme: .dark
    )

}

extension ArtworkPalette {
    /// The colours a page in `style` should use, given the artwork's own.
    static func forPage(_ style: PageStyle, artwork: @autoclosure () -> ArtworkPalette) -> ArtworkPalette {
        if style.usesBlurredBackground { return .overBlur }
        let colours = artwork()
        // Still neutral means the artwork has not been analysed yet.
        return colours.chromeScheme == nil ? .neutralOverArtwork : colours
    }
}

/// A page's backdrop for the current style.
struct PageBackground: View {
    let style: PageStyle
    /// The artwork's *own* colours — not the page palette.
    let artwork: ArtworkPalette

    var body: some View {
        Group {
            if style.usesBlurredBackground {
                BlurredArtworkBackground(mesh: artwork.mesh, fallback: artwork.background)
            } else {
                // Same fallback `forPage` gives the text: a palette that is still neutral (artwork
                // not analysed, or unreachable offline) gets white text, so it needs the dark
                // backdrop that goes with it rather than `systemBackground`.
                (artwork.chromeScheme == nil ? ArtworkPalette.neutralOverArtwork : artwork).background
            }
        }
        .ignoresSafeArea()
    }
}

extension ArtworkPalette {
    /// Wraps the analysed colours, whose contrast against their text colour
    /// is guaranteed by `PleviPalette`. Declared in an extension so the
    /// memberwise initialiser survives.
    init(_ colors: ArtworkColors, edge: RGBColor? = nil, mesh: [RGBColor] = []) {
        let text: Color = colors.prefersDarkText ? .black : .white
        let hot = ArtworkColorAnalyzer.vividMarker(against: colors.background)
        self.init(
            background: Color(
                red: colors.background.red,
                green: colors.background.green,
                blue: colors.background.blue
            ),
            foreground: text,
            secondaryForeground: text.opacity(0.75),
            hotAccent: Color(red: hot.red, green: hot.green, blue: hot.blue),
            edge: edge.map { Color(red: $0.red, green: $0.green, blue: $0.blue) },
            // Dark text means a light page, and vice versa.
            chromeScheme: colors.prefersDarkText ? .light : .dark,
            mesh: mesh.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        )
    }
}

/// What the analysis of a picture came to, in plain components so it can be
/// written beside a kept sleeve and read back on a launch with no connection.
struct StoredPalette: Codable, Equatable, Sendable {
    var colors: ArtworkColors
    var edge: RGBColor?
    var mesh: [RGBColor]
}

extension ArtworkPalette {
    init(_ stored: StoredPalette) {
        self.init(stored.colors, edge: stored.edge, mesh: stored.mesh)
    }
}

/// Bridges `UIImage` to the colour analysis in `PleviPalette`, which holds
/// the maths and is unit-tested there.
enum ArtworkPaletteExtractor {
    private static let sampleSide = 48

    static func palette(from image: UIImage) -> ArtworkPalette {
        ArtworkPalette(analysis(of: image))
    }

    /// The colours worked out of a picture, before they become SwiftUI
    /// values — the part worth writing to disk.
    static func analysis(of image: UIImage) -> StoredPalette {
        guard let pixels = downsampledPixels(image, side: sampleSide), !pixels.isEmpty else {
            return StoredPalette(colors: ArtworkColorAnalyzer.neutral, edge: nil, mesh: [])
        }
        let edge = ArtworkColorAnalyzer.bottomEdgeColor(in: pixels, side: sampleSide)
        let mesh = ArtworkColorAnalyzer.ultraBlurPalette(in: pixels, side: sampleSide)?.colors ?? []
        guard let dominant = ArtworkColorAnalyzer.dominantColor(in: pixels) else {
            return StoredPalette(colors: ArtworkColorAnalyzer.neutral, edge: edge, mesh: mesh)
        }
        // Hue comes from the colourful parts; how light or dark the page
        // should be comes from the cover as a whole, black included.
        let colors = ArtworkColorAnalyzer.readableColors(
            from: dominant,
            artworkLuminance: ArtworkColorAnalyzer.meanLuminance(of: pixels),
            darkFraction: ArtworkColorAnalyzer.darkFraction(of: pixels)
        )
        return StoredPalette(colors: colors, edge: edge, mesh: mesh)
    }

    /// Draws the artwork into a small bitmap so every pixel can be inspected.
    /// 48×48 is plenty for judging dominant colour and keeps the analysis
    /// well under a frame.
    private static func downsampledPixels(_ image: UIImage, side: Int) -> [RGBColor]? {
        guard let cgImage = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &data,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var pixels: [RGBColor] = []
        pixels.reserveCapacity(side * side)
        for index in stride(from: 0, to: data.count, by: 4) {
            guard data[index + 3] > 0 else { continue }
            pixels.append(RGBColor(
                red: Double(data[index]) / 255,
                green: Double(data[index + 1]) / 255,
                blue: Double(data[index + 2]) / 255
            ))
        }
        return pixels
    }
}

/// How a page's artwork gives way to the page beneath it.
struct HeaderFade {
    /// How dark the top edge is made, under the back button.
    var topScrim: Double
    /// Where the page colour starts coming up, as a fraction of the height.
    var start: Double
    /// How much of it there is at `start`.
    var startOpacity: Double
    /// And at 86%, after which it closes to solid.
    var lateOpacity: Double

    /// Late and light.
    static let artist = HeaderFade(topScrim: 0.42, start: 0.66, startOpacity: 0.08, lateOpacity: 0.72)
    static let album = HeaderFade(topScrim: 0.40, start: 0.56, startOpacity: 0.30, lateOpacity: 0.90)
    /// No scrim on top at all.
    static let playlist = HeaderFade(topScrim: 0, start: 0.72, startOpacity: 0.10, lateOpacity: 0.45)

    /// The page's own left and right margin, so the name lines up with
    /// everything under it.
    static let titleInset: CGFloat = 22
    static let titleBottomInset: CGFloat = 14

    /// - Parameter edge: the artwork's own sampled colour at its bottom edge, when known.
    func gradient(into page: Color, edge: Color? = nil) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(topScrim), location: 0),
                .init(color: .black.opacity(0), location: 0.22),
                .init(color: page.opacity(startOpacity), location: start),
                .init(color: page.opacity(lateOpacity), location: 0.86),
                .init(color: (edge ?? page).opacity(0.9), location: 0.95),
                .init(color: page, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Where the artwork begins fading into the page colour, as a fraction of
/// its height. The fade is long but very gradual, so the transition is soft
/// without washing out the cover.
let immersiveArtworkFadeStart = 0.58

/// Large artwork that fades into the palette colour, with the page's title
/// block sitting on top of the fade.
struct ImmersiveHeader<Content: View, Title: View>: View {
    let artwork: ArtworkID?
    let palette: ArtworkPalette
    var artworkShape: ArtworkShape = .square
    /// How the picture gives way to the page. See `HeaderFade`.
    var fade: HeaderFade = .album
    /// How much room is left under the title before whatever comes next.
    var titleBottom: CGFloat = HeaderFade.titleBottomInset

    /// How far below the picture the words start.
    var titleDrop: CGFloat = 0
    /// With a blurred page behind, the artwork dissolves into that instead of
    /// into a solid colour — there is no single colour to land on.
    var dissolvesIntoBackground = false
    /// What to show when there turns out to be no picture at all.
    var placeholder: ArtworkPlaceholder?
    /// How far the page has been pulled down past its own resting top, in points — zero the rest of
    /// the time.
    var pulledPast: CGFloat = 0
    /// The name and the line under it, drawn inside the foot of the picture.
    @ViewBuilder var title: Title
    @ViewBuilder var content: Content

    enum ArtworkShape {
        case square
        case circle
    }

    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    /// Whether the answer is in. Until it is, an empty header is a header
    /// still loading, not one with nothing to show.
    @State private var resolved = false

    var body: some View {
        Group {
            if dissolvesIntoBackground {
                dissolvingHeader
            } else {
                solidHeader
            }
        }
        // Attached to both layouts: when this lived on `solidHeader` alone the blurred style never
        // loaded its artwork and showed bare blur.
        .task(id: "\(artwork?.rawValue ?? "none")|\(app.artworkStage)") {
            guard let loader = app.artwork else { return }
            guard let artwork else {
                resolved = true
                return
            }
            let loaded = await loader.image(for: artwork, bucket: 1200)
            guard !Task.isCancelled else { return }
            image = loaded
            // Resolved means the question has been answered, and nothing found while the loader
            // could only read from disk is not an answer — it is the server not being there yet.
            resolved = loaded != nil || app.artworkCanFetch
        }
    }

    /// Both layouts are a picture, then the title and content stood beneath
    /// it the same way — only how the picture meets the page differs. `title`
    /// sits in the fade rather than below it: see its own doc comment.
    private func headerSkeleton(@ViewBuilder picture: () -> some View) -> some View {
        VStack(spacing: 0) {
            picture()
            title
                .padding(.horizontal, HeaderFade.titleInset)
                .padding(.top, titleDrop)
                .padding(.bottom, titleBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
    }

    private var dissolvingHeader: some View {
        headerSkeleton {
            GeometryReader { proxy in
                let side = proxy.size.width
                artworkContent(side: side, frameHeight: side + pulledPast)
                    .frame(width: side, height: side + pulledPast, alignment: .top)
                    .clipped()
                    // The room for the words, taken below the picture and
                    // filled with the colour the fade is on its way to.
                    .frame(height: side + pulledPast + titleDrop, alignment: .top)
                    .background(palette.background)
                    // Fades to nothing so the blurred page shows through, rather than meeting an
                    // opaque colour.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: immersiveArtworkFadeStart),
                                .init(color: .white.opacity(0.55), location: 0.86),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    // Pins the top of the picture to where it rests, rather
                    // than letting it be carried down with the rest of the
                    // page — see `pulledPast`.
                    .offset(y: -pulledPast)
            }
            .aspectRatio(1, contentMode: .fit)
            // No scrim behind the words here, and that is deliberate: over a blurred page a scrim
            // has nothing to dissolve into itself, so it ends where it ends and that edge is a line
            // across the screen.
        }
    }

    private var solidHeader: some View {
        headerSkeleton {
            GeometryReader { proxy in
                let side = proxy.size.width
                // Cropped to the box *first*, and only then given its fade.
                artworkContent(side: side, frameHeight: side + pulledPast)
                    .frame(width: side, height: side + pulledPast, alignment: .top)
                    .clipped()
                    .offset(y: -pulledPast)
            }
            .aspectRatio(1, contentMode: .fit)
            // Dark at the very top so the back button reads over a pale cover, clear through the
            // middle so the cover is a cover, and closing to the page colour by the foot — which is
            // the page the words below are standing on, so there is no join to see.
            .overlay {
                fade.gradient(into: palette.background, edge: palette.edge)
                    .allowsHitTesting(false)
            }
            // A real row rather than something floated over the picture, so
            // everything under it moves with it. See `titleDrop`.
        }
        .background(palette.background)
    }

    /// The picture itself, or what stands in for it, sized to fill a box `side` wide and
    /// `frameHeight` tall — `frameHeight` only ever taller than `side` when the page has been
    /// pulled past its top.
    @ViewBuilder
    private func artworkContent(side: CGFloat, frameHeight: CGFloat) -> some View {
        if let image {
            let naturalAspect = max(image.size.width, 1) / max(image.size.height, 1)
            let naturalHeight = side / naturalAspect
            let drawnHeight = max(naturalHeight, frameHeight)
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: drawnHeight)
        } else if let placeholder, resolved {
            ZStack {
                placeholder.fill()
                placeholder.glyph()
                    .font(.system(size: side * placeholder.symbolScale))
            }
        } else if dissolvesIntoBackground {
            // Let the blurred page show through while the full-size
            // artwork loads, rather than covering it with a slab.
            Color.clear
        } else {
            palette.background
        }
    }

    /// The palette for a piece of artwork, or the neutral scheme.
    static func palette(for image: UIImage?) -> ArtworkPalette {
        image.map(ArtworkPaletteExtractor.palette(from:)) ?? .neutral
    }
}

extension ImmersiveHeader where Title == EmptyView {
    /// A header with nothing written into the picture.
    init(
        artwork: ArtworkID?,
        palette: ArtworkPalette,
        artworkShape: ArtworkShape = .square,
        fade: HeaderFade = .album,
        dissolvesIntoBackground: Bool = false,
        placeholder: ArtworkPlaceholder? = nil,
        pulledPast: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            artwork: artwork,
            palette: palette,
            artworkShape: artworkShape,
            fade: fade,
            dissolvesIntoBackground: dissolvesIntoBackground,
            placeholder: placeholder,
            pulledPast: pulledPast,
            title: { EmptyView() },
            content: content
        )
    }
}

extension View {
    /// Feeds `pull` with how far this scroll view has been pulled past its own resting top, for an
    /// `ImmersiveHeader`'s `pulledPast` — apply to whatever the header is the first thing inside (a
    /// `ScrollView`, a `List`).
    func trackingHeaderPull(_ pull: Binding<CGFloat>, active: Bool = true) -> some View {
        modifier(HeaderPullTracker(pull: pull, active: active))
    }
}

private struct HeaderPullTracker: ViewModifier {
    @Binding var pull: CGFloat
    var active = true

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            // How far the page has travelled from its own top — which a raw `contentOffset.y` is
            // not.
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, scrolled in
            guard active else {
                if pull != 0 { pull = 0 }
                return
            }
            // Only downwards past the top is a pull; everything else is ordinary scrolling and
            // leaves the cover alone.
            let next = max(0, -scrolled)
            if pull != next { pull = next }
        }
    }
}

/// Loads artwork and publishes its palette, so a page can tint itself.
@MainActor
@Observable
final class PaletteLoader {
    private(set) var palette: ArtworkPalette = .neutral

    // Keyed on the whole ID, server included — the same artwork string can
    // be reused across two servers, and without the server in the key one's
    // colours would leak onto the other's cover.
    private static var cache: [ArtworkID: ArtworkPalette] = [:]

    /// The colour for artwork already analysed, without touching disk.
    static func cached(for artwork: ArtworkID?) -> ArtworkPalette? {
        artwork.flatMap { cache[$0] }
    }

    /// Works out a picture's colours while it is on screen as a thumbnail, so the page behind it
    /// opens already tinted.
    static func warm(_ artwork: ArtworkID?, from image: UIImage, bucket: Int) {
        guard bucket >= 300, let artwork, cache[artwork] == nil else { return }
        // After the frame that drew the thumbnail, not during it — and off the
        // main actor, where the analysis of a sleeve in a scrolling grid was
        // competing with the scrolling.
        Task(priority: .utility) {
            await Task.yield()
            guard cache[artwork] == nil else { return }
            let extracted = await Task.detached(priority: .utility) {
                ArtworkPaletteExtractor.palette(from: image)
            }.value
            store(extracted, for: artwork)
        }
    }

    /// Bounded, so a long session through a large library does not keep a
    /// palette for every sleeve it ever drew. Emptying it only means the next
    /// page colours itself from the artwork again.
    private static let cacheLimit = 600

    private static func store(_ palette: ArtworkPalette, for artwork: ArtworkID) {
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[artwork] = palette
    }

    init(artwork: ArtworkID? = nil) {
        if let cached = Self.cached(for: artwork) {
            palette = cached
        } else if let artwork, let kept = KeptArtwork.palette(for: artwork) {
            // Kept with a download: there on the first frame of a cold
            // launch, connection or no.
            let restored = ArtworkPalette(kept)
            Self.store(restored, for: artwork)
            palette = restored
        }
    }

    func load(artwork: ArtworkID?, using loader: ArtworkLoader?) async {
        guard let artwork, let loader else {
            palette = .neutral
            return
        }
        // Already worked out — from a previous visit, or from the thumbnail that was on screen a
        // moment ago.
        if let known = Self.cache[artwork] {
            palette = known
            return
        }
        if let kept = KeptArtwork.palette(for: artwork) {
            let restored = ArtworkPalette(kept)
            Self.store(restored, for: artwork)
            palette = restored
            return
        }
        // 640 rather than 300: the same image doubles as the blurred page
        // background, where a small one shows its pixels once enlarged.
        guard let image = await loader.image(for: artwork, bucket: 640) else {
            // Called off is not "no picture": leave the palette alone.
            if !Task.isCancelled { palette = .neutral }
            return
        }
        if let cached = Self.cache[artwork] {
            if !Task.isCancelled { palette = cached }
            return
        }
        let extracted = await Task.detached(priority: .userInitiated) {
            ArtworkPaletteExtractor.palette(from: image)
        }.value
        Self.store(extracted, for: artwork)
        guard !Task.isCancelled else { return }
        palette = extracted
    }
}
