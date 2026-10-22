import SwiftUI
import PleviDomain

/// Holding a playlist at the top of the playlists list, or letting it go.
struct TopPinMenuItem: View {
    let playlist: Playlist
    let pins: TopPinnedPlaylists

    var body: some View {
        let pinned = pins.isPinned(playlist)
        Button(
            pinned ? "Unpin from Top" : "Pin to Top",
            systemImage: pinned ? "arrow.down.to.line" : "arrow.up.to.line"
        ) {
            pins.toggle(playlist)
        }
    }
}
