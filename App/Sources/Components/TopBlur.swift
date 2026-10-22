import SwiftUI

/// The soft wash under the status bar, arriving as the artwork leaves.
struct TopBlur: ViewModifier {
    /// How far the wash is darkened, and how much colour it keeps.
    private static let darken: Double = 0.54
    private static let colour: Double = 3.2

    /// How tall the wash is. Measured off the system's own; see above.
    private static let height: CGFloat = 145
    /// Over how much scrolling it comes up, ending as the foot of the artwork reaches the toolbar.
    private static let arrivesOver: CGFloat = 90

    /// Whether the wash has a cover to be timed against.
    var enabled = true

    @State private var progress: CGFloat = 0
    /// Where the toolbar row begins, which is the line the artwork's foot is timed against.
    @State private var topInset: CGFloat = 0

    /// The artwork is square and starts at the very top of the content —
    /// these pages ignore the top safe area — so the width of the scroll
    /// view is also how far it has to travel to be gone.
    private struct Metrics: Equatable {
        var offset: CGFloat
        var width: CGFloat
        /// What the page is inset by at its head.
        var insetTop: CGFloat
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .saturation(Self.colour)
                    .overlay(Color.black.opacity(Self.darken))
                    .frame(height: Self.height)
                    // Solid at the very top and gone by its foot, so it has
                    // no edge of its own to give itself away — the same
                    // reason the header's own fade runs long.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white.opacity(0.85), location: 0.45),
                                .init(color: .white.opacity(0.35), location: 0.75),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(enabled ? progress : 0)
                    .allowsHitTesting(false)
                    .ignoresSafeArea(edges: .top)
                    .background(SafeAreaTopReader { topInset = $0 })
            }
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(
                    offset: geometry.contentOffset.y,
                    width: geometry.containerSize.width,
                    insetTop: geometry.contentInsets.top
                )
            } action: { _, now in
                guard enabled else {
                    if progress != 0 { progress = 0 }
                    return
                }
                // How far the page has travelled, taken from its own geometry rather than from
                // whatever the first reading happened to be: a page restored already scrolled would
                // have had that first reading treated as its resting place, and the wash timed…
                let scrolled = now.offset + now.insetTop
                // Where the foot of the cover has got to on screen. The
                // cover is square and starts at the very top of the content,
                // so it begins one width down and rises as the page scrolls.
                let coverFoot = now.width - scrolled
                // Timed against the toolbar rather than the top of the screen: the wash is fully
                // there as the cover's foot passes behind the buttons, and begins coming up
                // `arrivesOver` before it gets there.
                let stillToGo = coverFoot - topInset
                let ramp = 1 - min(1, max(0, stillToGo / Self.arrivesOver))
                // Rounded to twentieths so a scroll does not rewrite this on every frame: the
                // overlay is a material, and redrawing one sixty times a second to move its opacity
                // by a thousandth is work nobody can see.
                let stepped = (ramp * 20).rounded() / 20
                if stepped != progress { progress = stepped }
            }
    }
}

/// Reports the window's top safe-area inset, for the reason on
/// `TopBlur.topInset`.
private struct SafeAreaTopReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> Reader {
        let reader = Reader()
        // It measures; it must never be touched.
        reader.isUserInteractionEnabled = false
        reader.onChange = onChange
        return reader
    }

    func updateUIView(_ uiView: Reader, context: Context) {
        uiView.onChange = onChange
    }

    final class Reader: UIView {
        var onChange: ((CGFloat) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            let inset = window.safeAreaInsets.top
            DispatchQueue.main.async { [onChange] in onChange?(inset) }
        }
    }
}

extension View {
    /// See `TopBlur`.
    func topBlurAsArtworkLeaves(_ enabled: Bool = true) -> some View {
        modifier(TopBlur(enabled: enabled))
    }
}
