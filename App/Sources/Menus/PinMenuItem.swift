import SwiftUI
import PleviDomain

/// Keep this on Home, or stop keeping it.
struct PinMenuItem: View {
    let item: PinnedItem
    let pins: PinBoard

    var body: some View {
        let pinned = pins.isPinned(item)
        Button(
            pinned ? "Unpin from Home" : "Pin to Home",
            systemImage: pinned ? "pin.slash" : "pin"
        ) {
            pins.toggle(item)
        }
    }
}
