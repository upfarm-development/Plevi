import SwiftUI
import PleviDomain

/// The artist page: a stack of sections whose order and visibility come from
/// Settings. Sections with nothing to show are skipped, so a sparse library
/// doesn't produce a page of empty headings.
struct ArtistDetailView: View {
    let artist: Artist
    /// Show only the records that are actually on the phone.
    let downloadedOnly: Bool

    init(artist: Artist, downloadedOnly: Bool = false) {
        self.artist = artist
        self.downloadedOnly = downloadedOnly
        // Seeds an already-known colour so the page opens tinted instead of
        // flashing neutral first.
        _palette = State(initialValue: PaletteLoader(artwork: artist.artwork))
    }

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    /// The size this page is laying out in — see `PageMetrics`.
    @State private var pageSize: CGSize = .zero
    @State private var detail: ArtistDetail?
    @State private var info: ArtistInfo?
    /// Whether the biography has been settled one way or the other: read from
    /// the stored page, or asked of the server and answered. Until it has, the
    /// About section holds the room a long biography will take.
    @State private var infoResolved = false
    @State private var releaseGroups: [ReleaseType: [Album]] = [:]
    @State private var appearsOn: [Album] = []
    @State private var topTracks: [Track] = []
    @State private var favouriteTracks: [Track] = []
    /// Which half of the Popular / My Favourites card is showing.
    @State private var pagerPage: Int? = 0
    @State private var loadError: String?
    @State private var cacheWasFresh = false
    @State private var palette: PaletteLoader
    /// Filled in when this page was opened with an incomplete artist — an
    /// album only knows its artist's name and ID, not their artwork.
    @State private var resolvedArtist: Artist?
    /// How far this page has been pulled past its own top — see
    /// `trackingHeaderPull`.
    @State private var headerPull: CGFloat = 0
    /// See `dominantGenre` — worked out once when `detail` is set rather than
    /// every time the header reads it, which during a pull-past-top scroll is
    /// every frame.
    @State private var dominantGenreCache: String?

    /// The artist to display: the complete record once known.
    private var displayArtist: Artist {
        resolvedArtist ?? artist
    }

    private var actions: MediaActions { MediaActions(app: app) }

    /// How many sleeves are warmed at once, and in all.
    private var sleeveWarmKey: String {
        let layouts = app.settings.artistSectionOrder
            .map { "\($0.rawValue)\(app.settings.layout($0).isOn ? app.settings.layout($0).displayStyle.rawValue : "-")" }
            .joined(separator: ",")
        return "\(detail?.albums.count ?? 0)|\(appearsOn.count)|\(info?.similarArtists.count ?? 0)|\(topTracks.count)|\(favouriteTracks.count)|\(Int(pageSize.width))|\(app.settings.albumColumns)|\(layouts)"
    }

    private static let sleevesAtOnce = 4
    private static let sleevesWarmed = 120

    /// Every sleeve the page draws, with the size it is drawn at, in the order the page shows them:
    /// its sections as the settings order them, and each section as it lists its own.
    private func sleevesInPageOrder() -> [(artwork: ArtworkID, points: CGFloat)] {
        let gridWidth = AlbumGridMetrics(
            availableWidth: pageSize.width - 32,
            columns: app.settings.albumColumns,
            spacing: Self.gridSpacing
        ).itemWidth
        func albumSize(_ style: AlbumDisplayStyle) -> CGFloat {
            switch style {
            case .grid: gridWidth
            case .carousel: 140
            case .list: 52
            }
        }
        func artistSize(_ style: AlbumDisplayStyle) -> CGFloat {
            style == .list ? 44 : 96
        }
        var out: [(ArtworkID, CGFloat)] = []
        func add(_ albums: [Album], _ style: AlbumDisplayStyle) {
            let size = albumSize(style)
            for album in albums { if let art = album.artwork { out.append((art, size)) } }
        }
        for section in app.settings.artistSectionOrder {
            let layout = app.settings.layout(section)
            guard layout.isOn else { continue }
            let style = layout.displayStyle
            switch section {
            case .singles where app.settings.combinesSinglesAndEPs:
                add(((releaseGroups[.single] ?? []) + (releaseGroups[.ep] ?? []))
                    .sorted { ($0.year ?? 0, $0.name) > ($1.year ?? 0, $1.name) }, style)
            case .eps where app.settings.combinesSinglesAndEPs:
                break
            case .albums:
                add(albumsWithoutTheirOwnSection, style)
            case .appearsOn:
                add(Array(appearsOn.prefix(Self.shelfAlbums)), style)
            case .similarArtists:
                let shown = (info?.similarArtists ?? []).prefix(Self.similarArtistsShown(style))
                for other in shown { if let art = other.artwork { out.append((art, artistSize(style))) } }
            case .topTracks where style == .carousel:
                for track in topTracks.prefix(Self.shelfLength) {
                    if let art = track.artwork { out.append((art, 120)) }
                }
            case .favouriteTracks where style == .carousel:
                for track in favouriteTracks.prefix(Self.shelfLength) {
                    if let art = track.artwork { out.append((art, 120)) }
                }
            default:
                if let type = section.releaseType { add(releaseGroups[type] ?? [], style) }
            }
        }
        // Anything the sections did not place, last, at the grid's size.
        add(detail?.albums ?? [], .grid)
        return out
    }

