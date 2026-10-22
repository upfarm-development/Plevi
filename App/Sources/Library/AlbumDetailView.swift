import SwiftUI
import PleviDomain
import PleviAudio

struct AlbumDetailView: View {
    let album: Album
    /// Show only what is actually on the phone.
    let downloadedOnly: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The size this page is laying out in, read from its own scroll view —
    /// see `PageMetrics`, which turns it into the shape of the page. The
    /// height is only there to tell a window on its side from one stood up.
    @State private var pageSize: CGSize = .zero
    @State private var detail: AlbumDetail?
    /// The first track fetched in full, for the badge.
    @State private var detailedFirstTrack: Track?
    @State private var info: AlbumInfo?
    /// The review as it was last kept on this phone, shown when the server
    /// cannot be asked — offline, or from Downloads.
    @State private var keptNotes: String?
    /// Records the server says sound like this one, nearest first.
    @State private var similar: [Album] = []
    @State private var loadError: String?
    @State private var palette: PaletteLoader
    /// How far this page has been pulled past its own top — see
    /// `trackingHeaderPull`.
    @State private var headerPull: CGFloat = 0

    init(album: Album, downloadedOnly: Bool = false) {
        self.album = album
        self.downloadedOnly = downloadedOnly
        // Seeds an already-known colour so the page opens tinted.
        _palette = State(initialValue: PaletteLoader(artwork: album.artwork))
    }

    private var style: PageStyle {
        app.settings.pageStyle
    }

    private var activePalette: ArtworkPalette {
        .forPage(style, artwork: palette.palette)
    }

