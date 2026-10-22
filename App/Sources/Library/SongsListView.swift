import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// Every song in the library, in one list.
struct SongsListView: View {
    @Environment(AppModel.self) private var app

    /// The half of the cache key that belongs to the world rather than to this screen, handed in
    /// rather than read from the environment: the environment is not installed during `init`, and
    /// the kept list has to be picked up there to beat the first…
    private let cache: SongListCache
    private let library: ServerID?
    private let version: Int
    private let offline: Bool

    /// In bar order, and filed, so the list can draw slices of it.
    @State private var tracks: [Track]
    @State private var runs: AlphabetIndex.SectionRuns
    @State private var order: LibraryIndex.SongOrder
    @State private var direction: LibraryIndex.SortDirection
    @State private var loading = false
    @State private var filter: LibraryFilter
    @State private var editingFilter = false
    /// Whether what is already on screen came from the cache, and so the
    /// first reload can be skipped.
    @State private var isSeeded: Bool

    init(cache: SongListCache, library: ServerID?, version: Int, offline: Bool) {
        self.cache = cache
        self.library = library
        self.version = version
        self.offline = offline
        // Whatever is held, if it still answers for this library, this version and this connection.
        let held = cache.anything().flatMap { entry -> SongListCache.Entry? in
            guard let library,
                  entry.key.library == library,
                  entry.key.version == version,
                  entry.key.offline == offline
            else { return nil }
            return entry
        }
        _tracks = State(initialValue: held?.tracks ?? [])
        _runs = State(initialValue: held?.runs ?? AlphabetIndex.SectionRuns())
        _order = State(initialValue: held?.key.order ?? .alphabeticalByTitle)
        _direction = State(initialValue: held?.key.direction ?? .forward)
        _filter = State(initialValue: held?.key.filter ?? LibraryFilter(subject: .songs))
        _isSeeded = State(initialValue: held != nil)
    }

