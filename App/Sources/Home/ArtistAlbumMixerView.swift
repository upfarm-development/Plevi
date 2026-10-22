import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// Where the Artist & Album Mixer is assembled.
struct ArtistAlbumMixerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    /// Albums the server says sound like the selection, kept apart from the
    /// genre-matched ones so they can be shown first when they arrive.
    @State private var sonic: [Album] = []
    @State private var isBuilding = false
    @FocusState private var searchFocused: Bool

    private var store: ArtistAlbumMixerStore { app.artistAlbumMixer }

    /// Four across, four down. The columns come from the width; the rows are
    /// held to this and the sleeves sized to suit — see `grid`.
    private static let columns = 4
    private static let rows = 4
    /// Below this a sleeve stops being something you can recognise at a
    /// glance, which is the whole job of the grid. Rather than shrink past
    /// it, the grid drops to however many rows it can show properly.
    private static let smallestReadableSleeve: CGFloat = 62

    var body: some View {
        // Both rows are always here, whether or not anything is picked.
        VStack(spacing: 0) {
            searchField
            selectionRow
            emphasisPicker
            grid
        }
        .background(Color(.systemBackground))
        .navigationTitle("Artist & Album Mixer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isBuilding {
                    ProgressView()
                } else {
                    Button("Play", systemImage: "play.fill") { Task { await play() } }
                        .disabled(store.isEmpty)
                }
            }
            if !store.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear All") { store.clear() }
                }
            }
        }
        .task {
            store.refresh(index: app.libraryIndex)
            reloadGrid()
        }
        // Debounced the way Search's own field is, so a fast typist does not
        // run a query per keystroke.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            reloadGrid()
        }
        // What is picked changes what the grid should be offering, but only
        // while nothing is being typed — a search stands until it is cleared.
        .onChange(of: store.selection) { _, _ in
            guard trimmedQuery.isEmpty else { return }
            reloadGrid()
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The field, which never leaves

    /// A field of its own rather than `.searchable`, which hides itself as soon as anything under
    /// it scrolls — on a screen whose whole point is that the field and the selection stay put,
    /// that is the one thing it must not do.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Artists and albums", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: What is in the mix

    /// Directly under the field, so adding something has a visible landing
    /// place. Scrolls sideways when there are more than fit; never wraps,
    /// because a growing strip would push the grid around.
    @ViewBuilder
    private var selectionRow: some View {
        Group {
            if store.isEmpty {
                // Holds the row's height open so nothing below it moves when
                // the first thing is added or the last one taken away, and
                // says what the row is for while it is empty.
                Text("Tap below to add artists and albums")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(store.selection) { item in
                            chip(for: item)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .frame(height: 44)
        .padding(.bottom, 8)
    }

    private func chip(for item: ArtistAlbumMixerStore.Item) -> some View {
        HStack(spacing: 7) {
            ArtworkView(
                artwork: item.artwork,
                size: 26,
                cornerRadius: item.isArtist ? 13 : 3,
                placeholder: item.isArtist ? .artist : .music
            )
            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
            Button {
                store.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.name)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: Capsule())
        .frame(maxWidth: 200, alignment: .leading)
    }

    // MARK: How it leans

    /// Titled, because sitting directly above a grid of records it otherwise reads as a filter on
    /// the grid rather than a choice about the mix.
    private var emphasisPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Which songs the mix favours")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Which songs the mix favours", selection: emphasisBinding) {
                ForEach(ArtistAlbumMix.Emphasis.allCases, id: \.self) { emphasis in
                    Text(emphasis.title).tag(emphasis)
                }
            }
            .pickerStyle(.segmented)
            // Dimmed rather than hidden while there is nothing to apply it
            // to: taking it away would move everything under it.
            .disabled(store.isEmpty)

            Text(store.emphasis.subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var emphasisBinding: Binding<ArtistAlbumMix.Emphasis> {
        Binding(get: { store.emphasis }, set: { store.emphasis = $0 })
    }

    // MARK: The grid

    /// Four rows of four, sized to whatever the page has left.
    private var grid: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 12
            let byWidth = ((proxy.size.width - 32 - spacing * CGFloat(Self.columns - 1))
                / CGFloat(Self.columns)).rounded(.down)
            // The room a row needs beyond its sleeve: the gap under it and
            // two lines of name.
            let textHeight: CGFloat = 35
            let byHeight = (
                (proxy.size.height - spacing * CGFloat(Self.rows - 1)) / CGFloat(Self.rows)
                    - textHeight
            ).rounded(.down)

            let fitted = min(byWidth, byHeight)
            // Four rows at a readable size, or as many whole rows as a
            // width-sized sleeve leaves — never a fourth row so small the
            // sleeves stop being recognisable.
            let rows = fitted >= Self.smallestReadableSleeve
                ? Self.rows
                : max(1, Int((proxy.size.height + spacing) / (byWidth + textHeight + spacing)))
            let side = max(fitted >= Self.smallestReadableSleeve ? fitted : byWidth, 1)
            let items = Array(gridItems.prefix(rows * Self.columns))

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: Self.columns),
                spacing: spacing
            ) {
                ForEach(items) { item in
                    cell(for: item, side: side)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .overlay { if items.isEmpty { emptyState } }
        }
    }

    private func cell(for item: ArtistAlbumMixerStore.Item, side: CGFloat) -> some View {
        let picked = store.contains(item)
        return VStack(spacing: 5) {
            ArtworkView(
                artwork: item.artwork,
                size: side,
                cornerRadius: item.isArtist ? side / 2 : 6,
                placeholder: item.isArtist ? .artist : .music
            )
            .overlay(alignment: .bottomTrailing) {
                // Only when picked: an empty circle on every sleeve would
                // read as nine things waiting to be ticked off.
                if picked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                }
            }
            .overlay {
                if picked {
                    RoundedRectangle(cornerRadius: item.isArtist ? side / 2 : 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }

            // The sleeve and the name, and nothing else: a round portrait already says "artist" and
            // a square sleeve says "album", so a second line naming which would be the picture
            // repeated in words — and at a quarter of a phone there is no room to…
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            searchFocused = false
            store.toggle(item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !trimmedQuery.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            ContentUnavailableView(
                "Build a Mix",
                systemImage: "slider.horizontal.3",
                description: Text("Search for artists and albums to draw from, then play them as one mix.")
            )
        }
    }

    /// Artists first, then albums, so the grid reads as "who" before "what" — and so typing a name
    /// puts the artist themselves in the first cell with their records following.
    private var gridItems: [ArtistAlbumMixerStore.Item] {
        var seen: Set<MediaID> = []
        let ordered = (sonic + albums).filter { seen.insert($0.id).inserted }
        return artists.map(ArtistAlbumMixerStore.Item.artist)
            + ordered.map(ArtistAlbumMixerStore.Item.album)
    }

    // MARK: Filling it

    private func reloadGrid() {
        guard let index = app.libraryIndex else {
            artists = []
            albums = []
            sonic = []
            return
        }
        let offline = app.isOffline
        // Enough for the deepest grid any phone will draw, and cheap either
        // way — every one of these is a local query.
        let wanted = 32

        if !trimmedQuery.isEmpty {
            let found = (try? index.search(trimmedQuery, limit: wanted, downloadedOnly: offline))
            artists = found?.artists ?? []
            albums = found?.albums ?? []
            // A search is its own answer; nothing sonic belongs in it.
            sonic = []
            return
        }
        if !store.isEmpty {
            let ids = store.selectionIDs()
            let near = try? index.mixerNeighbours(
                artistIDs: ids.artists, albumIDs: ids.albums, limit: wanted
            )
            artists = near?.artists ?? []
            albums = near?.albums ?? []
            // A selection with no genre behind it has no neighbours; rather
            // than an empty page, fall back to what was played lately.
            if artists.isEmpty && albums.isEmpty { fillWithRecentlyPlayed(index, wanted: wanted) }
            Task { await loadSonic(index: index, for: ids) }
            return
        }
        sonic = []
        fillWithRecentlyPlayed(index, wanted: wanted)
    }

    /// Asks the server what actually sounds like the selection, and slots the answer in ahead of
    /// the genre matches when it arrives.
    private func loadSonic(
        index: LibraryIndex,
        for selection: (artists: [MediaID], albums: [MediaID])
    ) async {
        guard let provider = app.provider,
              provider.capabilities.contains(.similarAlbums),
              !app.isOffline
        else { return }

        // The most recently added few, because those are what the listener
        // was just thinking about — and a cap, so a selection of twenty does
        // not become twenty requests.
        let seeds = probeAlbums(index: index).suffix(3)
        guard !seeds.isEmpty else { return }

        var found: [Album] = []
        for seed in seeds {
            if let kept = store.sonicNeighbours(of: seed) {
                found += kept
                continue
            }
            let fetched = (try? await provider.similarAlbums(to: seed, limit: 12)) ?? []
            // Only what is actually in this library: a server can name a
            // record it knows of but does not hold, and a cell that cannot
            // be added is worse than no cell.
            let held = fetched.compactMap { try? index.album(id: $0.id) }
            store.rememberSonicNeighbours(held, of: seed)
            found += held
        }

        // The selection itself is not a suggestion, and neither is anything
        // by an artist already picked.
        let pickedAlbums = Set(store.selectionIDs().albums)
        let pickedArtists = Set(store.selectionIDs().artists)
        var seen: Set<MediaID> = []
        let usable = found.filter { album in
            guard !pickedAlbums.contains(album.id) else { return false }
            if let artistID = album.artistID, pickedArtists.contains(artistID) { return false }
            return seen.insert(album.id).inserted
        }
        // Only if the grid still belongs to this selection — a tap while the request was in flight
        // has already asked a different question, and a selection swapped for another non-empty one
        // is exactly that: not empty, but not this request's either.
        let current = store.selectionIDs()
        guard trimmedQuery.isEmpty,
              Set(current.artists) == Set(selection.artists),
              Set(current.albums) == Set(selection.albums)
        else { return }
        sonic = usable
    }

    /// One album per seed to ask about: a picked album speaks for itself, and
    /// a picked artist is asked about through one of their own records, since
    /// the server's similarity is album to album.
    private func probeAlbums(index: LibraryIndex) -> [MediaID] {
        store.selection.compactMap { item in
            switch item {
            case .album(let album): album.id
            case .artist(let artist): (try? index.albums(forArtist: artist.id))?.first?.id
            }
        }
    }

    private func fillWithRecentlyPlayed(_ index: LibraryIndex, wanted: Int) {
        let recent = try? index.mixerRecentlyPlayed(limit: wanted)
        artists = recent?.artists ?? []
        albums = recent?.albums ?? []
    }

    // MARK: Playing it

    /// Gathers the pool and draws the mix off the main actor, then hands the finished queue to the
    /// player.
    private func play() async {
        guard let index = app.libraryIndex else { return }
        let ids = store.selectionIDs()
        let emphasis = store.emphasis
        let artistCount = store.artistCount
        let downloadedOnly = app.isOffline
        // Read before the build below suspends — see PlaybackDestination.
        let player = app.activePlayer

        isBuilding = true
        defer { isBuilding = false }

        let tracks = await Task.detached(priority: .userInitiated) {
            let pool = ArtistAlbumMixerStore.pool(
                index: index,
                artistIDs: ids.artists,
                albumIDs: ids.albums,
                downloadedOnly: downloadedOnly
            )
            var generator = SystemRandomNumberGenerator()
            return ArtistAlbumMix.build(
                pool: pool,
                limit: ArtistAlbumMix.queueLength,
                emphasis: emphasis,
                artistCount: artistCount,
                using: &generator
            )
        }.value

        guard !tracks.isEmpty else {
            app.showTransientError(
                downloadedOnly
                    ? "Nothing from that selection is downloaded."
                    : "Nothing in that selection to play."
            )
            return
        }
        player.play(tracks, startingAt: 0, from: .radio)
        dismiss()
    }
}
