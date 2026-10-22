import SwiftUI
import PleviDomain

/// The five records that actually filled up a month, listed rather than laid out as cards — five
/// sleeves in a row read as five things to glance at, and what this shelf is actually saying is
/// closer to a ranking than a browse.
struct MostListenedList: View {
    let monthName: String
    let albums: [Album]
    let totalSeconds: [MediaID: TimeInterval]

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Most Listened to in \(monthName)")
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { offset, album in
                    NavigationLink(value: album) {
                        row(rank: offset + 1, album: album)
                    }
                    .buttonStyle(.plain)
                    if album.id != albums.last?.id {
                        Divider().padding(.leading, CompactList.thumbnailSize + 16 + 28)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func row(rank: Int, album: Album) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 20, alignment: .center)
            ArtworkView(artwork: album.artwork, size: CompactList.thumbnailSize, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayName)
                    .lineLimit(1)
                Text(album.artistName ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let seconds = totalSeconds[album.id] {
                Text(Duration.seconds(seconds).formatted(
                    .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .albumContextMenu(album, actions: MediaActions(app: app))
    }
}
