import SwiftUI
import PleviDomain

/// Mixes worked out from what you have been playing.
struct MadeForYouShelf: View {
    let mixes: [MadeForYou.Mix]
    /// The screen's own width, measured once above the `LazyVStack` this shelf sits in rather than
    /// re-measured here — see `MeasuredWidth`.
    var knownWidth: CGFloat = 0
    let seeds: (MadeForYou.Mix) -> [MediaID]

    @Environment(AppModel.self) private var app

    private static let inset: CGFloat = 16
    /// How much of the next card shows past the trailing edge.
    private static let peek: CGFloat = 34
    private static let gap: CGFloat = 12
    private static let maxCardWidth: CGFloat = 420
    /// The card is a picture with a panel beside it, so its height is the
    /// picture's — a fraction of the width, holding at any size.
    private static let heightShare: CGFloat = 0.44

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(HomeSection.madeForYou.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            MeasuredWidth(initial: knownWidth) { width in
                let cardWidth = min(width - Self.inset - Self.peek, Self.maxCardWidth)
                if cardWidth > 0 {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: Self.gap) {
                            ForEach(mixes) { mix in
                                MixCard(
                                    mix: mix,
                                    width: cardWidth,
                                    height: (cardWidth * Self.heightShare).rounded(),
                                    play: { MediaActions(app: app).playMix(mix, seeds: seeds(mix)) },
                                    save: {
                                        MediaActions(app: app).saveMixAsPlaylist(mix, seeds: seeds(mix))
                                    }
                                )
                            }
                        }
                        // Without this, `.scrollTargetBehavior(.viewAligned)` below has no per-card
                        // layout to snap to and falls back to a default paging behaviour that lands
                        // wherever the swipe's momentum happened to run out — stuck halfway between
                        // cards.
                        .scrollTargetLayout()
                        .padding(.leading, Self.inset)
                        .padding(.trailing, Self.peek)
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
        }
    }
}

/// One mix, as a picture dissolving into a panel.
private struct MixCard: View {
    let mix: MadeForYou.Mix
    let width: CGFloat
    let height: CGFloat
    let play: () -> Void
    let save: () -> Void

    @Environment(AppModel.self) private var app

    /// The panel is a warm off-white rather than the page's own white, so the
    /// picture has something to fade *into*. Fading to pure white leaves a
    /// pale band that reads as a seam.
    private var panel: Color { Color(.secondarySystemBackground) }

    var body: some View {
        Button(action: play) {
            HStack(spacing: 0) {
                MixArtwork(mix: mix, side: height)
                    .frame(width: height, height: height)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: panel.opacity(0), location: 0.62),
                                .init(color: panel.opacity(0.95), location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }

                VStack(alignment: .leading, spacing: 3) {
                        Text(mix.isArtist ? "Artist mix" : "Mix")
                            .font(.system(size: 11, weight: .bold))
                            .textCase(.uppercase)
                            .kerning(0.9)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(mix.title)
                            .font(.system(size: 21, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)

                        // Whose music this is going to be. A genre mix knows
                        // and says so; an artist mix is named after the only
                        // answer it has, so it says what it will do instead.
                    // Two rows whatever the name did.
                    Text(mix.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // Barely any on the leading side, so the words begin inside
                // the fade rather than after it — which is what makes the two
                // halves read as one card.
                .padding(.leading, 6)
                .padding(.trailing, 16)
                .padding(.vertical, 14)
                // Centred rather than pinned to the top: with the button gone the words are all
                // there is, and a block of text sitting against the top of a card with space under
                // it reads as something missing.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(width: width, height: height)
            .background { panel }
            .clipShape(.rect(cornerRadius: 22))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // A mix is rebuilt every day, so the one on screen is only here
        // until tomorrow. This is how you keep the one you liked.
        .contextMenu {
            Button("Save as Playlist", systemImage: "text.badge.plus", action: save)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mix.title) mix")
        // The card is the button now, so it has to say what pressing it does.
        .accessibilityHint("Plays this mix")
    }
}

/// What a mix looks like.
private struct MixArtwork: View {
    let mix: MadeForYou.Mix
    let side: CGFloat

    var body: some View {
        if mix.artworks.count >= 4 {
            let half = side / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ArtworkView(artwork: mix.artworks[0], size: half, cornerRadius: 0)
                    ArtworkView(artwork: mix.artworks[1], size: half, cornerRadius: 0)
                }
                HStack(spacing: 0) {
                    ArtworkView(artwork: mix.artworks[2], size: half, cornerRadius: 0)
                    ArtworkView(artwork: mix.artworks[3], size: half, cornerRadius: 0)
                }
            }
            .frame(width: side, height: side)
        } else {
            ArtworkView(
                artwork: mix.artwork,
                size: side,
                cornerRadius: 0,
                placeholder: mix.isArtist ? .artist : .music
            )
            .frame(width: side, height: side)
        }
    }
}