    var body: some View {
        content
            .navigationTitle("Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingFilter = true
                    } label: {
                        Image(systemName: filter.isEmpty
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel(filter.isEmpty ? "Filter" : "Filter, on")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SortMenu(order: $order, direction: $direction)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    KeepListActions(
                        subject: .songs, filter: filter,
                        songOrder: order, albumOrder: nil, direction: direction
                    )
                }
            }
            .task(id: taskKey) { await load() }
            .safeAreaInset(edge: .bottom) {
                if tracks.count >= Self.listLimit {
                    Text("Showing the first \(Self.listLimit.formatted()) songs")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.bar)
                }
            }
            .sheet(isPresented: $editingFilter) {
                LibraryFilterSheet(subject: .songs, filter: filter) { filter = $0 }
            }
    }

    /// Reloads when the order changes, and when going offline changes what can actually play — and
    /// when a sync lands, which a list opened during the first one would otherwise sit on 'No
    /// songs' through.
    private var taskKey: String {
        "\(order.rawValue)|\(direction.rawValue)|\(app.isOffline)|\(app.syncRevision)|\(filter)"
    }

    /// The most songs one list holds. The library can be larger; the list
    /// says so rather than stopping without a word.
    nonisolated private static let listLimit = 100_000

    @ViewBuilder
    private var content: some View {
        if loading && tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tracks.isEmpty {
            ContentUnavailableView(
                "No songs",
                systemImage: "music.note",
                description: Text(filterIsWhy
                                  ? "No songs match the filter."
                                  : app.isOffline
                                    ? "Nothing is downloaded yet."
                                    : "This library has no songs in it.")
            )
        } else if order.isAlphabetical {
            // The jump bar is the only sane way through sixty thousand rows,
            // and it files them by whatever the list is sorted on.
            IndexedList(items: tracks, title: filedUnder, groupingKey: taskKey, runs: runs) { track in
                row(for: track)
            }
        } else {
            List(tracks) { track in
                row(for: track).listRowInsets(CompactList.indexedRowInsets)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollIndicators(.hidden)
        }
    }

    private var filterIsWhy: Bool { !filter.isEmpty }

    private func filedUnder(_ track: Track) -> String {
        order == .alphabeticalByArtist ? (track.artistName ?? track.displayTitle) : track.displayTitle
    }

    private func row(for track: Track) -> some View {
        SongRow(track: track)
            // On the row, not behind it — see `AlbumDetailView`'s list.
            .contentShape(Rectangle())
            .onTapGesture { play(from: track) }
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

    private func play(from track: Track) {
        guard let start = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        app.activePlayer.play(tracks, startingAt: start, from: .songs)
    }

    private func load() async {
        // Already on screen, and still true: the task fires once when the
        // screen appears whether or not anything needs doing.
        if isSeeded {
            isSeeded = false
            return
        }
        guard let index = app.libraryIndex else { return }
        let key = taskKey
        loading = true
        // Guarded, or a superseded load's own defer clears the flag a live one just set —
        // `.task(id:)` does not await the task it replaces, so the old one keeps running to this
        // point regardless, and firing unconditionally would flash "No songs" for…
        defer { if key == taskKey { loading = false } }
        let chosen = order
        let way = direction
        let offline = app.isOffline
        let asked = filter
        // A rule about a playlist is answered against the index's copy of it, and that copy holds
        // the songs of a playlist only once something has asked for them.
        await app.fillPlaylistMembership(askedBy: asked)
        guard !Task.isCancelled, asked == filter else { return }
        // Read before the query, not after it: a rating bump that lands while the read is running
        // is then not claimed by rows that predate it.
        let versionAtRead = app.libraryVersion
        // Detached for where it runs, cancelled by hand for when it stops.
        let work = Task.detached(priority: .userInitiated) {
            Self.read(index, order: chosen, direction: way, filter: asked, offline: offline)
        }
        let (rows, filed) = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        // A cancelled read answers with nothing, which is not an answer.
        guard !Task.isCancelled, chosen == order, way == direction, asked == filter else { return }
        tracks = rows
        runs = filed
        // Kept for the next visit, under the version read just before the query rather than the one
        // captured at init: rating a song from this very list bumps it, and storing under a version
        // already gone stale would mean the entry could never be…
        if let library {
            cache.store(SongListCache.Entry(
                key: SongListCache.Key(
                    library: library,
                    version: versionAtRead,
                    offline: offline,
                    order: chosen,
                    direction: way,
                    filter: asked
                ),
                tracks: rows,
                runs: filed
            ))
        }
    }

    /// The rows, and where each letter's run sits in them.
    nonisolated private static func read(
        _ index: LibraryIndex,
        order: LibraryIndex.SongOrder,
        direction: LibraryIndex.SortDirection,
        filter: LibraryFilter,
        offline: Bool
    ) -> ([Track], AlphabetIndex.SectionRuns) {
        let rows = filter.isEmpty
            ? (try? index.tracks(
                order: order, direction: direction,
                limit: listLimit, downloadedOnly: offline
            )) ?? []
            : (try? index.tracks(
                matching: filter, order: order, direction: direction,
                limit: listLimit, downloadedOnly: offline
            )) ?? []
        // The read itself cannot be interrupted part way, but the filing
        // after it can be skipped for a screen nobody is looking at any more.
        guard !Task.isCancelled else { return ([], .init()) }
        // The jump bar reads A at the top and Z at the bottom. Run the list
        // backwards and the bar would point at the right rows under the
        // wrong letters, so it stands down rather than lying.
        guard order.isAlphabetical, direction == .forward else { return (rows, .init()) }
        let key: (Track) -> String
        switch order {
        case .alphabeticalByArtist: key = { $0.artistName ?? $0.displayTitle }
        case .alphabeticalByAlbum: key = { $0.albumName ?? $0.displayTitle }
        default: key = { $0.displayTitle }
        }
        return AlphabetIndex.filed(rows, title: key)
    }
}


/// One song, which knows for itself whether it is the one playing.
private struct SongRow: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        TrackRow(
            track: track,
            isCurrent: app.activePlayer.currentTrack?.id == track.id,
            showsRating: true,
            showsPosition: false,
            showsArtwork: true
        )
    }
}
