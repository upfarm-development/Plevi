import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// What you have put on lately — records and playlists together.
struct RecentlyPlayedShelf: View {
    let entries: [PlayedEntry]

    @Environment(AppModel.self) private var app
    /// True lengths for the playlists on this shelf, once asked for.
    @State private var counts: [MediaID: Int] = [:]
    /// The records behind the album cards, looked up once.
    @State private var albums: [MediaID: Album] = [:]
    /// Ids the lookup ran for and did not find, so a record that has left
    /// the library is not asked about again on every pass.
    @State private var missing: Set<MediaID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(HomeSection.recentlyPlayed.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(entries) { entry in
                        card(entry)
                            .contextMenu {
                                // An album on the shelf offers what it does
                                // everywhere else; one not found yet, or a
                                // playlist, only the removal.
                                if entry.source.kind == .album, let album = albums[entry.source.mediaID] {
                                    AlbumMenuContent(album: album, actions: MediaActions(app: app))
                                    Divider()
                                }
                                Button("Remove from Recently Played", systemImage: "xmark") {
                                    app.playLog.remove(entry)
                                }
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
        .task(id: entries.map(\.id)) { await resolveAlbums() }
        .task(id: entries.map(\.id)) { await countPlaylists() }
    }

    /// Asks the server how long each playlist on the shelf really is.
    private func countPlaylists() async {
        guard let provider = app.provider else { return }
        let wanted = entries
            .filter { $0.source.kind == .playlist && counts[$0.source.mediaID] == nil }
            .map(\.source.mediaID)
        guard !wanted.isEmpty else { return }
        for id in wanted {
            guard !Task.isCancelled else { return }
            if let page = try? await provider.playlistPage(id: id, offset: 0, limit: 1),
               let total = page.total {
                counts[id] = total
            }
        }
    }

    /// What the card says under its name: the true length where it is known,
    /// and whatever was recorded otherwise.
    private func subtitle(_ entry: PlayedEntry) -> String? {
        if entry.source.kind == .playlist, let known = counts[entry.source.mediaID] {
            return known.counted("song")
        }
        return entry.source.subtitle
    }

    /// Looks the album cards up, once, away from the body.
    private func resolveAlbums() async {
        guard let index = app.libraryIndex else { return }
        let wanted = entries
            .filter { $0.source.kind == .album }
            .map(\.source.mediaID)
            .filter { albums[$0] == nil && !missing.contains($0) }
        guard !wanted.isEmpty else { return }
        // A record put on from another library's search results is not in this library's index.
        let others = app.isOffline ? [] : app.otherQuickLibraryIndexes().map(\.index)
        let found = await Task.detached(priority: .userInitiated) { [wanted] in
            var found: [MediaID: Album] = [:]
            for id in wanted {
                if let album = (try? index.album(id: id)) ?? others.lazy.compactMap({ try? $0.album(id: id) }).first {
                    found[id] = album
                }
            }
            return found
        }.value
        guard !Task.isCancelled else { return }
        for id in wanted where found[id] == nil { missing.insert(id) }
        albums.merge(found) { _, new in new }
    }

    @ViewBuilder
    private func card(_ entry: PlayedEntry) -> some View {
        switch entry.source.kind {
        case .album:
            // Resolved against the index so the card opens the real record with everything on it,
            // and falls back to what was recorded if the library no longer has it.
            if let album = albums[entry.source.mediaID] {
                NavigationLink(value: album) { face(entry) }
                    .buttonStyle(.plain)
            } else if missing.contains(entry.source.mediaID) {
                gone(entry)
            } else {
                // The lookup has not come back yet. The card is drawn and
                // simply does not lead anywhere for the moment.
                face(entry)
            }
        case .playlist:
            NavigationLink(value: entry.source.asPlaylist) { face(entry) }
                .buttonStyle(.plain)
                .warmsPlaylist(entry.source.asPlaylist)
        }
    }

    /// Recorded, then removed from the library — or recorded before a sync
    /// finished. It keeps its place rather than vanishing without
    /// explanation, and says so when tapped.
    private func gone(_ entry: PlayedEntry) -> some View {
        Button {
            // Offline it is named, not opened: the download queue and the
            // detail pages belong to the active library.
            if let other = app.quickLibrary(named: entry.source.mediaID.server) {
                app.showTransientError("\(entry.source.title) is in \(other.title). Switch to that library to open it.")
            } else {
                app.showTransientError("\(entry.source.title) isn't in your library any more.")
            }
        } label: {
            face(entry).opacity(0.5)
        }
        .buttonStyle(.plain)
    }

    private func face(_ entry: PlayedEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(
                artwork: entry.source.artwork,
                size: Self.size,
                cornerRadius: 8,
                placeholder: .music
            )
            Text(entry.source.title)
                .font(.subheadline)
                .lineLimit(1)
            // A blank line where there is no subtitle, so the cards along the
            // row keep their sleeves level with each other.
            Text(subtitle(entry) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.size, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            subtitle(entry).map { "\(entry.source.title), \($0)" } ?? entry.source.title
        )
    }

    private static let size: CGFloat = 128
}
