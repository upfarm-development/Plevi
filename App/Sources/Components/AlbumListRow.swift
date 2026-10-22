import SwiftUI
import PleviDomain

/// One album as a row: sleeve at the leading edge, name, and a line of context beneath it.
struct AlbumListRow: View {
    let album: Album
    var palette: ArtworkPalette = .neutral
    /// Names the artist under the title. Off on an artist's own page, where
    /// it would be the same name on every row; on for a shelf drawn from
    /// across the library, where it is half of what the row says.
    var showsArtist = false
    /// The tighter row Home's own lists use, matching Most Listened exactly — the same 40pt sleeve
    /// every compact list in the app is built around (`CompactList.thumbnailSize`), and the same
    /// height, so two list shelves stacked on Home step evenly…
    var compact = false

    private var artworkSize: CGFloat { compact ? CompactList.thumbnailSize : 52 }
    private var verticalPadding: CGFloat { compact ? 8 : 6 }

    private var subtitle: String? {
        let year = album.year.map(String.init)
        guard showsArtist else { return year }
        let parts = [album.artistName, year]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: album.artwork, size: artworkSize, cornerRadius: compact ? 6 : 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayName)
                    .font(.subheadline)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryForeground)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, verticalPadding)
        .contentShape(Rectangle())
    }
}
