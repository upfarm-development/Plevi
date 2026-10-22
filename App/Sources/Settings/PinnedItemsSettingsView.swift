import SwiftUI
import PleviDomain

/// The order the Pinned shelf shows things in.
struct PinnedItemsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.pins.items.isEmpty {
                // Outside the list rather than inside a section of it: an
                // empty state framed by a rounded grey box reads as a row you
                // failed to fill in.
                ContentUnavailableView(
                    "Nothing Pinned",
                    systemImage: "pin",
                    description: Text("Hold an album, artist or playlist anywhere in the app and choose Pin to Home.")
                )
            } else {
                List {
                    Section {
                        ForEach(app.pins.items) { item in
                            row(item)
                        }
                        .onMove { offsets, destination in
                            app.pins.move(fromOffsets: offsets, toOffset: destination)
                        }
                        .onDelete { offsets in
                            unpin(offsets)
                        }
                    }
                }
                // Always on, so the grips are there without having to find an
                // Edit button first. The shelves list this is reached from
                // does the same.
                .environment(\.editMode, .constant(.active))
            }
        }
        .navigationTitle("Pinned")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: PinnedItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(
                artwork: item.artwork,
                size: Self.thumbnail,
                cornerRadius: item.kind == .artist ? Self.thumbnail / 2 : 4,
                placeholder: item.kind == .artist ? .artist : .music
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                // What it is, rather than only who it is by: on a list mixing
                // albums, artists and playlists, "Pink Floyd" twice over is
                // two different taps.
                Text(item.subtitle ?? item.kind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Collected before anything is removed: unpinning shortens the list the
    /// offsets point into.
    private func unpin(_ offsets: IndexSet) {
        let doomed = offsets
            .filter { app.pins.items.indices.contains($0) }
            .map { app.pins.items[$0] }
        for item in doomed {
            app.pins.unpin(item)
        }
    }

    private static let thumbnail: CGFloat = 44
}

extension PinnedItem.Kind {
    /// What to call this kind of pin where there is nothing else to say about
    /// it — an artist has no subtitle of its own.
    var label: String {
        switch self {
        case .album: "Album"
        case .artist: "Artist"
        case .playlist: "Playlist"
        case .collection: "Collection"
        }
    }
}
