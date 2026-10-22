import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// One radio: a rule for picking songs, and how it looks on the shelf.
struct RadioStation: Identifiable, Hashable {
    enum Action: Hashable {
        case play(LibraryIndex.Station)
        case choose(RadioPicker.Kind)
    }

    let id: String
    let title: String
    let subtitle: String
    /// The mark that sits beside the name.
    let icon: RadioIcon
    /// The two colours the tile's gradient is struck from, in that order. The
    /// first doubles as the flat tint wherever one colour is all there is room
    /// for.
    let ramp: [Color]
    let action: Action

    var tint: Color { ramp.first ?? .accentColor }

    /// An SF Symbol for the station, for places that can only draw one.
    var tileSymbol: String {
        switch icon {
        case .symbol(let name): name
        case .faders: "slider.vertical.3"
        }
    }

    /// 135°: corner to corner, top-left to bottom-right.
    var gradient: LinearGradient {
        LinearGradient(colors: ramp, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func == (lhs: RadioStation, rhs: RadioStation) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The station wrapped in whichever control its action calls for — a button that starts it, or
    /// a link to the screen that asks first.
    @MainActor @ViewBuilder
    func view<Label: View>(
        width: CGFloat,
        @ViewBuilder label: (RadioStation) -> Label,
        play: @escaping (LibraryIndex.Station, String) -> Void
    ) -> some View {
        switch action {
        case .play(let rule):
            Button { play(rule, title) } label: { label(self) }
                .buttonStyle(RadioTileStyle())
        case .choose(let kind):
            NavigationLink(value: RadioPicker(kind: kind)) { label(self) }
                .buttonStyle(RadioTileStyle())
        }
    }
}

/// The list behind the Decades and Genres cards.
struct RadioPicker: Hashable {
    enum Kind: String, Hashable {
        case decades
        case genres
        /// Not a list of things to tick like the other two — it opens the
        /// mixer, which is a screen of its own. It travels this way because
        /// it is reached from the same shelf, by the same tap.
        case mixer

        var title: String {
            switch self {
            case .decades: "Decades"
            case .genres: "Genres"
            case .mixer: "Artist & Album Mixer"
            }
        }
    }

    let kind: Kind
}

/// The stations Home offers, in the order they appear.
enum RadioStations {
    static let queueLength = 200

    static func all(index: LibraryIndex, downloadedOnly: Bool) -> [RadioStation] {
        var stations: [RadioStation] = [
            RadioStation(
                id: "everything",
                title: "Library",
                subtitle: "Everything, shuffled",
                // A waveform rather than a shuffle arrow: this is the whole
                // library, and the arrow says how it plays, not what it is.
                icon: .symbol("waveform"),
                ramp: [Color(hex: 0x4E7FE1), Color(hex: 0x6D5CE0)],
                action: .play(.everything)
            ),
            RadioStation(
                id: "highlyRated",
                title: "Highly Rated",
                subtitle: "The ones you rated",
                icon: .symbol("star.fill"),
                ramp: [Color(hex: 0xEFA33C), Color(hex: 0xE8783A)],
                action: .play(.highlyRated)
            ),
            RadioStation(
                id: "deepCuts",
                title: "Deep Cuts",
                subtitle: "Barely played",
                icon: .symbol("moon.fill"),
                ramp: [Color(hex: 0x8B5CD6), Color(hex: 0xB04FC9)],
                action: .play(.deepCuts())
            ),
        ]

        if (try? index.hasRadioDecades()) == true {
            stations.append(RadioStation(
                id: "decades",
                title: "Decades",
                subtitle: "Pick your years",
                icon: .symbol("calendar"),
                ramp: [Color(hex: 0x2FA98C), Color(hex: 0x3A8FB8)],
                action: .choose(.decades)
            ))
        }

        if (try? index.hasGenres()) == true {
            stations.append(RadioStation(
                id: "genres",
                title: "Genres",
                subtitle: "Pick your sound",
                icon: .symbol("guitars.fill"),
                ramp: [Color(hex: 0xCB5B6E), Color(hex: 0xD9506F)],
                action: .choose(.genres)
            ))
        }

        // Last, because it is the one station you build rather than pick:
        // everything above answers a question about the library, and this
        // asks you for the answer.
        stations.append(RadioStation(
            id: "mixer",
            title: "Mixer",
            subtitle: "Build your own",
            // Drawn rather than borrowed: no SF Symbol says "two faders" the
            // way the design's own mark does. See `FadersIcon`.
            icon: .faders,
            ramp: [Color(hex: 0x5C63D8), Color(hex: 0x7A55D9)],
            action: .choose(.mixer)
        ))

        // Offline, a station with nothing on the phone behind it is a card
        // that plays silence. The pickers answer for themselves — their lists
        // are filtered when they open.
        guard downloadedOnly else { return stations }
        return stations.filter { station in
            switch station.action {
            case .play(let rule):
                ((try? index.stationSize(rule, downloadedOnly: true)) ?? 0) > 0
            case .choose:
                true
            }
        }
    }
}

/// The shelf: stations as cards, a tap away from playing.
struct RadioShelf: View {
    let stations: [RadioStation]
    /// The screen's own width, measured once above the `LazyVStack` this shelf sits in rather than
    /// re-measured here — see `MeasuredWidth`.
    var knownWidth: CGFloat = 0
    /// A row that scrolls sideways, a grid, or a plain list of stations.
    var layout: AlbumDisplayStyle = .carousel

    @Environment(AppModel.self) private var app

    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 10
    /// Three across the screen, whatever the screen is: a station is a name
    /// and a colour, and at this size you can see the whole shelf at a glance
    /// rather than one and a half of it.
    private static let acrossTheScreen: CGFloat = 3
    /// The design asks for 36pt, with the icon beside the name. With the icon
    /// above it the button needs more, and `RadioTile.height(labelSize:)`
    /// works out how much. This is only a floor under that.
    private static let minimumTileHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Radio")
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            MeasuredWidth(initial: knownWidth) { width in
                let cardWidth = (
                    (width - Self.margin * 2 - Self.gap * (Self.acrossTheScreen - 1))
                        / Self.acrossTheScreen
                ).rounded(.down)
                // Sized against the grid cell even in the list layout, so one
                // station's name is never set larger than another's just
                // because the shelf is arranged differently.
                let labelSize = RadioTile.labelSize(
                    fitting: cardWidth,
                    titles: stations.map(\.title)
                )
                let tileHeight = max(Self.minimumTileHeight, RadioTile.height(labelSize: labelSize))

                switch layout {
                case .carousel:
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: Self.gap) {
                            ForEach(stations) { station in
                                station.view(width: cardWidth) {
                                    RadioTile(
                                        station: $0,
                                        width: cardWidth,
                                        height: tileHeight,
                                        labelSize: labelSize
                                    )
                                } play: {
                                    play($0, named: $1)
                                }
                            }
                        }
                        .padding(.horizontal, Self.margin)
                    }
                    .scrollIndicators(.hidden)
                case .grid:
                    // Three across, which with six stations comes to two tidy rows and no gap on
                    // the end.
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(cardWidth), spacing: Self.gap),
                            count: Int(Self.acrossTheScreen)
                        ),
                        alignment: .leading,
                        spacing: Self.gap
                    ) {
                        ForEach(stations) { station in
                            station.view(width: cardWidth) {
                                RadioTile(
                                    station: $0,
                                    width: cardWidth,
                                    height: tileHeight,
                                    labelSize: labelSize
                                )
                            } play: {
                                play($0, named: $1)
                            }
                        }
                    }
                    .padding(.horizontal, Self.margin)
                case .list:
                    // Not capped at five the way an album shelf's list is.
                    VStack(spacing: Self.gap) {
                        ForEach(stations) { station in
                            station.view(width: width) {
                                RadioTile(
                                    station: $0,
                                    width: nil,
                                    height: tileHeight,
                                    labelSize: labelSize
                                )
                            } play: {
                                play($0, named: $1)
                            }
                        }
                    }
                    .padding(.horizontal, Self.margin)
                }
            }
        }
    }

    private func play(_ rule: LibraryIndex.Station, named title: String) {
        RadioStations.play(rule, named: title, app: app)
    }
}

