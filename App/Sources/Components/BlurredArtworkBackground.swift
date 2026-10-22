import SwiftUI

/// The artwork reduced to a handful of colours and drawn as one smooth gradient — Plexamp's
/// "ultrablur" rather than a blurred copy of the cover.
struct BlurredArtworkBackground: View {
    /// Row-major 3×3, from `ArtworkPalette.mesh`.
    let mesh: [Color]
    /// Used until the artwork arrives, so the page never flashes white.
    let fallback: Color

    /// An even 3×3 lattice. The gradient between the points does all the
    /// shaping, so moving them buys nothing but asymmetry.
    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    var body: some View {
        GeometryReader { proxy in
            // Drawn square and cropped, never fitted to the page.
            let side = max(proxy.size.width, proxy.size.height)
            ZStack {
                if mesh.count == Self.points.count {
                    MeshGradient(width: 3, height: 3, points: Self.points, colors: mesh)
                        .frame(width: side, height: side)
                } else {
                    fallback
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .overlay {
            // Keeps white text and thin controls legible over a pale cover.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.18), location: 0),
                    .init(color: .black.opacity(0.28), location: 0.5),
                    .init(color: .black.opacity(0.38), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}