    /// Pulls the page's album sleeves into the cache at the size the grid draws them.
    private func warmSleeves() async {
        guard !app.isOffline, !downloadedOnly, pageSize.width > 0,
              let loader = app.artwork, detail?.albums.isEmpty == false
        else { return }
        var seen: Set<String> = []
        let missing = sleevesInPageOrder().compactMap { sleeve -> (ArtworkID, Int)? in
            let bucket = ArtworkLoader.bucket(forPointSize: sleeve.points, scale: displayScale)
            guard seen.insert("\(sleeve.artwork.rawValue)|\(bucket)").inserted,
                  !loader.hasImage(for: sleeve.artwork, bucket: bucket)
            else { return nil }
            return (sleeve.artwork, bucket)
        }
        guard !missing.isEmpty else { return }

        try? await Task.sleep(for: .milliseconds(250))
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (sleeve, bucket) in missing.prefix(Self.sleevesWarmed) {
                if Task.isCancelled { break }
                if running >= Self.sleevesAtOnce {
                    await group.next()
                    running -= 1
                }
                group.addTask { _ = await loader.image(for: sleeve, bucket: bucket) }
                running += 1
            }
        }
    }

    private var style: PageStyle {
        app.settings.pageStyle
    }

    private var metrics: PageMetrics {
        PageMetrics(
            size: pageSize,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    /// Enough words to fill the collapsed block at any width a phone or an
    /// iPad gives it.
    private static let biographyPlaceholder = String(
        repeating: "Biography placeholder text that fills the block. ", count: 12
    )

    /// Whether a biography is still expected: the server can provide one, the
    /// page is not offline or limited to what is downloaded, and it has not
    /// been settled yet.
    private var awaitingBiography: Bool {
        !infoResolved && !app.isOffline && !downloadedOnly
            && app.provider?.capabilities.contains(.artistInfo) == true
    }

    /// Where the page scrolls back to when a long biography folds up.
    private static let aboutAnchor = "artist-about"

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if metrics.standsSideBySide {
                        wideHeader
                    } else {
                        header
                    }
                    ForEach(app.settings.artistSectionOrder) { section in
                        let layout = app.settings.layout(section)
                        if layout.isOn {
                            sectionView(section, layout: layout.displayStyle, scrollProxy: scrollProxy)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            // See AlbumDetailView: the artwork must run under the navigation bar, which would
            // otherwise slice across it.
            .ignoresSafeArea(edges: metrics.standsSideBySide ? [] : .top)
            // Glass under the clock, arriving as the photograph leaves — see `TopBlur`.
            .withoutScrollEdgeBlur(topToo: !metrics.standsSideBySide)
            .topBlurAsArtworkLeaves(!metrics.standsSideBySide)
            // Off where the picture is a fixed card: there is nothing to stretch, and this writes
            // state on every frame of a scroll.
            .trackingHeaderPull($headerPull, active: !metrics.standsSideBySide)
            // `containerSize` rather than `contentOffset`: it changes on a rotation or a window
            // resize only, so this writes a handful of times in a session where the pull tracker
            // writes sixty times a second.
            .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in
                if size != pageSize { pageSize = size }
            }
        }
        .background {
            PageBackground(style: style, artwork: palette.palette)
        }
        // The status bar, back button and tab-bar glass are system
        // chrome we do not draw: without this they stay in the system
        // appearance and render light over a dark page.
        .toolbarColorScheme(activePalette.chromeScheme, for: .navigationBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // Draws over the header without taking its touches — see the same
        // overlay on `AlbumDetailView` for what that costs when it does.
        .overlay {
            Group {
                if detail == nil && loadError == nil {
                    ProgressView()
                } else if let loadError, detail == nil {
                    ContentUnavailableView {
                        Label("Can't load artist", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .task(id: app.libraryVersion) { await load() }
        // Every sleeve on the page, fetched in the background once the page has
        // painted, so scrolling down finds them already there.
        .task(id: sleeveWarmKey, priority: .utility) {
            await warmSleeves()
        }
    }

    // MARK: Header

    private var header: some View {
        ImmersiveHeader(
            artwork: displayArtist.artwork,
            palette: activePalette,
            artworkShape: .circle,
            fade: .artist,
            // The details below are part of the same block as the name — the
            // record page's arrangement, and now this one's.
            titleBottom: 8,
            // Under the photograph, the same as a record's sleeve — see
            // `HeaderFade.artist`, which is light enough that the picture is
            // still a picture where the name meets it.
            titleDrop: 0,
            dissolvesIntoBackground: style.usesBlurredBackground,
            placeholder: .artist,
            pulledPast: headerPull
        ) {
            titleBlock
        } content: {
            detailsAndControls
        }
    }

    /// The artist as a photograph standing on the page.
    private var wideHeader: some View {
        SideBySideHeader(
            artwork: displayArtist.artwork,
            palette: activePalette,
            placeholder: .artist,
            // The stack this sits in already puts `headerBottomGap` between
            // every section, so the header supplying its own would make the
            // step twice what the other two pages show.
            bottomGap: 0
        ) {
            wideIdentity
        } about: { room in
            wideBiography(room: room)
        }
    }

    private var wideIdentity: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Never truncated to one line: this is the page's subject, and a name like "Antonio
            // Carlos Jobim & Vinicius de Moraes" loses the half that says whose page you are on.
            Text(displayArtist.name)
                .font(.system(size: 40, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(activePalette.foreground)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let genre = dominantGenre {
                Text(genre)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(activePalette.foreground)
                    .lineLimit(1)
                    .padding(.top, 6)
            }

            if let albums = albumCountText {
                Text(albums)
                    .font(.system(size: 17))
                    .foregroundStyle(activePalette.secondaryForeground)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            HeaderActionRow(
                layout: .labelled,
                onPlay: { actions.playArtist(artist) },
                onShuffle: { actions.playArtist(artist, shuffled: true) },
                alternativeShuffle: .offering(
                    smart: !app.settings.smartShuffleByDefault
                ) {
                    actions.playArtist(artist, shuffled: true, smart: !app.settings.smartShuffleByDefault)
                },
                palette: activePalette,
                isDisabled: detail?.albums.isEmpty ?? true,
                bottomGap: 0,
                horizontalInset: 0,
                fixedWidth: metrics.actionRowWidth
            ) {
                artistMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The biography, cut to the room left before the foot of the photograph — and only where the
    /// section is switched on.
    @ViewBuilder
    private func wideBiography(room: CGFloat) -> some View {
        if app.settings.isEnabled(.about),
           let biography = info?.biography, !biography.isEmpty {
            InlineExpandableText(
                text: biography,
                width: metrics.textColumnWidth,
                availableHeight: room,
                palette: activePalette,
                sheetTitle: ArtistSection.about.title,
                moreColor: activePalette.foreground
            )
            .padding(.top, PageMetrics.aboutTopGap)
        }
    }

    /// The name alone, written into the foot of the picture. What kind of
    /// music and how much of it stands below, beside the controls.
    private var titleBlock: some View {
        // Never truncated to one line: this is the page's subject, and a
        // name like "Antonio Carlos Jobim & Vinicius de Moraes" loses the
        // half that says whose page you are on.
        Text(displayArtist.name)
            .font(.system(size: 34, weight: .bold))
            .tracking(-0.68)
            .foregroundStyle(activePalette.foreground)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 1)
    }

    /// What kind of music and how much of it, with the controls at the end of the same two lines —
    /// the record page's arrangement.
    private var detailsAndControls: some View {
        // No spacing of its own: the gap to the controls is the spacer's `minLength` and nothing
        // else.
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if let genre = dominantGenre {
                    Text(genre)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(activePalette.foreground)
                        .lineLimit(1)
                }
                if let albums = albumCountText {
                    Text(albums)
                        .font(.system(size: 14.5))
                        .foregroundStyle(activePalette.secondaryForeground)
                        .lineLimit(1)
                }
            }
            // Comfortably clear of a forty-four point square without
            // taking a word off the line beside it.
            Spacer(minLength: 16)
            // Aligned from the right, and never squeezed by a long genre —
            // that truncates instead.
            playButtons
                .layoutPriority(1)
        }
        .padding(.horizontal, HeaderFade.titleInset)
        // Less than a record's: About brings its own heading space, and a
        // full step here made two.
        .padding(.bottom, 10)
    }

    /// How much of it there is.
    private var albumCountText: String? {
        let albumCount = detail?.albums.count ?? displayArtist.albumCount ?? 0
        return albumCount > 0 ? albumCount.counted("album") : nil
    }

    /// The genre most of their records are filed under.
    private var dominantGenre: String? { dominantGenreCache }

    /// `dominantGenre`'s actual work, run once whenever `detail` is set
    /// rather than on every read of the computed property above.
    private static func dominantGenre(among albums: [Album]) -> String? {
        let genres = albums.compactMap(\.genre).filter { !$0.isEmpty }
        guard !genres.isEmpty else { return nil }
        let counts = Dictionary(genres.map { ($0, 1) }, uniquingKeysWith: +)
        // Ties broken by name, so the same artist reads the same way twice.
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    private var playButtons: some View {
        HeaderActionRow(
            layout: .compact,
            onPlay: { actions.playArtist(artist) },
            onShuffle: { actions.playArtist(artist, shuffled: true) },
            alternativeShuffle: .offering(
                smart: !app.settings.smartShuffleByDefault
            ) {
                actions.playArtist(artist, shuffled: true, smart: !app.settings.smartShuffleByDefault)
            },
            palette: activePalette,
            isDisabled: detail?.albums.isEmpty ?? true
        ) {
            artistMenu
        }
    }

    /// The same menu as a long press on this artist anywhere else — see `ArtistMenuContent`.
    private var artistMenu: some View {
        Menu {
            // See the album page's menu: the tint below dresses this button's
            // circle, and without this it would dress the menu's icons too.
            ArtistMenuContent(artist: displayArtist, actions: actions)
                .tint(Color.primary)
        } label: {
            Image(systemName: "ellipsis")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(
        _ section: ArtistSection,
        layout: AlbumDisplayStyle,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        switch section {
        case .about:
            // Drawn in the header where the artwork stands beside the words — see `wideBiography`.
            if !metrics.standsSideBySide,
               let biography = info?.biography, !biography.isEmpty {
                SectionContainer(title: section.title, palette: activePalette) {
                    ExpandableText(
                        text: biography,
                        palette: activePalette,
                        scrollAnchor: Self.aboutAnchor,
                        scrollProxy: scrollProxy
                    )
                    .padding(.horizontal)
                }
                .id(Self.aboutAnchor)
            } else if !metrics.standsSideBySide, awaitingBiography {
                // Holds the room the biography will take.
                SectionContainer(title: section.title, palette: activePalette) {
                    ExpandableText(text: Self.biographyPlaceholder, palette: activePalette)
                        .redacted(reason: .placeholder)
                        .allowsHitTesting(false)
                        .padding(.horizontal)
                }
                .accessibilityHidden(true)
            }
        case .topTracks, .favouriteTracks:
            // The two song shelves share one card when both are on: swipe
            // sideways to go from what you play to what you rated.
            if pairsTrackSections {
                if section == firstTrackSection { trackPager }
            } else if section == .topTracks {
                popularSection
            } else {
                favouritesSection
            }
        case .appearsOn, .similarArtists:
            if pairsClosingSections {
                // Drawn at whichever of the two the reader put first, exactly as the two song
                // shelves share a card at the first of *them*.
                if section == firstClosingSection {
                    // No spacing of its own.
                    HStack(alignment: .top, spacing: 0) {
                        // Each half looks up its own layout.
                        appearsOnSection(layout: app.settings.layout(.appearsOn).displayStyle)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        similarArtistsSection(layout: app.settings.layout(.similarArtists).displayStyle)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else if section == .appearsOn {
                appearsOnSection(layout: layout)
            } else {
                similarArtistsSection(layout: layout)
            }
        case .singles where app.settings.combinesSinglesAndEPs:
            albumSection(
                "Singles & EPs",
                albums: ((releaseGroups[.single] ?? []) + (releaseGroups[.ep] ?? []))
                    .sorted { ($0.year ?? 0, $0.name) > ($1.year ?? 0, $1.name) },
                layout: layout
            )
        case .eps where app.settings.combinesSinglesAndEPs:
            // Shown with the singles above; a second heading would be empty.
            EmptyView()
        case .albums:
            albumSection(section.title, albums: albumsWithoutTheirOwnSection, layout: layout)
        default:
            if let type = section.releaseType {
                albumSection(section.title, albums: releaseGroups[type] ?? [], layout: layout)
            }
        }
    }

    /// Records this artist is a guest on. Its own function rather than an
    /// arm of the switch, so the wide layout can stand it beside the
    /// neighbours without either of them being written twice.
    @ViewBuilder
    private func appearsOnSection(layout: AlbumDisplayStyle) -> some View {
        // A prolific guest can appear on dozens of other people's
        // records, which is a page of its own rather than the tail of
        // this one.
        albumSection(
            ArtistSection.appearsOn.title,
            albums: Array(appearsOn.prefix(Self.shelfAlbums)),
            layout: layout,
            showsArtist: true,
            more: appearsOn.count > Self.shelfAlbums
                ? AlbumCollection(
                    title: ArtistSection.appearsOn.title,
                    albums: appearsOn,
                    // The page behind the heading looks like the shelf in
                    // front of it, whichever way that shelf is set.
                    layout: layout == .list ? .list : .grid,
                    artwork: displayArtist.artwork
                )
                : nil
        )
    }

    @ViewBuilder
    private func similarArtistsSection(layout: AlbumDisplayStyle) -> some View {
        if let similar = info?.similarArtists, !similar.isEmpty {
            let shown = Array(similar.prefix(Self.similarArtistsShown(layout)))
            SectionContainer(
                title: ArtistSection.similarArtists.title,
                palette: activePalette,
                moreSimilar: shown.count < similar.count
                    ? SimilarArtistsRoute(artist: displayArtist, similar: similar)
                    : nil
            ) {
                artistCollection(shown, layout: layout)
            }
        }
    }

    /// Both closing shelves are on and both have something to show, so they stand side by side
    /// rather than one above the other — the same rule, and for the same reason, as the two song
    /// shelves sharing a card on a phone.
    private var pairsClosingSections: Bool {
        metrics.pairsClosingSections
            && app.settings.isEnabled(.appearsOn)
            && app.settings.isEnabled(.similarArtists)
            && !appearsOn.isEmpty
            && !(info?.similarArtists ?? []).isEmpty
    }

    /// Whichever of the two the reader put first; the pair takes that place.
    private var firstClosingSection: ArtistSection? {
        app.settings.artistSectionOrder.first { $0 == .appearsOn || $0 == .similarArtists }
    }

    /// Three across a phone with the gaps closed up: the artwork is what the row is for, the space
    /// between is not.
    private static func similarArtistsShown(_ layout: AlbumDisplayStyle) -> Int {
        switch layout {
        case .grid: 6
        case .list: 5
        case .carousel: .max
        }
    }

    private static let shelfLength = 10

    /// And how many records.
    static let shelfAlbums = 5

    private static let gridArtworkSize: CGFloat = 118
    private static let gridSpacing: CGFloat = 8

    /// How wide a song row wants to be where these sections lay out in a grid.
    private static let trackColumnWidth: CGFloat = 160

    /// Both song shelves are on and both have something to show, so they are
    /// drawn as one swipeable card rather than two stacked sections.
    private var pairsTrackSections: Bool {
        app.settings.isEnabled(.topTracks) && app.settings.isEnabled(.favouriteTracks)
            && !topTracks.isEmpty && !favouriteTracks.isEmpty
    }

    /// Whichever of the two the user put first; the card takes that place in
    /// the page's order.
    private var firstTrackSection: ArtistSection? {
        app.settings.artistSectionOrder.first { $0 == .topTracks || $0 == .favouriteTracks }
    }

    private var trackPager: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    popularSection
                        .containerRelativeFrame(.horizontal)
                        .id(0)

                    favouritesSection
                        .containerRelativeFrame(.horizontal)
                        .id(1)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $pagerPage)

            // Two dots, because a card that can be swiped and does not say so
            // is a card nobody swipes.
            HStack(spacing: 7) {
                ForEach(0..<2, id: \.self) { page in
                    Circle()
                        .fill(activePalette.foreground.opacity((pagerPage ?? 0) == page ? 0.85 : 0.28))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var popularSection: some View {
        if !topTracks.isEmpty {
            shelf(
                title: ArtistSection.topTracks.title,
                kind: .popular,
                tracks: topTracks,
                songColumns: metrics.songColumns
            )
        }
    }

    @ViewBuilder
    private var favouritesSection: some View {
        if !favouriteTracks.isEmpty {
            shelf(
                title: ArtistSection.favouriteTracks.title,
                kind: .rated,
                tracks: favouriteTracks,
                songColumns: metrics.songColumns
            )
        }
    }

    /// A shelf of songs whose heading opens the long list — ten here, the rest a tap away.
    private func shelf(
        title: String,
        kind: ArtistTracksView.Kind,
        tracks: [Track],
        songColumns: Int? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                ArtistTracksView(artist: displayArtist, kind: kind)
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(activePalette.secondaryForeground)
                }
                .foregroundStyle(activePalette.foreground)
                .padding(.horizontal)
            }
            .buttonStyle(.plain)

            // Ten, in five rows of two on a phone and in fewer rows wherever there is room for more
            // columns: the shelf is a taste, and the heading above it opens the rest.
            trackList(
                Array(tracks.prefix(Self.shelfLength)),
                layout: .grid,
                queue: tracks,
                songColumns: songColumns
            )
        }
    }

    /// Everything that has no enabled section of its own, plus plain albums.
    private var albumsWithoutTheirOwnSection: [Album] {
        var covered = Set(
            ArtistSection.allCases
                .filter { $0 != .albums && app.settings.isEnabled($0) }
                .compactMap(\.releaseType)
        )
        // Combined, EPs ride along with the singles — so they are covered
        // only while that section is on, and fall back to Albums if it is not.
        if app.settings.combinesSinglesAndEPs {
            if app.settings.isEnabled(.singles) {
                covered.insert(.ep)
            } else {
                covered.remove(.ep)
            }
        }
        return ReleaseType.allCases
            .filter { $0 == .album || !covered.contains($0) }
            .flatMap { releaseGroups[$0] ?? [] }
            .sorted { ($0.year ?? 0, $0.name) > ($1.year ?? 0, $1.name) }
    }

    private var activePalette: ArtworkPalette {
        .forPage(style, artwork: palette.palette)
    }

    @ViewBuilder
    /// - Parameter showsArtist: off by default — on this page every album is the artist's own and
    /// repeating their name says nothing.
    private func albumSection(
        _ title: String,
        albums: [Album],
        layout: AlbumDisplayStyle,
        showsArtist: Bool = false,
        more: AlbumCollection? = nil
    ) -> some View {
        if !albums.isEmpty {
            SectionContainer(title: title, palette: activePalette, more: more) {
                switch layout {
                case .grid:
                    // Wraps, so a long discography is all visible rather than hidden off the side
                    // of a row.
                    MeasuredWidth { width in
                        let metrics = AlbumGridMetrics(
                            availableWidth: width,
                            columns: app.settings.albumColumns,
                            spacing: Self.gridSpacing
                        )
                        LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 16) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCard(
                                        album: album,
                                        size: metrics.itemWidth,
                                        palette: activePalette,
                                        showsArtist: showsArtist,
                                        actions: actions
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal)
                case .carousel:
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCard(
                                        album: album,
                                        size: 140,
                                        palette: activePalette,
                                        showsArtist: showsArtist,
                                        actions: actions
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                case .list:
                    VStack(spacing: 0) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumListRow(album: album, palette: activePalette)
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album, actions: actions)
                        }
                    }
                }
            }
        }
    }

    /// Popular and My Favourites, in as many columns as there is room for.
    @ViewBuilder
    private func trackSection(_ title: String, tracks: [Track], layout: AlbumDisplayStyle) -> some View {
        if !tracks.isEmpty {
            SectionContainer(title: title, palette: activePalette) {
                trackList(tracks, layout: layout)
            }
        }
    }

    /// - Parameter queue: What tapping a row actually starts playing — defaults to `tracks` itself,
    /// but the shelf passes the section's full fetch here while `tracks` stays the ten it shows.
    @ViewBuilder
    private func trackList(
        _ tracks: [Track],
        layout: AlbumDisplayStyle,
        queue: [Track]? = nil,
        songColumns: Int? = nil
    ) -> some View {
        let queue = queue ?? tracks
        Group {
                switch layout {
                case .grid:
                    // As many columns as the width has room for: the two a phone has always shown,
                    // more on an iPad, one where the window is narrower than any phone.
                    EvenColumnsLayout(
                        columns: songColumns,
                        minimum: Self.trackColumnWidth,
                        spacing: songColumns == nil ? 10 : PageMetrics.songColumnSpacing,
                        rowSpacing: 2
                    ) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, position: index + 1, in: queue, at: index)
                        }
                    }
                    .padding(.horizontal)
                case .list:
                    VStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, position: index + 1, in: queue, at: index)
                        }
                    }
                    .padding(.horizontal)
                case .carousel:
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                VStack(alignment: .leading, spacing: 6) {
                                    ArtworkView(artwork: track.artwork, size: 120)
                                    Text(track.title)
                                        .font(.caption)
                                        .foregroundStyle(activePalette.foreground)
                                        .lineLimit(2)
                                }
                                .frame(width: 120, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { app.activePlayer.play(queue, startingAt: index, from: .artist) }
                                .trackContextMenu(track, actions: actions)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
        }
    }

    private func trackRow(_ track: Track, position: Int, in tracks: [Track], at index: Int) -> some View {
        CompactTrackRow(
            position: position,
            track: track,
            isCurrent: app.activePlayer.currentTrack?.id == track.id,
            palette: activePalette,
            // Stars belong in the full list, where there is room to aim at
            // them. On a two-column shelf they crowd the title.
            showsRating: false
        )
        // On the row, as on the album page. Behind it, only the touches that
        // missed every piece of text ever arrived.
        .contentShape(Rectangle())
        .onTapGesture { app.activePlayer.play(tracks, startingAt: index, from: .artist) }
        .trackContextMenu(track, actions: actions)
    }

    /// Similar artists, in whichever shape the section is set to.
    @ViewBuilder
    private func artistCollection(_ artists: [Artist], layout: AlbumDisplayStyle) -> some View {
        switch layout {
        case .grid:
            EvenColumnsLayout(columns: nil, minimum: 96, spacing: 12, rowSpacing: 16) {
                ForEach(artists) { other in
                    artistCard(other, size: 96)
                }
            }
            .padding(.horizontal)
        case .carousel:
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(artists) { other in
                        artistCard(other, size: 96)
                    }
                }
                .padding(.horizontal)
            }
        case .list:
            VStack(spacing: 0) {
                ForEach(artists) { other in
                    NavigationLink(value: other) {
                        HStack(spacing: 12) {
                            ArtworkView(
                                artwork: other.artwork,
                                size: 44,
                                cornerRadius: 22,
                                placeholder: .artist
                            )
                            Text(other.name)
                                .font(.subheadline)
                                .foregroundStyle(activePalette.foreground)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .artistContextMenu(other, actions: actions)
                }
            }
            .padding(.horizontal)
        }
    }

    private func artistCard(_ other: Artist, size: CGFloat) -> some View {
        NavigationLink(value: other) {
            VStack(spacing: 6) {
                ArtworkView(
                    artwork: other.artwork,
                    size: size,
                    cornerRadius: size / 2,
                    placeholder: .artist
                )
                Text(other.name)
                    .font(.caption)
                    .foregroundStyle(activePalette.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .artistContextMenu(other, actions: actions)
    }

    // MARK: Loading

    private func load() async {
        // Arriving from an album gives only a name and ID, because that is
        // all an album record holds — complete it before anything reads the
        // artwork.
        if artist.artwork == nil, resolvedArtist == nil {
            if let full = try? app.index(for: artist.id.server)?.artist(id: artist.id), full.artwork != nil {
                resolvedArtist = full
            } else if !downloadedOnly, !app.isOffline,
                      let provider = app.provider,
                      let fetched = try? await provider.artist(id: artist.id) {
                // Not from Downloads, and not offline: this is a request to the server sitting in
                // front of everything the phone already knows, and with no answer coming it held
                // the whole page blank until the request gave up — over records that are on the…
                resolvedArtist = fetched.artist
            }
        }

        // Everything local first, in one pass, so the page paints complete
        // rather than revealing sections as each request lands.
        if let index = app.index(for: artist.id.server) {
            var albums = (try? index.albums(forArtist: artist.id, downloadedOnly: app.isOffline || downloadedOnly)) ?? []
            // An artist of another library whose songs were downloaded from this one's search: they
            // are in this library's downloads, which the other library's own table knows nothing
            // of, so "downloaded" is judged by the songs themselves.
            if albums.isEmpty, app.isOffline || downloadedOnly,
               artist.id.server != app.libraryIndex?.server {
                albums = ((try? index.albums(forArtist: artist.id)) ?? []).filter { album in
                    ((try? index.tracks(inAlbum: album.id)) ?? [])
                        .contains { app.downloads?.isDownloaded($0.id) == true }
                }
            }
            if !albums.isEmpty {
                detail = ArtistDetail(artist: artist, albums: albums)
                dominantGenreCache = Self.dominantGenre(among: albums)
                // The grid is drawn from these, not from `albums`, so narrowing only the latter
                // left the page saying "3 albums" over a wall of every record the artist has — each
                // of which then opened onto nothing, because the record screen narrows itself too.
                let kept = Set(albums.map(\.id))
                releaseGroups = Dictionary(
                    uniqueKeysWithValues: ((try? index.releaseGroups(forArtist: artist.id)) ?? [])
                        .map { group in
                            (
                                group.type,
                                downloadedOnly
                                    ? group.albums.filter { kept.contains($0.id) }
                                    : group.albums
                            )
                        }
                        .filter { !$0.1.isEmpty }
                )
                appearsOn = (try? index.appearsOn(
                    artistID: artist.id,
                    artistName: displayArtist.name,
                    downloadedOnly: app.isOffline || downloadedOnly
                )) ?? []
                favouriteTracks = (try? index.favoriteTracks(forArtist: artist.id, limit: 10)) ?? []
                // The shelf itself still only shows ten — see `shelf` — but fetching the same
                // thirty its "Popular" heading opens is what lets tapping one of the ten queue the
                // chart the way it reads, not just the taste of it visible here.
                topTracks = (try? index.topTracks(
                    forArtist: artist.id, limit: ArtistTracksView.Kind.popular.limit
                )) ?? []
            }

            if let cached = try? index.cachedArtistPage(for: artist.id) {
                infoResolved = true
                if info == nil {
                    info = ArtistInfo(
                        biography: cached.biography,
                        similarArtists: cached.similarArtists
                    )
                }
                if !cached.topTracks.isEmpty {
                    topTracks = cached.topTracks
                }
                cacheWasFresh = !cached.isStale()
            }
        }

        do {
            await palette.load(artwork: displayArtist.artwork, using: app.artwork)
        }

        guard let provider = app.provider else { return }
        if detail == nil {
            do {
                let fetched = try await provider.artist(id: artist.id)
                detail = fetched
                dominantGenreCache = Self.dominantGenre(among: fetched.albums)
                releaseGroups = Dictionary(grouping: fetched.albums, by: \.primaryReleaseType)
            } catch {
                loadError = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            }
        }

        // With a fresh cache there is nothing to wait for; otherwise fetch
        // and store so the next visit is instant.
        guard !cacheWasFresh else { return }
        await app.artistPrefetcher.warm(artist)
        if let index = app.libraryIndex,
           let refreshed = try? index.cachedArtistPage(for: artist.id) {
            withAnimation(.easeInOut(duration: 0.2)) {
                infoResolved = true
                info = ArtistInfo(
                    biography: refreshed.biography,
                    similarArtists: refreshed.similarArtists
                )
                if !refreshed.topTracks.isEmpty {
                    topTracks = refreshed.topTracks
                }
            }
        }
        // However the request went: a failed one is an answer too, and the
        // room held for a biography that is not coming must be given back.
        if !infoResolved {
            withAnimation(.easeInOut(duration: 0.2)) { infoResolved = true }
        }
    }
}

/// A titled section with consistent spacing, tinted for the immersive style.
struct SectionContainer<Content: View>: View {
    let title: String
    var palette: ArtworkPalette = .neutral
    /// When there is more than the shelf shows, the heading becomes the way
    /// to the rest of it — a chevron on the title rather than a "See All"
    /// button competing with it.
    var more: AlbumCollection?
    /// The same chevron, for the similar artists an artist page works out for itself.
    var moreSimilar: SimilarArtistsRoute?
    @ViewBuilder var content: Content

    init(
        title: String,
        palette: ArtworkPalette = .neutral,
        more: AlbumCollection? = nil,
        moreSimilar: SimilarArtistsRoute? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.palette = palette
        self.more = more
        self.moreSimilar = moreSimilar
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let more {
                NavigationLink(value: more) {
                    heading(showsChevron: true)
                }
                .buttonStyle(.plain)
            } else if let moreSimilar {
                NavigationLink(value: moreSimilar) {
                    heading(showsChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                heading(showsChevron: false)
            }
            content
        }
    }

    private func heading(showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.title3.weight(.semibold))
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.secondaryForeground)
            }
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal)
        .contentShape(Rectangle())
    }
}

/// Every similar artist, down a list, which is the shape that reads best when the question is "who
/// else" rather than "which of these".
struct SimilarArtistsRoute: Hashable {
    let artist: Artist
    let similar: [Artist]
}

struct SimilarArtistsListView: View {
    let route: SimilarArtistsRoute

    @Environment(AppModel.self) private var app
    @State private var palette: PaletteLoader

    init(route: SimilarArtistsRoute) {
        self.route = route
        _palette = State(initialValue: PaletteLoader(artwork: route.artist.artwork))
    }

    private var style: PageStyle { app.settings.pageStyle }
    private var activePalette: ArtworkPalette { .forPage(style, artwork: palette.palette) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(route.similar) { other in
                    NavigationLink(value: other) {
                        HStack(spacing: 12) {
                            ArtworkView(
                                artwork: other.artwork,
                                size: 44,
                                cornerRadius: 22,
                                placeholder: .artist
                            )
                            Text(other.name)
                                .font(.subheadline)
                                .foregroundStyle(activePalette.foreground)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .artistContextMenu(other, actions: MediaActions(app: app))
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background { PageBackground(style: style, artwork: palette.palette) }
        .toolbarColorScheme(activePalette.chromeScheme, for: .navigationBar)
        .navigationTitle(ArtistSection.similarArtists.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await palette.load(artwork: route.artist.artwork, using: app.artwork) }
    }
}

/// Body text that clamps to a few lines with a "more" control — biographies and album reviews are
/// often several paragraphs.
struct ExpandableText: View {
    let text: String
    var palette: ArtworkPalette = .neutral
    var collapsedLineLimit = 4
    /// What to scroll back to when a long one folds up, and the proxy to do
    /// it with. Both are needed, or a collapse leaves the page exactly where
    /// it was — which is right for a short one and stranding for a long one.
    var scrollAnchor: AnyHashable?
    var scrollProxy: ScrollViewProxy?

    @State private var expanded = false
    /// The top of the block on screen, watched so a collapse can tell
    /// "you can still see where this starts" from "you have read past it".
    @State private var topOnScreen: CGFloat = .greatestFiniteMagnitude

    /// How far the block's top sits below its section heading.
    private static let headingRoom: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(palette.secondaryForeground)
                .lineLimit(expanded ? nil : collapsedLineLimit)
                .animation(.easeInOut(duration: 0.2), value: expanded)
            // A label rather than a button: with the whole block taking the tap, a button inside it
            // would be a second target for the same action — and two of those in one place is how a
            // tap lands on neither.
            Text(expanded ? "Show Less" : "Show More")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { topOnScreen = $0 }
        .onTapGesture { toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(expanded ? "Shows less" : "Shows more")
        .accessibilityAction { toggle() }
    }

    private func toggle() {
        // Only when the start of the text has gone off the top. If you can
        // still see where it begins, the page moving under you as you close a
        // few lines is a jolt for nothing.
        guard expanded,
              topOnScreen < Self.headingRoom,
              let scrollProxy,
              let scrollAnchor
        else {
            expanded.toggle()
            return
        }

        // Scroll first, fold second, and never both at once.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            scrollProxy.scrollTo(scrollAnchor, anchor: .top)
        }
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
        }
    }
}

/// A track in one column of the Popular / My Favourites grid.
struct CompactTrackRow: View {
    let position: Int
    let track: Track
    var isCurrent = false
    var palette: ArtworkPalette = .neutral
    /// Rating from the shelf itself, as in every other track list.
    var showsRating = true

    @Environment(AppModel.self) private var app

    private var ratingsAvailable: Bool {
        showsRating
            && app.settings.ratingVisibility.showsInOtherLists
            && (app.provider?.capabilities.contains(.ratings) ?? false)
            && app.settings.showsStars(for: track.rating)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(String(position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.secondaryForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let album = track.albumName {
                        Text(album)
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryForeground)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if ratingsAvailable, app.settings.ratingStyle != .singleStar {
                        rating
                    }
                }
            }
            Spacer(minLength: 0)
            if ratingsAvailable, app.settings.ratingStyle == .singleStar {
                rating
            }
            // Nothing but the bars ever sits here, so the slot reserves
            // their width on every row rather than only on the playing one.
            TrackTrailing(
                duration: nil,
                isCurrent: isCurrent,
                showsDuration: false,
                palette: palette
            )
        }
        .padding(.vertical, 7)
    }

    private var rating: some View {
        StarRatingControl(
            rating: track.rating,
            style: app.settings.ratingStyle,
            allowsHalfStars: app.provider?.capabilities.contains(.halfStarRatings) ?? false,
            palette: palette,
            size: 11
        ) { newRating in
            MediaActions(app: app).setRating(newRating, id: track.id)
        }
    }
}


/// A grid of equal columns, laid out at once rather than lazily.
struct EvenColumnsLayout: Layout {
    var columns: Int?
    var minimum: CGFloat
    var spacing: CGFloat
    var rowSpacing: CGFloat

    private struct Rows {
        var columnWidth: CGFloat
        var count: Int
        var heights: [CGFloat]
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> Rows {
        let count: Int
        if let columns {
            count = max(1, columns)
        } else {
            count = max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
        }
        let columnWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let row = subviews[index ..< min(index + count, subviews.count)]
            heights.append(
                row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
            )
            index += count
        }
        return Rows(columnWidth: columnWidth, count: count, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        let laid = rows(subviews, width: width)
        let height = laid.heights.reduce(0, +) + rowSpacing * CGFloat(max(0, laid.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (rowIndex, height) in laid.heights.enumerated() {
            for column in 0 ..< laid.count {
                let index = rowIndex * laid.count + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (laid.columnWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: laid.columnWidth, height: height)
                )
            }
            y += height + rowSpacing
        }
    }
}
