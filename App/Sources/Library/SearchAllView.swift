import SwiftUI
import PleviDomain

/// Everything a search found of one kind.
struct SearchAllView: View {
    let kind: SearchResultKind
    let query: String
    let results: SearchResults

    @Environment(AppModel.self) private var app

    private static let thumbnailSize = CompactList.thumbnailSize
    private static let rowInsets = CompactList.rowInsets

    var body: some View {
        let siblingTitles = app.siblingLibraryTitles
        List {
            switch kind {
            case .artists:
                ForEach(results.artists) { artist in
                    NavigationLink(value: artist) {
                        HStack(spacing: 12) {
                            ArtworkView(
                                artwork: artist.artwork,
                                size: Self.thumbnailSize,
                                cornerRadius: Self.thumbnailSize / 2,
                                placeholder: .artist
                            )
                            Text(artist.name).lineLimit(1).truncationMode(.tail)
                            LibraryBadge(titles: siblingTitles, server: artist.id.server)
                        }
                    }
                    .listRowInsets(Self.rowInsets)
                    .artistContextMenu(artist, actions: MediaActions(app: app))
                }
            case .albums:
                ForEach(results.albums) { album in
                    NavigationLink(value: album) {
                        HStack(spacing: 12) {
                            ArtworkView(artwork: album.artwork, size: Self.thumbnailSize)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(album.name).lineLimit(1)
                                Text(album.artistName ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            LibraryBadge(titles: siblingTitles, server: album.id.server)
                        }
                    }
                    .listRowInsets(Self.rowInsets)
                    .albumContextMenu(album, actions: MediaActions(app: app))
                }
            case .playlists:
                ForEach(results.playlists) { playlist in
                    NavigationLink(value: playlist) {
                        HStack(spacing: 12) {
                            ArtworkView(
                                artwork: playlist.artwork,
                                size: Self.thumbnailSize,
                                cornerRadius: 6
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name).lineLimit(1)
                                if let count = playlist.trackCount {
                                    Text("\(count) song\(count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listRowInsets(Self.rowInsets)
                }
            case .songs:
                ForEach(Array(results.tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        app.activePlayer.play(results.tracks, startingAt: index, from: .songs)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(artwork: track.artwork, size: Self.thumbnailSize)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).lineLimit(1)
                                Text(track.artistName ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            LibraryBadge(titles: siblingTitles, server: track.id.server)
                            if app.activePlayer.currentTrack?.id == track.id {
                                Image(systemName: "waveform").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(Self.rowInsets)
                    .trackContextMenu(
                        track,
                        actions: MediaActions(app: app),
                        onGoToAlbum: track.albumID.map { id in
                            { app.requestNavigation(.album(id, name: track.albumName)) }
                        },
                        onGoToArtist: track.artistID.map { id in
                            { app.requestNavigation(.artist(id, name: track.artistName)) }
                        }
                    )
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
