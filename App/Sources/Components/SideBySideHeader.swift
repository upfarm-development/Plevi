import SwiftUI
import PleviDomain

/// A page's artwork stood beside its words, for a window wide enough that a full-bleed cover would
/// be a wall.
struct SideBySideHeader<Details: View, About: View>: View {
    let artwork: ArtworkID?
    let palette: ArtworkPalette
    var placeholder: ArtworkPlaceholder = .music
    /// The step between the foot of this header and whatever the page puts next.
    var bottomGap: CGFloat = PageMetrics.headerBottomGap
    /// The name, the facts and the controls. Intrinsically sized: its height
    /// is what decides the About budget.
    @ViewBuilder var details: Details
    /// Given the room left between the foot of `details` and the foot of the card.
    @ViewBuilder var about: (CGFloat) -> About

    @State private var detailsHeight: CGFloat = PageMetrics.detailsHeightSeed

    var body: some View {
        HStack(alignment: .top, spacing: PageMetrics.columnGutter) {
            card
            VStack(alignment: .leading, spacing: 0) {
                details
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        detailsHeight = $0
                    }
                about(aboutRoom)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, PageMetrics.pageMargin)
        .padding(.top, PageMetrics.headerTopGap)
        .padding(.bottom, bottomGap)
    }

    /// How much prose there is room for before the card's foot.
    private var aboutRoom: CGFloat {
        max(0, PageMetrics.artworkSide - detailsHeight - PageMetrics.aboutTopGap)
    }

    /// The card.
    private var card: some View {
        ArtworkView(
            artwork: artwork,
            size: PageMetrics.artworkSide,
            cornerRadius: PageMetrics.artworkCorner,
            placeholder: placeholder
        )
        .overlay {
            // A hairline, struck from the page's own foreground — which `PleviPalette` guarantees
            // against the background, so it reads on a page a pale cover made pale and on one a
            // dark cover made near-black.
            RoundedRectangle(cornerRadius: PageMetrics.artworkCorner)
                .strokeBorder(palette.foreground.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: 18, y: 8)
    }

    /// Lighter on a page the artwork made pale.
    private var shadowOpacity: Double {
        palette.chromeScheme == .light ? 0.22 : 0.38
    }
}
