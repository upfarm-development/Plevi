import SwiftUI
import PleviDomain

/// What a long press on a collection offers, wherever one is shown.
struct CollectionMenuContent: View {
    let collection: MediaCollection
    let actions: MediaActions
    let pins: PinBoard

    var body: some View {
        // Glyphs on one row, matching every other long press in the app
        // rather than this one reading as words on two lines.
        ControlGroup {
            Button("Play", systemImage: "play.fill") {
                actions.playCollection(collection, shuffled: false)
            }
            Button("Shuffle", systemImage: "shuffle") {
                actions.playCollection(collection, shuffled: true)
            }
        }
        .controlGroupStyle(.compactMenu)

        PinMenuItem(item: PinnedItem(collection: collection), pins: pins)
    }
}