extension RadioStations {
    /// Builds a station's queue and starts it.
    @MainActor
    static func play(
        _ rule: LibraryIndex.Station, named title: String, app: AppModel,
        on player: (any PlaybackControlling)? = nil
    ) {
        guard let index = app.libraryIndex else { return }
        let tracks = (try? index.stationTracks(
            rule,
            limit: queueLength,
            downloadedOnly: app.isOffline
        )) ?? []
        guard !tracks.isEmpty else {
            app.showTransientError("Nothing to play on \(title) yet.")
            return
        }
        // The station chose its songs with `ORDER BY RANDOM()`, which is a true shuffle and so
        // perfectly happy to open with five songs by one artist.
        let spaced = SmartShuffle.space(tracks, settings: app.settings.smartShuffle)
        (player ?? app.activePlayer).play(spaced, startingAt: 0, from: .radio(named: title))
    }
}

/// Choosing which decades, or which genres, a radio draws on.
struct RadioPickerView: View {
    let picker: RadioPicker

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var decades: [Int] = []
    @State private var genres: [Genre] = []
    @State private var chosenDecades: Set<Int> = []
    @State private var chosenGenres: Set<String> = []

    var body: some View {
        // The mixer is a screen, not a list of things to tick, so it takes
        // over entirely rather than trying to share this one's chrome.
        if picker.kind == .mixer {
            ArtistAlbumMixerView()
        } else {
            pickerList
        }
    }

