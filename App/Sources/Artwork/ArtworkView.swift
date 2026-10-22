import SwiftUI
import PleviDomain

/// What to draw where a picture is missing.
enum ArtworkPlaceholder {
    case music
    case artist

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .artist: "person.fill"
        }
    }

    /// Proportion of the frame the glyph takes.
    var symbolScale: CGFloat {
        switch self {
        case .music: 0.35
        case .artist: 0.45
        }
    }

    @ViewBuilder
    func fill() -> some View {
        switch self {
        case .music: Color.clear.background(.quaternary)
        // A fixed grey rather than a system one: this sits on pages that are tinted by artwork
        // rather than by the system's light or dark background, and a colour that follows the
        // appearance can land on a page the same shade as itself.
        case .artist: Color(white: 0.45)
        }
    }

    @ViewBuilder
    func glyph() -> some View {
        switch self {
        case .music: Image(systemName: symbol).foregroundStyle(.tertiary)
        case .artist: Image(systemName: symbol).foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct CardIsRisingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the full player card is on its way up. See `RisesFromBelow`.
    var cardIsRising: Bool {
        get { self[CardIsRisingKey.self] }
        set { self[CardIsRisingKey.self] = newValue }
    }
}

/// Square artwork thumbnail that requests exactly the pixel size it renders.
struct ArtworkView: View {
    let artwork: ArtworkID?
    let size: CGFloat
    var cornerRadius: CGFloat = 8
    /// What stands in when there is no picture — a note for music, a figure
    /// for a person.
    var placeholder: ArtworkPlaceholder = .music
    /// The size to ask the loader for, when it should not follow the size drawn.
    var requestSize: CGFloat? = nil

    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @Environment(\.cardIsRising) private var cardIsRising
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            placeholder.fill()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            if let shown = image ?? alreadyInMemory {
                Image(uiImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .transition(cardIsRising ? .identity : .opacity)
            } else if artwork == nil {
                // Only where there is genuinely no picture.
                placeholder.glyph()
                    .font(.system(size: size * placeholder.symbolScale))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: taskKey) {
            guard let artwork, let loader = app.artwork else { return }
            let bucket = ArtworkLoader.bucket(forPointSize: requested, scale: displayScale)
            let hadOne = image ?? alreadyInMemory
            let loaded = await loader.image(for: artwork, bucket: bucket)
            // A cell that scrolled away, or whose artwork changed, gets nil
            // back from a cancelled request, which says nothing about the
            // sleeve and must not be drawn over whatever is there now.
            guard !Task.isCancelled else { return }
            // No fade over a picture already on screen — that is the same sleeve arriving twice,
            // and it reads as a flicker.
            if hadOne == nil, !cardIsRising {
                withAnimation(.easeIn(duration: 0.15)) { image = loaded }
            } else {
                image = loaded
            }
            // Every sleeve drawn anywhere teaches the app what colour its
            // page should be, so opening it is instant.
            if let loaded {
                PaletteLoader.warm(artwork, from: loaded, bucket: bucket)
            }
        }
    }

    /// The sleeve if it is already in memory, which costs nothing to ask and
    /// is what keeps a rebuilt view from blinking — see
    /// `ArtworkLoader.cachedImage(for:bucket:)`.
    private var alreadyInMemory: UIImage? {
        guard let artwork, let loader = app.artwork else { return nil }
        return loader.cachedImage(
            for: artwork,
            bucket: ArtworkLoader.bucket(forPointSize: requested, scale: displayScale)
        )
    }

    /// What is asked of the loader — see `requestSize`.
    private var requested: CGFloat { requestSize ?? size }

    /// The loader, the active server, and whether that server has actually been reached, are all
    /// part of the key rather than just the artwork: a view that appears before the app has
    /// connected has nothing to load from, and without this it would…
    private var taskKey: String {
        let subject = artwork.map { "\($0.rawValue)|\(Int(requested))" } ?? "none"
        let server = app.servers.activeServerID?.rawValue.uuidString ?? "no-server"
        return "\(subject)|\(server)|\(app.artworkStage)"
    }
}
