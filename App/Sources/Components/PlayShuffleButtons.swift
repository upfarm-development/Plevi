import SwiftUI

/// Paired Play and Shuffle controls, used on every screen that can start a collection: albums,
/// artists, and playlists.
struct PlayShuffleButtons: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    /// The other kind of shuffle, revealed by holding the button.
    var alternativeShuffle: AlternativeShuffle?
    /// On the immersive style the page is already coloured, so the buttons
    /// borrow the palette rather than the system tint, which can vanish
    /// against a similar background.
    var palette: ArtworkPalette?
    /// Sized to sit on the same line as an album's details rather than on a
    /// row of their own — which buys back a row of the tracklist.
    var size: ControlMetrics.Size = .large

    var body: some View {
        HStack(spacing: size == .compact ? 8 : 12) {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(ControlMetrics.font(size))
                    .frame(width: ControlMetrics.side(size), height: ControlMetrics.side(size))
                    .foregroundStyle(playForeground)
            }
            .buttonStyle(.borderedProminent)
            .tint(playTint)
            .accessibilityLabel("Play")

            Button(action: onShuffle) {
                Image(systemName: "shuffle")
                    .font(ControlMetrics.font(size))
                    .frame(width: ControlMetrics.side(size), height: ControlMetrics.side(size))
                    .foregroundStyle(palette?.foreground ?? Color.accentColor)
            }
            .buttonStyle(.bordered)
            .tint(palette.map { $0.foreground.opacity(0.22) } ?? Color.accentColor.opacity(0.15))
            .accessibilityLabel("Shuffle")
            .contextMenu {
                // Reset here for the same reason the album and playlist "…" menus reset it on their
                // own content: the tint above is a washed-out fill for the button's own circle, and
                // left to spread it colours this menu's icon too — near-invisible at a fifth…
                Group {
                    if let alternative = alternativeShuffle {
                        Button(alternative.title, systemImage: alternative.icon, action: alternative.action)
                    }
                }
                .tint(Color.primary)
            }
        }
        .controlSize(ControlMetrics.controlSize(size))
        .buttonBorderShape(.circle)
    }

    private var playTint: Color {
        palette?.foreground ?? Color.accentColor
    }

    private var playForeground: Color {
        palette?.background ?? .white
    }
}

/// The shuffle a long press offers: whichever one a tap is not doing.
struct AlternativeShuffle {
    var title: String
    var icon: String
    var action: () -> Void

    /// Built from the setting, so the wording always names the one you are
    /// not already getting.
    static func offering(smart: Bool, action: @escaping () -> Void) -> AlternativeShuffle {
        smart
            ? AlternativeShuffle(title: "Smart Shuffle", icon: "wand.and.stars", action: action)
            : AlternativeShuffle(title: "Classic Shuffle", icon: "shuffle", action: action)
    }
}

/// Keeps the circular header controls the same size as each other, whichever
/// size they are being drawn at.
enum ControlMetrics {
    enum Size {
        /// Beside a line of details, as small as it can usefully be.
        case compact
        /// Beside an album's artist and year: as tall as those two lines
        /// together, so the controls start and finish where the text does.
        case header
        /// A row of its own.
        case large
    }

    static func side(_ size: Size) -> CGFloat {
        switch size {
        case .compact: 18
        case .header: 22
        case .large: 26
        }
    }

    static func font(_ size: Size) -> Font {
        switch size {
        case .compact: .body
        case .header: .title3
        case .large: .title2
        }
    }

    static func controlSize(_ size: Size) -> ControlSize {
        size == .large ? .large : .regular
    }
}