    private var pickerList: some View {
        List {
            switch picker.kind {
            case .mixer:
                // Unreachable — handled above, before this list is built.
                EmptyView()
            case .decades:
                ForEach(decades, id: \.self) { decade in
                    row(title: "\(decade)s", isOn: chosenDecades.contains(decade)) {
                        toggle(decade)
                    }
                }
            case .genres:
                ForEach(genres) { genre in
                    row(
                        title: genre.name,
                        detail: genre.trackCount.map { $0.counted("song") },
                        isOn: chosenGenres.contains(genre.name)
                    ) {
                        toggle(genre.name)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(picker.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Play", systemImage: "play.fill") { play() }
                    .disabled(isEmpty)
            }
        }
        .task { load() }
    }

    private var isEmpty: Bool {
        picker.kind == .decades ? chosenDecades.isEmpty : chosenGenres.isEmpty
    }

    private func row(
        title: String,
        detail: String? = nil,
        isOn: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .listRowInsets(CompactList.rowInsets)
    }

    private func toggle(_ decade: Int) {
        if chosenDecades.contains(decade) {
            chosenDecades.remove(decade)
        } else {
            chosenDecades.insert(decade)
        }
        app.settings.radioDecades = chosenDecades.sorted()
    }

    private func toggle(_ genre: String) {
        if chosenGenres.contains(genre) {
            chosenGenres.remove(genre)
        } else {
            chosenGenres.insert(genre)
        }
        app.settings.radioGenres = chosenGenres.sorted()
    }

    private func load() {
        guard let index = app.libraryIndex else { return }
        switch picker.kind {
        case .mixer:
            break
        case .decades:
            decades = (try? index.radioDecades()) ?? []
            chosenDecades = Set(app.settings.radioDecades).intersection(decades)
        case .genres:
            genres = ((try? index.genres()) ?? [])
                .sorted { ($0.trackCount ?? 0) > ($1.trackCount ?? 0) }
            chosenGenres = Set(app.settings.radioGenres)
                .intersection(Set(genres.map(\.name)))
        }
    }

    private func play() {
        switch picker.kind {
        case .mixer:
            return
        case .decades:
            RadioStations.play(
                .decades(chosenDecades.sorted()),
                named: "Decades",
                app: app
            )
        case .genres:
            RadioStations.play(
                .genres(chosenGenres.sorted()),
                named: "Genres",
                app: app
            )
        }
        dismiss()
    }
}
