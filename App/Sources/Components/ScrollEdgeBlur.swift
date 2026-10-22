import SwiftUI

extension View {
    /// Switches off the blur iOS draws at the top and bottom of a scrolling page.
    func withoutBottomScrollEdgeBlur() -> some View {
        scrollEdgeEffectHidden(true, for: .bottom)
    }

    /// - Parameter topToo: false where the page's artwork no longer runs to the top of the screen.
    func withoutScrollEdgeBlur(topToo: Bool = true) -> some View {
        scrollEdgeEffectHidden(true, for: topToo ? [.top, .bottom] : .bottom)
    }
}
