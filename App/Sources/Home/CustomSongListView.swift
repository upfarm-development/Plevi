import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// What "More" on a song shelf opens: the whole list the shelf is the top of.
struct CustomSongList: Hashable {
    let section: CustomHomeSection
}

/// The songs a shelf's rules find, in the shelf's own order, as far as its limit goes.
struct CustomSongListView: View {
    let section: CustomHomeSection

    @Environment(AppModel.self) private var app
    @State private var tracks: [Track] = []
    @State private var loading = true

    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { play(from: index) } label: {
                    TrackRow(
                        track: track,
                        isCurrent: app.activePlayer.currentTrack?.id == track.id,
                        showsRating: true,
                        showsPosition: false,
                        showsArtwork: true
                    )
                    // The shelf's own spacing, carried through to the screen behind it: tapping See
                    // More should show more of the same list, not the same list set differently.
                    .padding(.horizontal)
                    .padding(.vertical, CustomShelf.rowPadding)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if loading && tracks.isEmpty {
                ProgressView()
            } else if !loading && tracks.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "music.note.list",
                    description: Text("Nothing in your library matches \(section.displayName).")
                )
            }
        }
        .navigationTitle(section.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Play", systemImage: "play.fill") { play(from: 0) }
                        Button("Shuffle", systemImage: "shuffle") {
                            app.activePlayer.shuffle(tracks, startingWith: nil, from: .songs, smart: nil)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        // Reloads when the library changes underneath it — a shelf of what
        // was played lately is out of date the moment something else is.
        .task(id: "\(app.libraryVersion)|\(app.isOffline)") { await load() }
    }

    private func load() async {
        guard let index = app.libraryIndex else { return }
        loading = true
        defer { loading = false }
        let asked = section
        let offline = app.isOffline
        let found = await Task.detached(priority: .userInitiated) {
            (try? index.tracks(
                matching: asked.filter,
                order: asked.sort?.songOrder,
                direction: asked.sort?.direction ?? .forward,
                // Without a limit of its own the shelf is everything the rules find, which on a
                // whole library is a screen nobody scrolls to the end of.
                limit: asked.limit ?? 10_000,
                downloadedOnly: offline
            )) ?? []
        }.value
        guard !Task.isCancelled else { return }
        tracks = found
    }

    /// Plays the list from the row tapped, so what follows is the rest of the
    /// list rather than one song on its own.
    private func play(from index: Int) {
        guard tracks.indices.contains(index) else { return }
        app.activePlayer.play(tracks, startingAt: index, from: .songs)
    }
}
