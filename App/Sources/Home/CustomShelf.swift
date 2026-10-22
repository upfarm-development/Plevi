import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// A Home shelf built from someone's own filter.
struct CustomShelf: View {
    let section: CustomHomeSection
    let albums: [Album]
    /// The handful Home shows when the shelf is set to draw as a list.
    let songs: [Track]
    let songCount: Int

    @Environment(AppModel.self) private var app

    /// Sleeves drawn on Home before "See More".
    static let shelfCards = 12
    /// The most songs Play, Shuffle and a tapped row queue when the shelf has
    /// no limit of its own: the same ceiling as the list behind "See More",
    /// so the count on the card is what actually plays. Not the radio's 200.
    nonisolated static let playCap = 10_000

    var body: some View {
        if section.showsAlbums {
            if !albums.isEmpty {
                AlbumShelf(
                    title: section.displayName,
                    // A dozen on Home, or fewer if the shelf keeps fewer;
                    // "See More" gets everything that was read.
                    albums: Array(albums.prefix(min(Self.shelfCards, section.limit ?? Self.shelfCards))),
                    collection: AlbumCollection(
                        title: section.displayName,
                        albums: albums,
                        showsArtist: true
                    ),
                    layout: app.settings.homeLayout(.custom(section.id))
                )
            }
        } else if songCount > 0 {
            if app.settings.homeLayout(.custom(section.id)) == .list, !songs.isEmpty {
                songList
            } else {
                songCard
            }
        }
    }

    private var songCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.displayName)
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            Button {
                play(shuffled: false)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(songCount.counted("song"))
                            .font(.subheadline.weight(.semibold))
                        Text("Tap to play")
                            .font(.caption)
                            .opacity(0.85)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.title3)
                }
                .foregroundStyle(.white)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Self.tint, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .contextMenu {
                // Glyphs on one row, matching every other long press in the
                // app rather than this one card reading as words on two.
                ControlGroup {
                    Button("Play", systemImage: "play.fill") { play(shuffled: false) }
                    Button("Shuffle", systemImage: "shuffle") { play(shuffled: true) }
                }
                .controlGroupStyle(.compactMenu)
            }
        }
    }

    /// The shelf as a list: the first few songs, and a way to the rest.
    private var songList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.displayName)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                // Only where there is more than is shown. A "More" that opens
                // the same five songs is a button that does nothing.
                if songCount > songs.count {
                    NavigationLink(value: CustomSongList(section: section)) {
                        Text("See More")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(songs) { track in
                    Button { play(from: track) } label: {
                        TrackRow(
                            track: track,
                            isCurrent: app.activePlayer.currentTrack?.id == track.id,
                            showsPosition: false,
                            showsArtwork: true
                        )
                        // The spacing an album row on Home carries — see `AlbumListRow`'s compact
                        // form, which pads itself by exactly this.
                        .padding(.horizontal)
                        .padding(.vertical, Self.rowPadding)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// What the shelf's rules find, in its own order and up to its limit.
    /// Read off the main actor: up to ten thousand rows.
    private func fetchSongs() async -> [Track] {
        guard let index = app.libraryIndex else { return [] }
        let section = section
        let offline = app.isOffline
        return await Task.detached(priority: .userInitiated) {
            (try? index.tracks(
                matching: section.filter,
                order: section.sort?.songOrder,
                direction: section.sort?.direction ?? .forward,
                limit: min(section.limit ?? Self.playCap, Self.playCap),
                downloadedOnly: offline
            )) ?? []
        }.value
    }

    /// Plays the shelf from the song tapped, so the rest of the list follows
    /// it rather than the tap being a single song on its own.
    private func play(from track: Track) {
        Task {
            let all = await fetchSongs()
            guard let start = all.firstIndex(where: { $0.id == track.id }) else { return }
            app.activePlayer.play(all, startingAt: start, from: .songs)
        }
    }

    /// What `AlbumListRow` gives its compact form, so the two kinds of Home
    /// list step at the same rate.
    static let rowPadding: CGFloat = 8

    private static let tint = Color(red: 0.36, green: 0.42, blue: 0.55)

    private func play(shuffled: Bool) {
        Task {
            let songs = await fetchSongs()
            guard !songs.isEmpty else {
                app.showTransientError("Nothing in your library matches \(section.displayName).")
                return
            }
            if shuffled {
                app.activePlayer.shuffle(songs, startingWith: nil, from: .songs, smart: nil)
            } else {
                app.activePlayer.play(songs, startingAt: 0, from: .radio)
            }
        }
    }
}
