import SwiftUI
import PleviDomain

/// One playlist, as both the tab and the add-to-playlist picker draw it.
struct PlaylistRow: View {
    let playlist: Playlist
    /// Marks a playlist being held at the top of the list.
    ///
    /// Off by default, so the add-to-playlist picker — which shares this row
    /// — does not carry a mark for something that has no bearing on choosing
    /// where to put a song.
    var isPinnedToTop = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: playlist.artwork, size: CompactList.thumbnailSize)
            VStack(alignment: .leading, spacing: 1) {
                // Baseline-aligned, so on a name long enough to wrap the
                // mark sits beside the first line rather than floating at
                // the middle of the block.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(playlist.name)
                        .foregroundStyle(.primary)
                    if isPinnedToTop {
                        // The same mark its menu item uses, and deliberately not a pushpin: a pin
                        // in this app means pinned to Home, and two different pins in one list
                        // would be one too many.
                        Image(systemName: "arrow.up.to.line")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            // Never the thing that gives way: a long name would otherwise squeeze
                            // the mark out before it truncated itself, and the row would silently
                            // stop saying it was pinned.
                            .layoutPriority(1)
                            .accessibilityLabel("Pinned to top")
                    }
                }
                // The line is there even before the number is, so a smart
                // playlist's count arriving does not make the whole list
                // jump a few points.
                Text(playlist.trackCount.map { $0.counted("song") } ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        // Held to the same height as every other row, rather than left to
        // whatever the text comes to: a name long enough to wrap would
        // otherwise make one row taller than its neighbours.
        .frame(minHeight: CompactList.rowHeight)
    }
}