    private var metrics: PageMetrics {
        PageMetrics(
            size: pageSize,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    private var tracks: [Track] {
        let all = detail?.tracks ?? []
        // Reached from Downloads, the record is only the part of it that is here — hidden rather
        // than greyed.
        guard downloadedOnly else { return all }
        return all.filter { app.downloads?.isDownloaded($0.id) == true }
    }

    /// Where the page scrolls back to when a long review folds up.
    private static let aboutAnchor = "album-about"

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if metrics.standsSideBySide {
                        wideHeader
                    } else {
                        header
                    }
                    // Held back where the header is already carrying it —
                    // see `wideReview`.
                    if !metrics.standsSideBySide, app.settings.albumReviewPosition == .beforeTracks {
                        review(scrollProxy: scrollProxy)
                    }
                    trackList
                    releaseFooter
                    if !metrics.standsSideBySide, app.settings.albumReviewPosition == .afterTracks {
                        review(scrollProxy: scrollProxy)
                    }
                    similarSection
                }
                .padding(.bottom, 24)
            }
            // In the immersive style the artwork runs to the very top of the screen: anything less
            // leaves the navigation bar slicing across it.
            .ignoresSafeArea(edges: metrics.standsSideBySide ? [] : .top)
            // Glass under the clock, arriving as the cover leaves — see `TopBlur`.
            .withoutScrollEdgeBlur(topToo: !metrics.standsSideBySide)
            .topBlurAsArtworkLeaves(!metrics.standsSideBySide)
            .trackingHeaderPull($headerPull, active: !metrics.standsSideBySide)
            // `containerSize` rather than `contentOffset`: it is the scroll view's own size and
            // changes on a rotation or a window resize only, so this writes state a handful of
            // times in a session where the pull tracker beside it writes sixty times a…
            .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in
                if size != pageSize { pageSize = size }
            }
        }
        .background {
            PageBackground(style: style, artwork: palette.palette)
        }
        // The header already states the album name, and a title in a transparent bar over artwork
        // is unreadable anyway.
        .toolbarColorScheme(activePalette.chromeScheme, for: .navigationBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // Says what is happening and takes no touches for saying it.
        .overlay {
            Group {
                if detail == nil && loadError == nil {
                    ProgressView()
                } else if let loadError, detail == nil {
                    ContentUnavailableView {
                        Label("Can't load album", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        // Re-reads when the library version changes, so a rating written from
        // this screen is reflected here immediately.
        .task(id: app.libraryVersion) { await load() }
        // Its own task, so switching the setting on fills the shelf without
        // leaving and coming back — and so a page opened before the server
        // answered gets a second chance when it does.
        .task(id: "\(app.settings.showsSimilarAlbums)|\(showsOnlyWhatIsHere)|\(app.libraryVersion)") {
            await loadSimilar()
        }
    }

    // MARK: Sonically similar

    /// How many records the shelf shows, and how many are fetched so the
    /// full list behind the heading has something to be.
    private static let similarShelf = 5
    private static let similarFetched = 30

    @ViewBuilder
    private var similarSection: some View {
        // Offline the shelf goes: it is a question for the server, and every record on it would
        // open a page with nothing to play.
        if app.settings.showsSimilarAlbums, !showsOnlyWhatIsHere, !similar.isEmpty {
            let actions = MediaActions(app: app)
            SectionContainer(
                title: "Sonically Similar",
                palette: activePalette,
                more: similar.count > Self.similarShelf
                    ? AlbumCollection(
                        title: "Sonically Similar",
                        albums: similar,
                        layout: .list,
                        pinsLayout: true,
                        showsArtist: true,
                        artwork: album.artwork
                    )
                    : nil
            ) {
                VStack(spacing: 0) {
                    ForEach(similar.prefix(Self.similarShelf)) { album in
                        NavigationLink(value: album) {
                            // Named artists: a record that merely sounds like
                            // this one is usually somebody else's.
                            AlbumListRow(album: album, palette: activePalette, showsArtist: true)
                        }
                        .buttonStyle(.plain)
                        .albumContextMenu(album, actions: actions)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    /// Whether this page is being read as part of what is on the phone rather than as part of the
    /// library — either because the whole app is offline, or because it was opened from Downloads.
    private var showsOnlyWhatIsHere: Bool { app.isOffline || downloadedOnly }

    private func loadSimilar() async {
        guard !showsOnlyWhatIsHere else { return }
        guard app.settings.showsSimilarAlbums else {
            similar = []
            return
        }
        guard similar.isEmpty,
              let provider = app.provider,
              provider.capabilities.contains(.similarAlbums)
        else { return }
        // A server with no sonic analysis answers with nothing, and the
        // section stays away — this is not an error worth showing.
        similar = (try? await provider.similarAlbums(to: album.id, limit: Self.similarFetched)) ?? []
    }

    // MARK: Review

    /// What the server said just now, or failing that what this phone kept.
    private var reviewText: String? {
        [info?.notes, keptNotes]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    @ViewBuilder
    private func review(scrollProxy: ScrollViewProxy) -> some View {
        if app.settings.showsAlbumReview, let notes = reviewText {
            SectionContainer(title: "About", palette: activePalette) {
                ExpandableText(
                    text: notes,
                    palette: activePalette,
                    scrollAnchor: Self.aboutAnchor,
                    scrollProxy: scrollProxy
                )
                .padding(.horizontal)
            }
            .padding(.vertical, 20)
            .id(Self.aboutAnchor)
        }
    }

    // MARK: Header

    /// The album's artist as a link, when we know which artist it is.
    @ViewBuilder
    private func artistLabel(_ name: String, font: Font, color: Color) -> some View {
        if let artistID = album.artistID {
            NavigationLink(value: Artist(id: artistID, name: name)) {
                Text(name)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
        } else {
            Text(name)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var header: some View {
        ImmersiveHeader(
            artwork: album.artwork,
            palette: activePalette,
            fade: .album,
            // The details below are part of the same block as the name.
            titleBottom: 8,
            titleDrop: 4,
            dissolvesIntoBackground: style.usesBlurredBackground,
            pulledPast: headerPull
        ) {
            titleBlock
        } content: {
            detailsAndControls
        }
    }

    /// The record as a sleeve standing on the page, rather than as a page made out of the sleeve.
    private var wideHeader: some View {
        SideBySideHeader(
            artwork: album.artwork,
            palette: activePalette
        ) {
            wideDetails
        } about: { room in
            wideReview(room: room)
        }
    }

    private var wideDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(album.displayName)
                .font(.system(size: 40, weight: .bold))
                // The same -0.02em the phone's 34 / -0.68 uses, at this size.
                .tracking(-0.8)
                .foregroundStyle(activePalette.foreground)
                .lineLimit(2)
                // In the narrowest window that still counts as wide — an iPad mini upright, which
                // leaves this column about 384 points — a long name shrinks rather than losing half
                // of itself to an ellipsis.
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                // No shadow. The phone's title is written into the foot of
                // the artwork and needs one to be read through it; this one
                // stands on the page, where the same shadow is a smudge.

            if let artist = album.artistName {
                artistLabel(
                    artist,
                    font: .system(size: 22, weight: .medium),
                    color: activePalette.foreground
                )
                .padding(.top, 6)
            }

            // The same two facts the phone shows.
            if !headerMetaTail.isEmpty {
                Text(headerMetaTail)
                    .font(.system(size: 17))
                    .foregroundStyle(activePalette.secondaryForeground)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            HeaderActionRow(
                layout: .labelled,
                onPlay: { app.activePlayer.play(tracks, startingAt: 0, from: .album(detail?.album ?? album)) },
                onShuffle: { app.activePlayer.shuffle(tracks, startingWith: nil, from: .album(detail?.album ?? album), smart: nil) },
                palette: activePalette,
                isDisabled: tracks.isEmpty,
                // About brings its own space above it; the row's usual step
                // down would make two.
                bottomGap: 0,
                horizontalInset: 0,
                fixedWidth: metrics.actionRowWidth
            ) {
                albumMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The review, cut to the room left before the foot of the sleeve.
    @ViewBuilder
    private func wideReview(room: CGFloat) -> some View {
        if app.settings.showsAlbumReview, let notes = reviewText {
            InlineExpandableText(
                text: notes,
                width: metrics.textColumnWidth,
                availableHeight: room,
                palette: activePalette,
                sheetTitle: "About",
                // The only colour `PleviPalette` guarantees against this page in both styles.
                moreColor: activePalette.foreground
            )
            .padding(.top, PageMetrics.aboutTopGap)
        }
    }

    /// The record's name, written into the foot of the sleeve. Everything
    /// else stands below it, beside the controls.
    private var titleBlock: some View {
        Text(album.displayName)
            .font(.system(size: 34, weight: .bold))
            .tracking(-0.68)
            .foregroundStyle(activePalette.foreground)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 1)
    }

    /// Who it is by and what it is, with the controls at the end of the same two lines.
    private var detailsAndControls: some View {
        // No spacing of its own: the gap to the controls is the spacer's `minLength` and nothing
        // else.
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if let artist = album.artistName {
                    artistLabel(
                        artist,
                        font: .system(size: 19, weight: .medium),
                        color: activePalette.foreground
                    )
                }
                // No line at all rather than an empty one, as on the wide
                // header above and on the playlist's.
                if !headerMetaTail.isEmpty {
                    Text(headerMetaTail)
                        .font(metaFont)
                        .foregroundStyle(activePalette.secondaryForeground)
                        .lineLimit(1)
                }
            }
            // Comfortably clear of a forty-four point square without
            // taking a word off the line beside it.
            Spacer(minLength: 16)
            // Aligned from the right, and never squeezed by a long artist
            // name — that name truncates instead.
            playButtons()
                .layoutPriority(1)
        }
        .padding(.horizontal, HeaderFade.titleInset)
        .padding(.bottom, 22)
    }

    private var metaFont: Font { .system(size: 14.5) }

    /// When it came out and how long it runs.
    private var headerMetaTail: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        if let length = headerDuration { parts.append(Duration.spoken(length)) }
        return parts.joined(separator: " · ")
    }

    /// Added up from the songs on the page, since that is the only place the
    /// real number is. Nothing said at all until they are here: a running
    /// time that grows while you read it is worse than none.
    private var headerDuration: TimeInterval? {
        guard !tracks.isEmpty else { return album.duration }
        let known = tracks.compactMap(\.duration)
        guard known.count == tracks.count else { return album.duration }
        return known.reduce(0, +)
    }

    private var ratingsAvailable: Bool {
        app.settings.ratingVisibility.showsInAlbumsAndPlaylists
            && (app.provider?.capabilities.contains(.ratings) ?? false)
    }

    private func playButtons() -> some View {
        HeaderActionRow(
            layout: .compact,
            onPlay: { app.activePlayer.play(tracks, startingAt: 0, from: .album(detail?.album ?? album)) },
            onShuffle: { app.activePlayer.shuffle(tracks, startingWith: nil, from: .album(detail?.album ?? album), smart: nil) },
            palette: activePalette,
            isDisabled: tracks.isEmpty
        ) {
            albumMenu
        }
    }

    /// The same menu as a long press anywhere else — see `AlbumMenuContent`.
    private var albumMenu: some View {
        Menu {
            // The resolved album, so its rating is the one the page is
            // showing rather than the one the row it came from knew.
            AlbumMenuContent(album: detail?.album ?? album, actions: MediaActions(app: app))
                // The tint below is for the button's own circle, and it is a washed-out version of
                // the artwork's colour.
                .tint(Color.primary)
        } label: {
            Image(systemName: "ellipsis")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    // MARK: Tracks

    /// Offline, a song with no file behind it cannot play.
    private func isUnavailable(_ track: Track) -> Bool {
        showsOnlyWhatIsHere && app.downloads?.isDownloaded(track.id) != true
    }

    private var playableOffline: [Track] {
        showsOnlyWhatIsHere ? tracks.filter { !isUnavailable($0) } : tracks
    }

    /// The record's songs, in one ladder or two.
    @ViewBuilder
    private var trackList: some View {
        // Read once: `tracks` filters on every access, and what follows wants
        // a count and two slices of the same answer.
        let songs = tracks
        let queue = playableOffline
        // Worked out once for the whole record rather than per row: it is a
        // comparison across all of them, not a fact about any one song on
        // its own, and there are never more than a few dozen to rank.
        let hotTrackIDs = HotTracks.ids(in: songs, releaseType: album.primaryReleaseType)
        let discs = Self.discs(of: songs)
        // Four is the fewest that leaves two songs a side.
        let paired = metrics.pairsTrackList && discs.contains { $0.songs.count >= 4 }
        let playlist = TrackListContext(all: songs, queue: queue)
        if paired {
            // Two columns cannot be one flat list, so each is its own stack.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(discs) { disc in
                    if discs.count > 1 {
                        discHeading(disc.id, isFirst: disc.id == discs.first?.id)
                    }
                    // Split on the disc's own count, so a two-song bonus disc
                    // stays whole beside a record running in two.
                    let half = disc.songs.count >= 4
                        ? (disc.songs.count + 1) / 2
                        : disc.songs.count
                    HStack(alignment: .top, spacing: 0) {
                        trackColumn(disc.songs[..<half], context: playlist, hot: hotTrackIDs)
                        if disc.songs.count >= 4 {
                            trackColumn(disc.songs[half...], context: playlist, hot: hotTrackIDs)
                        }
                    }
                }
            }
        } else {
            // One flat list, headings and songs alike, directly under the
            // page's lazy stack: a single lazy level, so the page measures
            // what exists and builds a row only as it comes into view.
            ForEach(Self.items(of: discs)) { item in
                switch item.content {
                case .heading(let number, let isFirst):
                    discHeading(number, isFirst: isFirst)
                case .song(let track):
                    songRow(track, context: playlist, hot: hotTrackIDs)
                }
            }
        }
    }

    /// One song and the divider under it.
    private func songRow(_ track: Track, context: TrackListContext, hot: Set<MediaID>) -> some View {
        VStack(spacing: 0) {
            AlbumTrackRow(
                track: track,
                context: context,
                origin: detail?.album ?? album,
                isCurrent: app.activePlayer.currentTrack?.id == track.id,
                isHot: hot.contains(track.id),
                unavailable: isUnavailable(track),
                palette: activePalette,
                verticalPadding: app.settings.trackRowStyle.verticalPadding
            )
            .equatable()
            Divider()
                .opacity(0.18)
                .padding(.leading, 48)
        }
    }

    /// One ladder of songs for the two-column layout. `all` and `queue` stay
    /// the whole record in both columns: a tap resolves the song by its id,
    /// not by where it sits.
    @ViewBuilder
    private func trackColumn(
        _ songs: ArraySlice<Track>,
        context: TrackListContext,
        hot: Set<MediaID>
    ) -> some View {
        if songs.count > Self.longDisc {
            LazyVStack(spacing: 0) {
                ForEach(songs) { songRow($0, context: context, hot: hot) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(songs) { songRow($0, context: context, hot: hot) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Past this many songs a column of the two-column layout is lazy.
    private static let longDisc = 80

    /// What one entry of the flat list is: a disc heading or a song.
    private struct TrackListItem: Identifiable {
        enum ID: Hashable {
            case disc(Int)
            case song(MediaID)
        }
        enum Content {
            case heading(Int, isFirst: Bool)
            case song(Track)
        }
        let id: ID
        let content: Content
    }

    /// The record flattened into headings and songs, in order. A heading only
    /// where there is more than one disc.
    private static func items(of discs: [DiscGroup]) -> [TrackListItem] {
        var out: [TrackListItem] = []
        for disc in discs {
            if discs.count > 1 {
                out.append(TrackListItem(
                    id: .disc(disc.id),
                    content: .heading(disc.id, isFirst: disc.id == discs.first?.id)
                ))
            }
            out.append(contentsOf: disc.songs.map {
                TrackListItem(id: .song($0.id), content: .song($0))
            })
        }
        return out
    }

    /// One disc of a record, and the songs pressed on it.
    private struct DiscGroup: Identifiable {
        /// The disc's number, which is also what the block on screen is held by — it is what the
        /// group actually is.
        let id: Int
        let songs: [Track]
    }

    /// The record's songs split into discs, in disc order.
    private static func discs(of songs: [Track]) -> [DiscGroup] {
        Dictionary(grouping: songs) { max($0.discNumber ?? 1, 1) }
            .sorted { $0.key < $1.key }
            .map { DiscGroup(id: $0.key, songs: $0.value) }
    }

    /// Which disc the songs below it are on.
    private func discHeading(_ number: Int, isFirst: Bool) -> some View {
        Text("Disc \(number)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(activePalette.secondaryForeground)
            .accessibilityAddTraits(.isHeader)
            // The rows' own margin, so the heading starts where their numbers
            // do rather than where their titles do. It heads the whole
            // ladder, numbers included.
            .padding(.horizontal)
            // The page header already leaves the gap above the first disc;
            // only the ones after it open their own. Enough of a step to
            // close the ladder above without reading as a new section.
            .padding(.top, isFirst ? 0 : 20)
            .padding(.bottom, 8)
    }

    // MARK: Release footer

    /// Label and release date on the left, a format badge on the right —
    /// the small print of a record, in the place a sleeve would put it.
    @ViewBuilder
    private var releaseFooter: some View {
        let credit = releaseCredit
        let format = formatBadge
        if credit != nil || format != nil {
            HStack(alignment: .center, spacing: 12) {
                if let credit {
                    Text(credit)
                        .font(.footnote)
                        .foregroundStyle(activePalette.secondaryForeground)
                }
                Spacer(minLength: 0)
                if let format {
                    Text(format)
                        .font(.caption2.monospaced())
                        .foregroundStyle(activePalette.secondaryForeground)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(activePalette.secondaryForeground.opacity(0.45), lineWidth: 1)
                        }
                }
            }
            .padding(.horizontal)
            .padding(.top, 14)
        }
    }

    private var releaseCredit: String? {
        let album = detail?.album ?? album
        var parts: [String] = []
        if let label = album.recordLabel, !label.isEmpty { parts.append(label) }
        if let date = album.releaseDate {
            parts.append(date.formatted(.dateTime.day().month(.abbreviated).year()))
        } else if let year = album.year {
            parts.append(String(year))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }

    /// Taken from the album's first track, because the format belongs to the files rather than to
    /// the album record.
    private var formatBadge: String? {
        guard app.settings.showsCodecBadge else { return nil }
        guard let track = detailedFirstTrack ?? tracks.first else { return nil }
        // A kept copy that was converted on the way down is what would
        // actually play, so it is what the badge says. The library's own
        // entry still describes the server's original.
        if let converted = app.downloads?.downloadedConversion(for: track.id) {
            return CodecBadge.downloaded(
                codec: converted.codec,
                kbps: converted.kbps,
                settings: app.settings
            )
        }
        return CodecBadge.original(for: track, settings: app.settings)
    }

    // MARK: Loading

    /// The index paints the page at once; the server then has the last word.
    @State private var askedTheServer = false
    /// Whether `detail` is the server's answer rather than the index's. The
    /// server's carries credits the index never had, so a later re-read of
    /// the index (a star tapped) must update ratings on it, not replace it.
    @State private var hasServerDetail = false

    private func refreshFromServer() async {
        guard let provider = app.provider,
              var fresh = try? await provider.album(id: album.id),
              !fresh.tracks.isEmpty
        else { return }
        // Under the identity the page was opened with.
        fresh.tracks = fresh.tracks.map { $0.rekeyed(to: album.id.server) }
        detail = fresh
        hasServerDetail = true
    }

    /// The server's detail with the index's current ratings, favourites and play counts laid over
    /// it.
    private func merging(_ indexed: AlbumDetail, into current: AlbumDetail) -> AlbumDetail {
        var merged = current
        merged.album.rating = indexed.album.rating
        merged.album.isFavorite = indexed.album.isFavorite
        let byID = Dictionary(indexed.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in merged.tracks.indices {
            guard let local = byID[merged.tracks[index].id] else { continue }
            merged.tracks[index].rating = local.rating
            merged.tracks[index].isFavorite = local.isFavorite
            merged.tracks[index].playCount = local.playCount
            merged.tracks[index].playedAt = local.playedAt
        }
        return merged
    }

    /// One request, and only when the badge is on and the indexed track is
    /// missing the numbers it would show.
    private func loadBadgeDetail() async {
        guard app.settings.showsCodecBadge,
              let first = tracks.first,
              first.sampleRate == nil || first.bitDepth == nil,
              detailedFirstTrack?.id != first.id,
              let provider = app.provider
        else { return }
        detailedFirstTrack = try? await provider.track(id: first.id)
    }

    private func load() async {
        // The record's own library, which is not the open one for an album found through a search
        // across libraries or kept in another library's downloads.
        let id = album.id
        let indexed: AlbumDetail? = if let index = app.index(for: id.server) {
            await Task.detached(priority: .userInitiated) { try? index.albumDetail(id: id) }.value
        } else {
            nil
        }
        if let indexed, !indexed.tracks.isEmpty {
            if hasServerDetail, let current = detail {
                detail = merging(indexed, into: current)
            } else {
                detail = indexed
            }
        } else if detail == nil, let provider = app.provider {
            do {
                detail = try await provider.album(id: album.id)
            } catch {
                loadError = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            }
        }

        // Once per opening, not once per reload.
        let colours = Task { await palette.load(artwork: album.artwork, using: app.artwork) }
        // Before any request, so an album opened with no server shows its
        // review at once rather than after a failed attempt.
        if keptNotes == nil {
            keptNotes = try? app.libraryIndex?.albumNotes(forAlbum: album.id)
        }
        if !askedTheServer {
            askedTheServer = true
            if !downloadedOnly {
                await refreshFromServer()
                // Cancelled by the version bump that started this very call
                // over: the one-shot has not been spent, so the run that
                // replaced it makes the request.
                if Task.isCancelled { askedTheServer = false }
            }
        }
        await loadBadgeDetail()
        await colours.value
        if let provider = app.provider,
           provider.capabilities.contains(.albumInfo),
           info == nil {
            info = try? await provider.albumInfo(id: album.id)
            // Kept for the next time there is no server to ask.
            if let notes = info?.notes {
                try? app.libraryIndex?.storeAlbumNotes(ReviewLedger.tidied(notes), forAlbum: album.id)
            }
        }
        // Opening an album is a strong hint the artist is next.
        if let artistID = album.artistID, let artistName = album.artistName {
            app.artistPrefetcher.prefetch(Artist(id: artistID, name: artistName))
        }
    }
}

struct TrackRow: View {
    let track: Track
    var isCurrent = false
    /// Shows the rating control when the server supports ratings. Five stars
    /// sit beneath the title; a single star sits at the trailing edge next to
    /// the duration, where it keeps a fixed position down the list.
    var showsRating = false
    /// Kept on by default: a track's own artist matters whenever it differs
    /// from the album artist.
    var showsArtist = true
    /// The number down the left. An album has track numbers worth reading; a
    /// playlist's are just the row's position, which the eye already knows.
    var showsPosition = true
    /// Sleeve at the leading edge. An album page has one picture for every
    /// song on it; a playlist draws from everywhere, so the artwork is what
    /// tells one row from the next at a glance.
    var showsArtwork = false
    /// One of the record's own standouts — see `HotTracks`.
    var isHot = false
    var palette: ArtworkPalette = .neutral

    @Environment(AppModel.self) private var app

    /// Album pages and playlists follow the same setting; see `TrackRowStyle`.
    private var rowStyle: TrackRowStyle {
        app.settings.trackRowStyle
    }

    /// The song as this row should draw its stars: the rating just set on
    /// this device where there is one, else what the list was handed. See
    /// `AppModel.ratedLocally`.
    private var shown: Track {
        guard let rated = app.ratedLocally[track.id] else { return track }
        var copy = track
        copy.rating = rated
        return copy
    }

    private var ratingsAvailable: Bool {
        showsRating
            && app.settings.ratingVisibility.showsInAlbumsAndPlaylists
            && (app.provider?.capabilities.contains(.ratings) ?? false)
            // Quiet rows: with this on, an unrated song shows nothing rather
            // than five empty stars. It can still be rated from its menu.
            && app.settings.showsStars(for: shown.rating)
    }

    private var style: RatingStyle {
        app.settings.ratingStyle
    }

    var body: some View {
        HStack(spacing: 10) {
            if showsPosition {
                positionColumn
                    .frame(width: 22, alignment: .center)
                    .font(rowStyle.numberFont)
            }

            if showsArtwork {
                ArtworkView(artwork: track.artwork, size: 40, cornerRadius: 5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(rowStyle.titleFont)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                // Artist and stars share the second line, the stars at its right-hand end: one line
                // saved per row, and the stars line up down the list.
                HStack(spacing: 8) {
                    // The duration leads the second line when the bars have
                    // taken the trailing edge; a length and an artist read
                    // fine side by side, and it keeps the row two lines.
                    if rowStyle.durationBesideArtist, let duration = track.duration {
                        Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryForeground)
                            .monospacedDigit()
                    }
                    if showsArtist, let artist = track.artistName {
                        // A track's own artist, not the album's — the two differ on a compilation,
                        // where every song has its own name here but the record itself credits
                        // "Various Artists".
                        Text(artist)
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryForeground)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if ratingsAvailable, style != .singleStar, !rowStyle.ratingAsNumber {
                        ratingControl
                    }
                }
            }

            Spacer(minLength: 4)

            if rowStyle.ratingAsNumber {
                if ratingsAvailable {
                    RatingSummaryButton(
                        track: shown,
                        palette: palette,
                        font: rowStyle.durationFont,
                        showsBars: rowStyle.ratingAsBars
                    )
                }
            } else if ratingsAvailable, style == .singleStar {
                ratingControl
            }
            // Without a number column the playing marker has nowhere to sit
            // on the left, so it takes the duration's place.
            TrackTrailing(
                duration: track.duration,
                isCurrent: isCurrent && !showsPosition,
                isHot: isHot,
                showsDuration: !rowStyle.durationBesideArtist,
                font: rowStyle.durationFont,
                palette: palette
            )
        }
    }

    /// The number down the left, or the marker for the track that is playing.
    @ViewBuilder
    private var positionColumn: some View {
        if isCurrent {
            Image(systemName: "waveform")
                // In the standout colour where the song playing is one, so that starting a record's
                // best-known track does not hide the one thing the row was marked with.
                .foregroundStyle(
                    isHot ? AnyShapeStyle(palette.hotAccent) : AnyShapeStyle(.tint)
                )
                .accessibilityLabel("Now playing")
        } else {
            Text(track.trackNumber.map(String.init) ?? "·")
                .foregroundStyle(isHot ? palette.hotAccent : palette.secondaryForeground)
                .fontWeight(isHot ? .bold : .regular)
                .monospacedDigit()
                // The column is two digits wide, which a record with a hundred tracks or more
                // outgrew: the number was cut to an ellipsis.
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }

    private var ratingControl: some View {
        StarRatingControl(
            rating: shown.rating,
            style: style,
            allowsHalfStars: app.provider?.capabilities.contains(.halfStarRatings) ?? false,
            palette: palette,
            size: 12
        ) { newRating in
            MediaActions(app: app).setRating(newRating, id: track.id)
        }
    }
}

/// One song on a record's page, and everything a long press on it can do.
private final class TrackListContext: Equatable, @unchecked Sendable {
    let all: [Track]
    let queue: [Track]
    private let fingerprint: Int

    init(all: [Track], queue: [Track]) {
        self.all = all
        self.queue = queue
        var hasher = Hasher()
        hasher.combine(all)
        // The queue is the record, or the part of it that can play. A count
        // is not enough to tell two such parts apart, so it is hashed too.
        if queue.count == all.count {
            hasher.combine(true)
        } else {
            hasher.combine(queue)
        }
        fingerprint = hasher.finalize()
    }

    nonisolated static func == (lhs: TrackListContext, rhs: TrackListContext) -> Bool {
        lhs === rhs || lhs.fingerprint == rhs.fingerprint
    }
}

/// Its own view, and `Equatable`, because the page around it is not still while somebody is reading
/// it: the record comes back from the server, the first song's full detail lands for the codec
/// badge, the review arrives, the sonically-similar…
private struct AlbumTrackRow: View, Equatable {
    let track: Track
    /// What a tap plays, and what "shuffle the rest" shuffles.
    let context: TrackListContext
    let origin: Album
    let isCurrent: Bool
    let isHot: Bool
    let unavailable: Bool
    let palette: ArtworkPalette
    let verticalPadding: CGFloat

    @Environment(AppModel.self) private var app

    /// Compared off the main actor — everything here is a value, and
    /// `EquatableView` is entitled to ask on whichever thread it is drawing
    /// from.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.track == rhs.track
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isHot == rhs.isHot
            && lhs.unavailable == rhs.unavailable
            && lhs.palette == rhs.palette
            && lhs.verticalPadding == rhs.verticalPadding
            && lhs.origin == rhs.origin
            && lhs.context == rhs.context
    }

    var body: some View {
        TrackRow(
            track: track,
            isCurrent: isCurrent,
            showsRating: true,
            isHot: isHot,
            palette: palette
        )
        .opacity(unavailable ? 0.35 : 1)
        .padding(.horizontal)
        .padding(.vertical, verticalPadding)
        // The tap belongs to the row itself, not to a clear layer behind it.
        .contentShape(Rectangle())
        .onTapGesture {
            guard !unavailable else { return }
            // Offline, the queue is what can actually play: starting an album
            // and having it stop three songs in is worse than starting with
            // the three.
            let start = context.queue.firstIndex(where: { $0.id == track.id }) ?? 0
            app.activePlayer.play(context.queue, startingAt: start, from: .album(origin))
        }
        .trackContextMenu(
            track,
            actions: MediaActions(app: app),
            onShuffleRest: {
                MediaActions(app: app).shuffle(context.all, startingWith: track, from: .album(origin))
            },
            // No "Go to Album" — this is it. The artist is worth offering
            // even here: on a compilation every song has a different one, and
            // this is now the only way to reach them from a row.
            onGoToArtist: track.artistID.map { id in
                { app.requestNavigation(.artist(id, name: track.artistName)) }
            }
        )
    }
}
