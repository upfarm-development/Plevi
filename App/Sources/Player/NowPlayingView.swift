import SwiftUI
import AVKit
import PleviDomain

/// The full player.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    /// Read only for the iPad wide layout's own gate — see `PageMetrics`, whose `standsSideBySide`
    /// test this mirrors so this screen agrees with the album, artist and playlist pages about what
    /// counts as "wide enough," rather than drawing its own…
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Taking the screen away. Its own closure rather than `dismiss`: this is
    /// a layer of the app now, not something presented over it, so there is
    /// nothing for the environment's dismissal to act on.
    let onClose: () -> Void

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var waveform: [Float]?
    /// What the bar is given.
    private var shownWaveform: [Float]? {
        waveform ?? app.readyWaveform(for: player.currentTrack)
    }
    /// Plex puts the year on the album rather than the track, so it is looked
    /// up when the track does not carry one.
    @State private var albumYear: Int?
    @State private var showSleepTimer = false
    @State private var showLyrics = false
    @State private var showDJSheet = false
    /// The words to what is playing, or nil for a song the server has none for — which is also what
    /// decides whether the button is offered.
    @State private var heldLyrics: Lyrics?
    @State private var lyricsTrackID: MediaID?
    private var lyrics: Lyrics? {
        lyricsTrackID != nil && lyricsTrackID == player.currentTrack?.id ? heldLyrics : nil
    }
    /// The playing track fetched in full, for the badge; see the album page.
    @State private var detailedTrack: Track?
    @State private var confirmingStop = false
    @State private var palette = PaletteLoader()
    /// The sleeve the page is drawing, which is not always the sleeve the player is on.
    @State private var shownArtwork: ArtworkID?
    /// The screen's own margins, handed in because the layer this is drawn
    /// on ignores the safe area and so has none left to report.
    let safeArea: EdgeInsets
    /// Whether the queue is scrolled to its top, which is the only place a
    /// downward drag means "close" rather than "scroll".
    @State private var listIsAtTop = true
    /// Where the queue rail sits on screen, in the window's coordinates, so
    /// the dismiss drag can tell a drag in the rail from one on the player
    /// — see `card`'s `CardDismissDrag`.
    @State private var railFrame: CGRect = .zero
    /// The last size this screen laid out at, mirrored out of `content`'s own `GeometryReader` so
    /// the dismiss drag — built outside that reader, as a sibling overlay — can still ask whether
    /// the wide layout is the one on screen.
    @State private var cardMetrics = PageMetrics(
        size: .zero,
        horizontalSizeClass: nil,
        verticalSizeClass: nil,
        dynamicTypeSize: .large
    )
    /// Which half of the queue is showing. Up Next on the way in: it is what
    /// this screen has always opened on, and the far commoner question.
    @State private var queueTab: QueueTab = .upNext
    @State private var queueMetrics = QueueScrollMetrics()
    /// The height the phone's list is being held at, while it is.
    @State private var pinnedContentHeight: CGFloat?
    /// Blank rows at the foot of the list making up the difference.
    @State private var tailSpacer: CGFloat = 0
    /// Whether the iPad's queue rail is open, for as long as this screen is.
    @State private var railOpen: Bool?
    /// Whether the card is standing aside for the drag's snapshot copy —
    /// see `CardDismissDrag`, which moves a picture of this screen rather
    /// than the screen. The card itself never travels a point.
    @State private var hiddenBehindStandIn = false
    /// The badge as it is currently on screen.
    @State private var shownBadge: String?
    private var player: any PlaybackControlling { app.activePlayer }
    private var track: Track? { player.currentTrack }
    private var actions: MediaActions { MediaActions(app: app) }

    /// §4.8.2: "Stop playing on Kitchen iPad and clear its queue?" while
    /// remote — asked in both places a stop is confirmed (here and
    /// `MiniPlayerBar`'s own popover).
    private var stopConfirmationTitle: String {
        guard let name = app.remote.controlledDeviceName else { return "Stop playing and clear the queue?" }
        return "Stop playing on \(name) and clear its queue?"
    }

    private var style: PageStyle {
        app.settings.pageStyle
    }

    private var colors: ArtworkPalette {
        .forPage(style, artwork: palette.palette)
    }

    /// iPad has no Bleed to choose from — its own screen is always framed, including the
    /// narrow-window fallback below `PageMetrics`' side-by-side width, which still renders through
    /// `ModernPlayerPage` and would otherwise still answer to whatever…
    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var layout: NowPlayingLayout { isIPad ? .contained : app.settings.nowPlayingLayout }

    /// The two extra colours the artwork-led screens need, struck against the
    /// page they are actually drawn on rather than a dark one of their own.
    private var playerPalette: PlayerPalette {
        PlayerPalette(page: colors, artwork: palette.palette)
    }

    var body: some View {
        card(safeArea: safeArea)
    }

    private func card(safeArea: EdgeInsets) -> some View {
        content
            // The screen's own margins, given back to the *content* while the card behind it keeps
            // the whole screen.
            .padding(.top, layout == .bleed ? 0 : safeArea.top)
            .padding(.bottom, safeArea.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A real background rather than a ZStack layer, so it can never
            // paint over the controls.
            .background { background }
            // A card of its own rather than a sheet, so the bleeding artwork reaches the top edge
            // of the screen instead of stopping a few points short of it.
            .opacity(hiddenBehindStandIn ? 0 : 1)
            .overlay {
                CardDismissDrag(
                    canBegin: { start in
                        guard Self.hostsRail(cardMetrics) else { return listIsAtTop }
                        let expanded = railExpanded(landscape: cardMetrics.isOnItsSide)
                        // A drag on the player pane closes the screen; a drag that starts in the
                        // open rail is the queue's, whatever it is scrolled to.
                        return !(expanded && railFrame.contains(start))
                    },
                    setCardHidden: { hiddenBehindStandIn = $0 },
                    onClose: onClose
                )
            }
            .colorScheme(colors.chromeScheme ?? .dark)
            .sheet(isPresented: $showSleepTimer) { SleepTimerView() }
            .sheet(isPresented: $showDJSheet) { DJSheetView(palette: playerPalette) }
            .sheet(isPresented: $showLyrics) {
                if let lyrics, let track {
                    LyricsView(
                        lyrics: lyrics,
                        palette: playerPalette,
                        title: track.title,
                        artist: track.artistName
                    )
                } else if let track {
                    // The next song's words are on their way.
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(track.title).font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: "\(track?.id.rawValue ?? "none")|\(app.settings.showsLyrics)") {
                guard app.settings.showsLyrics,
                      let track,
                      let provider = app.provider,
                      provider.capabilities.contains(.syncedLyrics)
                else {
                    replaceLyrics(with: nil, for: nil)
                    return
                }
                // Quietly.
                do {
                    let found = try await provider.lyrics(for: track.id)
                    guard !Task.isCancelled else { return }
                    replaceLyrics(with: found, for: track.id)
                } catch {
                    guard !Task.isCancelled, !error.isCancelledFetch else { return }
                    replaceLyrics(with: nil, for: track.id)
                }
            }
            .confirmationDialog(
                stopConfirmationTitle,
                isPresented: $confirmingStop,
                titleVisibility: .visible
            ) {
                Button("Stop and Clear", role: .destructive) {
                    stopAndDismiss()
                }
            }
            .task(id: track?.artwork?.rawValue) {
                let arriving = track?.artwork
                await holdForTheSleeve()
                // Skipped past while it was loading: the song it was for has
                // gone, and this finishing last would put its sleeve and
                // colours over the one that is playing.
                guard !Task.isCancelled else { return }
                await palette.load(artwork: arriving, using: app.artwork)
                guard !Task.isCancelled else { return }
                // `load` publishes the palette as it returns, and this lands
                // in the same turn, so the page's colour and the sleeve are
                // one change rather than two a moment apart.
                shownArtwork = arriving
            }
            .task(id: track?.albumID?.rawValue) {
                albumYear = nil
                guard track?.year == nil, let albumID = track?.albumID else { return }
                albumYear = (try? app.libraryIndex?.albumDetail(id: albumID))??.album.year
            }
            .task(id: track?.id.rawValue) {
                waveform = nil
                guard app.settings.progressStyle.needsWaveform else { return }
                let drawn = await app.waveform(for: track)
                // The sampler finishes whatever it started; only the answer
                // for the song now playing belongs on the scrubber.
                guard !Task.isCancelled else { return }
                waveform = drawn
            }
            .onChange(of: codecBadge, initial: true) { _, badge in
                // A nil badge — mid-fetch, or the setting switched off — is
                // not news: the last thing said is still the truest thing
                // known. Only a real value replaces it.
                if let badge, badge != shownBadge { shownBadge = badge }
                if !app.settings.showsCodecInfo { shownBadge = nil }
            }
            .onChange(of: track == nil) { _, stopped in
                if stopped { shownBadge = nil }
            }
            .task(id: track?.id.rawValue) {
                detailedTrack = nil
                // One request, and only when the badge is on and the track as
                // indexed has nothing more to say; see the album page.
                guard app.settings.showsCodecInfo,
                      let track,
                      track.sampleRate == nil || track.bitDepth == nil,
                      let provider = app.provider
                else { return }
                detailedTrack = try? await provider.track(id: track.id)
            }
    }

    /// Swaps in the words for whatever is playing now.
    private func replaceLyrics(with found: Lyrics?, for id: MediaID?) {
        heldLyrics = found
        lyricsTrackID = id
        if found == nil { showLyrics = false }
    }

    /// Asks first only if the setting says to; the action is deliberate
    /// either way.
    private func requestStop() {
        guard app.settings.confirmsStopAndClear else {
            stopAndDismiss()
            return
        }
        // The popover is anchored to the classic screen's play button.
        confirmingStop = true
    }

    private func stopAndDismiss() {
        // Closing first, and emptying the queue only once the screen has actually gone.
        let leaving = player.currentTrack?.id
        withAnimation { onClose() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.dismissalSettleMilliseconds))
            // Nothing is stopped that the listener has since started: a tap on
            // another song during the animation is a new intention, and the
            // one that asked for silence has already had its screen closed.
            guard player.currentTrack?.id == leaving else { return }
            player.stop()
        }
    }

    /// Comfortably past the spring the screen leaves on, so nothing about the
    /// track is taken away while any of the card is still visible.
    private static let dismissalSettleMilliseconds = 620

    /// What the sleeve should draw: the one held back with the palette, or
    /// the current track's on the first pass through.
    private var artworkOnScreen: ArtworkID? { shownArtwork ?? track?.artwork }

    private var background: some View {
        PageBackground(style: style, artwork: palette.palette)
            // The same fade the sleeve uses when its picture arrives, so the page changes colour at
            // exactly the rate the record changes.
            .animation(.easeIn(duration: 0.15), value: palette.palette)
    }

    /// Branches once, on a measurement, between the iPad wide layout below and `phoneContent` — the
    /// original arrangement, byte-identical to what this screen has always drawn on a phone, and
    /// still what a narrow Split View or Slide Over on iPad…
    private var content: some View {
        GeometryReader { proxy in
            let metrics = PageMetrics(
                size: proxy.size,
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                dynamicTypeSize: dynamicTypeSize
            )
            Group {
                if Self.hostsRail(metrics) {
                    iPadLayout(metrics: metrics)
                } else {
                    phoneContent(pageHeight: proxy.size.height, pageWidth: proxy.size.width)
                }
            }
            .onChange(of: metrics, initial: true) { _, new in cardMetrics = new }
        }
    }

    /// The page as the `List`'s own first row, Up Next scrolling below it in the same list — the
    /// original arrangement, one scroll end to end.
    private func phoneContent(pageHeight: CGFloat, pageWidth: CGFloat) -> some View {
        List {
            playerPage(pageHeight: pageHeight, pageWidth: pageWidth)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
            queueHeader
            switch queueTab {
            case .upNext: upNext
            case .history: playedAlready
            }
            if tailSpacer > 0 {
                Color.clear
                    .frame(height: tailSpacer)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
                    .deleteDisabled(true)
                    .animation(nil, value: tailSpacer)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: QueueScrollMetrics.self) { geometry in
            QueueScrollMetrics(
                content: geometry.contentSize.height,
                offset: geometry.visibleRect.minY,
                visibleBottom: geometry.visibleRect.maxY
            )
        } action: { _, metrics in
            settleTail(metrics)
        }
        // Whether a downward drag closes the screen or scrolls the queue is decided by this and
        // nothing else, which is what keeps the two from fighting: at the top the card goes,
        // anywhere else the list scrolls.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y <= geometry.contentInsets.top + 0.5
        } action: { _, atTop in
            listIsAtTop = atTop
        }
    }

    // MARK: iPad — wide layout
    //
    // Everything from here to the end of this MARK is iPad-only: the queue
    // becomes a collapsible trailing rail instead of the rest of one
    // scrolling list, and the player pane beside it never scrolls at all.
    // Gated in `content` above on `hostsRail`: the same
    // `PageMetrics.standsSideBySide` test the album, artist and playlist
    // pages already use for their own wide layout, plus room for an open
    // rail beside a whole player. So a narrow Split View, an accessibility
    // text size, a window too narrow for the rail, or an iPhone — which is
    // portrait-only and so never passes it — all fall back to
    // `phoneContent`, unchanged.

    private static let collapsedRailWidth: CGFloat = 56
    /// The chevron's disc, the same in both directions — one button that
    /// turns, not two.
    private static let railChevronSize: CGFloat = 36
    /// The rail's side margin, for its header and its rows alike so the
    /// chevron, the switch and the sleeves down the list share one left edge.
    private static let railMargin: CGFloat = 24
    /// What the rail's rows take above and below, on top of the phone's, to
    /// give the taller row the design draws — 56 points against 52.
    private static let railRowExtraPadding: CGFloat = 2
    private static let expandedRailWidthLandscape: CGFloat = 424
    private static let expandedRailWidthPortrait: CGFloat = 312

    /// The narrowest the player pane may be left beside an open rail, in the side-by-side
    /// arrangement: its two margins, the gutter, the metadata column's stated minimum and the
    /// sleeve's stated minimum — `IPadPlayerPane`'s own constants, added up…
    private static let landscapePaneMinimum: CGFloat =
        IPadPlayerPane.sidePadding * 2
        + IPadPlayerPane.artworkGutter
        + IPadPlayerPane.landscapeMetadataMinWidth
        + IPadPlayerPane.minArtworkSide
    /// Below this an open rail is too narrow to read a queue in.
    private static let usableRailWidth: CGFloat = 280

    /// Whether this window can host the rail layout at all.
    private static func hostsRail(_ metrics: PageMetrics) -> Bool {
        guard metrics.standsSideBySide else { return false }
        guard metrics.isOnItsSide else { return true }
        return metrics.width - landscapePaneMinimum >= usableRailWidth
    }

    /// How wide the open rail is here: its full width where there is room,
    /// giving way down to `usableRailWidth` where there is not, so the
    /// player keeps its minimum rather than the rail keeping its maximum.
    private static func expandedRailWidth(landscape: Bool, width: CGFloat) -> CGFloat {
        guard landscape else { return expandedRailWidthPortrait }
        return max(usableRailWidth, min(expandedRailWidthLandscape, width - landscapePaneMinimum))
    }
    private static let railSpring = Animation.spring(response: 0.42, dampingFraction: 0.88)

    private func iPadLayout(metrics: PageMetrics) -> some View {
        let landscape = metrics.isOnItsSide
        let expanded = railExpanded(landscape: landscape)
        return HStack(spacing: 0) {
            IPadPlayerPane(
                palette: playerPalette,
                artwork: artworkOnScreen,
                waveform: shownWaveform,
                badge: shownBadge,
                badgeSlot: badgeSlot,
                albumYear: albumYear,
                error: player.lastError,
                isLandscape: landscape,
                railExpanded: expanded,
                isScrubbing: $isScrubbing,
                scrubTime: $scrubTime,
                onNavigate: navigate,
                onStop: requestStop,
                onSleepTimer: { showSleepTimer = true },
                lyrics: lyrics,
                onLyrics: { showLyrics = true },
                onDJ: { showDJSheet = true },
                onClose: onClose
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            queueRail(landscape: landscape, width: metrics.width)
        }
        .onAppear {
            if railOpen == nil { railOpen = expanded }
        }
    }

    /// The rail's state right now: what it was left as on this screen, or
    /// what the setting for this orientation says if it has not been drawn yet.
    private func railExpanded(landscape: Bool) -> Bool {
        railOpen ?? (landscape
            ? app.settings.queueRailExpandedLandscape
            : app.settings.queueRailExpandedPortrait)
    }

    // MARK: iPad — queue rail

    /// A drawer: the open rail is always laid out at its full width and slides in from, and out to,
    /// the trailing edge, while the space it takes grows and shrinks around it.
    @ViewBuilder
    private func queueRail(landscape: Bool, width: CGFloat) -> some View {
        let expanded = railExpanded(landscape: landscape)
        let openWidth = Self.expandedRailWidth(landscape: landscape, width: width)
        ZStack(alignment: .trailing) {
            if expanded {
                expandedRail(landscape: landscape)
                    .frame(width: openWidth)
                    .transition(.move(edge: .trailing))
            } else {
                collapsedRailTab(landscape: landscape)
                    .frame(width: Self.collapsedRailWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(width: expanded ? openWidth : Self.collapsedRailWidth, alignment: .trailing)
        .frame(maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { railFrame = $0 }
        .animation(reduceMotion ? nil : Self.railSpring, value: expanded)
    }

    /// The translucent material every state of the rail sits on, with the hairline leading border
    /// that marks it off from the player pane.
    private var railBackground: some View {
        Group {
            if reduceTransparency {
                colors.background
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(colors.foreground.opacity(0.14)).frame(width: 0.5)
        }
        .ignoresSafeArea(edges: .vertical)
    }

    /// Tapping anywhere on the tab expands the rail — there is no separate
    /// hit target for the chevron, which is drawn here rather than made its
    /// own button so the whole strip answers to one tap.
    private func collapsedRailTab(landscape: Bool) -> some View {
        Button {
            toggleRail(landscape: landscape, to: true)
        } label: {
            VStack(spacing: 16) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.foreground.opacity(0.7))
                    .frame(width: Self.railChevronSize, height: Self.railChevronSize)
                    .background { Circle().fill(colors.foreground.opacity(0.1)) }
                RotatedRailLabel(
                    text: "UP NEXT · \(player.upNextCount.formatted())",
                    color: colors.secondaryForeground
                )
            }
            .padding(.top, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { railBackground }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Up next, \(player.upNextCount.counted("song"))")
        .accessibilityHint("Expands the queue")
    }

    /// One chevron, two directions: this is the only affordance for
    /// collapsing the rail back down, the same way the tab above is the
    /// only affordance for opening it.
    private func expandedRail(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    toggleRail(landscape: landscape, to: false)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.foreground.opacity(0.7))
                        .frame(width: Self.railChevronSize, height: Self.railChevronSize)
                        .background { Circle().fill(colors.foreground.opacity(0.1)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse queue")

                queueTabs
            }
            .padding(.horizontal, Self.railMargin)
            .padding(.top, 20)
            .padding(.bottom, 14)

            if player.currentTrack != nil {
                smartContinueAndClearRow(horizontal: Self.railMargin, bottom: 10)
            }

            List {
                switch queueTab {
                case .upNext: upNextRows(inRail: true)
                case .history: playedAlreadyRows(inRail: true)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { railBackground }
    }

    /// History and Up Next as a segmented control, for the rail and for the
    /// phone's queue alike.
    private var queueTabs: some View {
        // A segmented control, as the iPad design draws it, rather than two
        // bare headings.
        RailTabs(
            selection: queueTab,
            track: colors.foreground.opacity(0.1),
            selectedFill: colors.foreground,
            selectedText: colors.background,
            unselectedText: colors.secondaryForeground,
            animation: reduceMotion ? nil : .easeInOut(duration: 0.15)
        ) { which in
            guard queueTab != which else { return }
            holdPageHeight()
            queueTab = which
        }
    }

    /// Smart continue and Clear, on a line of their own below the tabs: the switch on the left,
    /// Clear on the right.
    private func smartContinueAndClearRow(horizontal: CGFloat, bottom: CGFloat) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { player.smartContinueForThisQueue },
                set: { on in
                    // Switching it off takes back the songs it added, which can leave the list
                    // shorter than where the page is scrolled to.
                    if !on { holdPageHeight() }
                    player.smartContinueForThisQueue = on
                }
            )) {
                Text("Smart continue")
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(colors.secondaryForeground)
            }
            .toggleStyle(RailSwitchStyle(
                on: playerPalette.accent,
                off: colors.foreground.opacity(0.22),
                knob: colors.foreground,
                animation: reduceMotion ? nil : .easeInOut(duration: 0.15)
            ))
            .accessibilityHint(player.smartContinueForThisQueue
                               ? "Turns off carrying the queue on"
                               : "Turns on carrying the queue on")
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if hasSomethingToClear {
                    Button("Clear") {
                        switch queueTab {
                        case .upNext: player.clearUpNext()
                        case .history: player.clearHistory()
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Clear").hidden()
                }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(playerPalette.accent)
        }
        .padding(.horizontal, horizontal)
        .padding(.bottom, bottom)
    }

    private func toggleRail(landscape: Bool, to expanded: Bool) {
        railOpen = expanded
        if landscape {
            app.settings.queueRailExpandedLandscape = expanded
        } else {
            app.settings.queueRailExpandedPortrait = expanded
        }
    }

    @ViewBuilder
    private func playerPage(pageHeight: CGFloat, pageWidth: CGFloat) -> some View {
        ModernPlayerPage(
            layout: layout,
            palette: playerPalette,
            artwork: artworkOnScreen,
            waveform: shownWaveform,
            badge: shownBadge,
            badgeSlot: badgeSlot,
            albumYear: albumYear,
            error: player.lastError,
            pageHeight: pageHeight,
            pageWidth: pageWidth,
            isScrubbing: $isScrubbing,
            scrubTime: $scrubTime,
            onNavigate: navigate,
            onStop: requestStop,
            onSleepTimer: { showSleepTimer = true },
            lyrics: lyrics,
            onLyrics: { showLyrics = true },
            onDJ: { showDJSheet = true },
            dissolvesIntoBackground: style.usesBlurredBackground,
            // The page's own colour, not the sleeve's bottom edge.
            fadeTarget: palette.palette.background,
            safeTop: safeArea.top
        )
    }

    // MARK: Keeping the page where it is when the queue gets shorter
    //
    // The phone's queue is the end of one scrolling list. A shorter tab —
    // History with three songs under an Up Next of thirty — or Smart continue
    // being switched off and its songs taken back, made the whole list
    // shorter than where it had been scrolled to, so the page was snapped
    // back up to the top and whoever had scrolled down to the queue lost
    // their place. The list is held at the height it had instead, with blank
    // space under the short one, until that space is scrolled out of view or
    // the list is long enough to fill the page again.

    /// How far the phone's list has scrolled and how tall it is, as last
    /// reported.
    struct QueueScrollMetrics: Equatable {
        var content: CGFloat = 0
        var offset: CGFloat = 0
        var visibleBottom: CGFloat = 0
    }

    /// Called before something that can shorten the list — a tab being
    /// chosen, Smart continue being switched off: from here on the list is not
    /// allowed to be shorter than it is now.
    private func holdPageHeight() {
        // At the top a short list costs nothing: there is no position to lose.
        guard queueMetrics.offset > 1 else { return }
        pinnedContentHeight = queueMetrics.content
        // More than will be needed, so the offset is never clamped for the
        // instant before the real list is measured; `settleTail` trims it to
        // exactly what is missing as soon as it is.
        tailSpacer = queueMetrics.content
    }

    /// Keeps the blank space at exactly what the chosen tab is short by, and
    /// lets it go once nothing would move.
    private func settleTail(_ metrics: QueueScrollMetrics) {
        queueMetrics = metrics
        guard let pinned = pinnedContentHeight else {
            if tailSpacer != 0 { tailSpacer = 0 }
            return
        }
        // The list as it would be with no blank space.
        let base = metrics.content - tailSpacer
        // Scrolled up (or a long enough tab chosen) so that the blank space is
        // off the bottom of the screen: removing it moves nothing.
        if metrics.visibleBottom <= base + 0.5 {
            pinnedContentHeight = nil
            tailSpacer = 0
            return
        }
        let wanted = max(0, pinned - base)
        if abs(wanted - tailSpacer) > 0.5 { tailSpacer = wanted }
    }

    /// Which half of the queue is being looked at.
    enum QueueTab: Hashable {
        case history
        case upNext

        var title: String {
            switch self {
            case .history: "History"
            case .upNext: "Up Next"
            }
        }
    }

    /// Whether the tab being looked at has anything in it to empty. Up Next
    /// also needs `canEditQueue` — a read-only queue gets no Clear either.
    private var hasSomethingToClear: Bool {
        switch queueTab {
        case .upNext: player.canEditQueue && player.hasUpNext
        case .history: !player.history.isEmpty
        }
    }

    /// The phone's queue header: the iPad rail's tabs and its switch row, laid out the same way —
    /// the segmented control across the top, and beneath it Smart continue's switch on the left and
    /// Clear on the right.
    @ViewBuilder
    private var queueHeader: some View {
        if player.currentTrack != nil {
            VStack(spacing: 14) {
                queueTabs
                smartContinueAndClearRow(horizontal: 0, bottom: 0)
            }
            .padding(.horizontal)
            // The page above is as tall as the screen less the home indicator's strip, so
            // twenty-four points under it put the top of the tabs a few points inside the screen
            // and a sliver of them showed under the controls.
            .padding(.top, max(24, safeArea.bottom + 10))
            .padding(.bottom, 8)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
            .deleteDisabled(true)
        }
    }

    @ViewBuilder
    private func queueRating(for track: Track) -> some View {
        if app.settings.showsRatingsInQueue,
           app.settings.ratingVisibility != .hidden,
           // Quiet rows, the same as every other list of songs: with this
           // on, an unrated song shows nothing rather than five empty stars.
           // It can still be rated from its own menu.
           app.settings.showsStars(for: track.rating),
           app.provider?.capabilities.contains(.ratings) == true {
            let style = app.settings.trackRowStyle
            Group {
                if style.ratingAsNumber {
                    RatingSummaryButton(
                        track: track,
                        palette: colors,
                        font: style.durationFont,
                        showsBars: style.ratingAsBars
                    )
                } else {
                    StarRatingControl(
                        rating: track.rating,
                        style: app.settings.ratingStyle,
                        allowsHalfStars: app.provider?.capabilities.contains(.halfStarRatings) ?? false,
                        palette: colors,
                        size: 12
                    ) { newRating in
                        actions.setRating(newRating, id: track.id)
                    }
                }
            }
            // Both of these are built to sit on a row of their own and carry their own tap target
            // with them — six points of padding on the number, twenty points a star on the control.
            .frame(height: Self.queueRatingHeight)
            .clipped()
            .fixedSize()
        }
    }

    /// The height a queue row's second line already has, so a rating placed on it does not push the
    /// row taller.
    private static let queueRatingHeight: CGFloat = 18

    /// The row being swiped, and how far.
    @State private var swipe: (id: UUID, offset: CGFloat)?
    /// Where the row sat when the finger went down, and whether it is still
    /// down — so a drag that begins on an already-open row carries on from
    /// where it was rather than jumping back to nothing.
    @State private var swipeBase: CGFloat = 0
    @State private var swiping = false
    /// The row on its way off the side, and how wide its panel was when it
    /// was let go — held still at that width so the whole row travels as one
    /// piece rather than the panel growing to fill the space the words leave.
    @State private var exiting: (id: UUID, panel: CGFloat)?
    /// How far that row has got. Separate from `exiting` so the panel can be
    /// frozen first and the journey animated after.
    @State private var exitOffset: CGFloat = 0

    /// How far a swipe has to go before letting go removes the row.
    private static let swipeToRemove: CGFloat = 110
    /// Where a swipe would have come to rest, for one thrown rather than dragged.
    private static let flickToRemove: CGFloat = 170
    /// A throw still has to be a swipe. Below this it is a slip of the
    /// thumb, however fast, and nothing should happen to the queue.
    private static let flickNeedsAtLeast: CGFloat = 45
    /// Where a swipe that stopped short comes to rest, with the button open.
    private static let swipeOpen: CGFloat = 96
    /// Below this a swipe was a slip of the thumb, and the row closes.
    private static let swipeToOpen: CGFloat = 36

    private func swipeOffset(for item: QueueItem) -> CGFloat {
        swipe?.id == item.id ? swipe?.offset ?? 0 : 0
    }

    /// The red panel behind the row, uncovered as it slides.
    @ViewBuilder
    private func removePanel(for item: QueueItem) -> some View {
        // Held at the width it was let go at once the row is leaving.
        let shown = exiting?.id == item.id ? exiting?.panel ?? 0 : -swipeOffset(for: item)
        if shown > 0 {
            Button { remove(item) } label: {
                ZStack(alignment: .trailing) {
                    Color.red
                    VStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.system(size: 17))
                        Text("Remove")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .frame(width: Self.swipeOpen)
                }
                .frame(width: shown)
                .frame(maxHeight: .infinity)
                // Only ever as wide as it has been pulled: the words are laid out at their full
                // width from the first moment so they do not reflow as it opens, and what is not
                // uncovered yet is simply not drawn.
                .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from queue")
        }
    }

    /// Takes the row off the screen, and only then closes the gap.
    private func remove(_ item: QueueItem) {
        // The panel is pinned at its current width first, and only then is
        // the row sent on its way — words and panel together, as the one
        // thing the finger was pulling.
        exiting = (item.id, max(Self.swipeOpen, -swipeOffset(for: item)))
        exitOffset = 0
        withAnimation(.easeIn(duration: 0.34), completionCriteria: .removed) {
            exitOffset = -Self.swipeOffScreen
        } completion: {
            withAnimation(.snappy) { player.removeQueueItem(item) }
            exiting = nil
            exitOffset = 0
            swipe = nil
        }
    }

    /// Far enough left to clear the widest phone, and no further.
    private static let swipeOffScreen: CGFloat = 500

    /// Sideways only, and out of the way of everything else.
    private func removeSwipe(for item: QueueItem) -> some View {
        QueueRowSwipe(
            onChanged: { width in
                if !swiping {
                    swiping = true
                    swipeBase = swipe?.id == item.id ? (swipe?.offset ?? 0) : 0
                }
                swipe = (item.id, min(0, swipeBase + width))
            },
            onEnded: { _, predictedEnd in
                let base = swipeBase
                swiping = false
                let travelled = -swipeOffset(for: item)
                // Where it was going, not only where it got to.
                let thrown = -(base + predictedEnd)
                let goes = travelled >= Self.swipeToRemove
                    || (travelled >= Self.flickNeedsAtLeast && thrown >= Self.flickToRemove)
                if goes {
                    remove(item)
                } else if travelled > Self.swipeToOpen {
                    withAnimation(.snappy) { swipe = (item.id, -Self.swipeOpen) }
                } else {
                    withAnimation(.snappy) { swipe = nil }
                }
            },
            onCancelled: {
                // Back where the row stood before this drag: closed, or open
                // at its button if that is where it already was.
                let base = swipeBase
                swiping = false
                withAnimation(.snappy) {
                    swipe = base == 0 ? nil : (item.id, base)
                }
            }
        )
    }

    /// How many of the songs still to play the queue actually lists.
    private static let upNextDisplayLimit = 25

    @ViewBuilder
    private var upNext: some View { upNextRows(inRail: false) }

    /// `inRail` is the iPad rail's own arrangement of the same rows: the
    /// margins its header uses, and a hairline between rows. The phone's
    /// rows are drawn exactly as they were.
    @ViewBuilder
    private func upNextRows(inRail: Bool) -> some View {
        let items = player.upNext(limit: Self.upNextDisplayLimit)
        let beyond = player.upNextCount - items.count
        if !items.isEmpty {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    ArtworkView(artwork: player.artwork(for: item.track), size: 40)
                    // Set like a song in a tracklist, because that is what it
                    // is: the same title and artist sizes an album page uses,
                    // following the same setting.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.track.title)
                            .font(app.settings.trackRowStyle.titleFont)
                            .foregroundStyle(colors.foreground)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(item.track.artistName ?? "")
                                .font(.footnote)
                                .foregroundStyle(colors.secondaryForeground)
                                .lineLimit(1)
                                .layoutPriority(1)
                            // Provenance, not the DJ currently active — a row a DJ chose keeps its
                            // own mark even after switching to a different one, so long as it has
                            // not been played and cleaned up.
                            if let origin = item.djOrigin {
                                DJGlyph.path(for: origin)
                                    .stroke(colors.secondaryForeground, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                                    .frame(width: 10, height: 10)
                                    .accessibilityLabel("Added by \(origin.label)")
                            }
                            // Artist and rating share the second line, the rating at its right-hand
                            // end — the same arrangement an album's tracklist uses, and for the
                            // same reason.
                            Spacer(minLength: 4)
                            queueRating(for: item.track)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, app.settings.trackRowStyle.verticalPadding - 1 + (inRail ? Self.railRowExtraPadding : 0))
                .contentShape(Rectangle())
                .onTapGesture {
                    // A row standing open is asking a question; answering it
                    // with "play this" would be answering a different one.
                    if swipe != nil {
                        withAnimation(.snappy) { swipe = nil }
                    } else if player.canEditQueue {
                        player.play(item)
                    }
                }
                // Removal is a swipe, which VoiceOver cannot make: offered as
                // a named action on the row as well.
                .accessibilityActions {
                    if player.canEditQueue {
                        Button("Remove from queue") { remove(item) }
                    }
                }
                // The row's own trailing margin, given to the content rather than to the row, so
                // the panel behind it can reach the edge of the screen.
                .padding(.trailing, inRail ? Self.railMargin : 16)
                .offset(x: swipeOffset(for: item))
                .background(alignment: .trailing) { removePanel(for: item) }
                // Outside the panel rather than inside it, so this carries
                // the row and the panel off together. The offset above moves
                // only the words, which is what opening the panel is.
                .offset(x: exiting?.id == item.id ? exitOffset : 0)
                .background { if player.canEditQueue { removeSwipe(for: item) } }
                .listRowInsets(EdgeInsets(top: 0, leading: inRail ? Self.railMargin : 16, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .railRowSeparator(inRail, tint: colors.foreground.opacity(0.14), margin: Self.railMargin)
                // No delete control: removal is the swipe. A read-only queue
                // — a target that has not offered this edit — takes the drag
                // off too.
                .deleteDisabled(true)
                .moveDisabled(!player.canEditQueue)
            }
            .onMove { offsets, destination in
                guard player.canEditQueue, let currentIndex = player.currentIndex else { return }
                // Translate Up Next positions into queue positions.
                let base = currentIndex + 1
                player.moveQueueItems(
                    fromOffsets: IndexSet(offsets.map { $0 + base }),
                    toOffset: destination + base
                )
            }

            // Says what the cap is hiding rather than ending on a row that looks like the end of
            // the queue.
            if beyond > 0 {
                Text("\(beyond.formatted()) more in the queue")
                    .font(.footnote)
                    .foregroundStyle(colors.secondaryForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }

            Color.clear
                .frame(height: 28)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
        }
    }

    /// What has already been heard, newest first.
    @ViewBuilder
    private var playedAlready: some View { playedAlreadyRows(inRail: false) }

    @ViewBuilder
    private func playedAlreadyRows(inRail: Bool) -> some View {
        if player.history.isEmpty {
            Text("Nothing played yet")
                .font(.footnote)
                .foregroundStyle(colors.secondaryForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 10)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
        } else {
            ForEach(player.history) { item in
                HStack(spacing: 12) {
                    ArtworkView(artwork: player.artwork(for: item.track), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.track.title)
                            .font(app.settings.trackRowStyle.titleFont)
                            .foregroundStyle(colors.foreground)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(item.track.artistName ?? "")
                                .font(.footnote)
                                .foregroundStyle(colors.secondaryForeground)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Spacer(minLength: 4)
                            historyRating(for: item.track)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, app.settings.trackRowStyle.verticalPadding - 1 + (inRail ? Self.railRowExtraPadding : 0))
                .padding(.trailing, inRail ? Self.railMargin : 16)
                .contentShape(Rectangle())
                .onTapGesture { player.playAgain(item) }
                .listRowInsets(EdgeInsets(top: 0, leading: inRail ? Self.railMargin : 16, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .railRowSeparator(inRail, tint: colors.foreground.opacity(0.14), margin: Self.railMargin)
                .moveDisabled(true)
                .deleteDisabled(true)
            }

            Color.clear
                .frame(height: 28)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
        }
    }


    /// The stars on a history row.
    @ViewBuilder
    private func historyRating(for track: Track) -> some View {
        if app.settings.ratingVisibility != .hidden,
           app.provider?.capabilities.contains(.ratings) == true {
            StarRatingControl(
                rating: track.rating,
                style: app.settings.ratingStyle,
                allowsHalfStars: app.provider?.capabilities.contains(.halfStarRatings) ?? false,
                palette: colors,
                size: 12
            ) { newRating in
                actions.setRating(newRating, id: track.id)
            }
        }
    }

    /// Artwork, and the width everything under it lines up with.
    private static let contentWidth: CGFloat = 360

    private var artworkView: some View {
        ArtworkView(artwork: artworkOnScreen, size: Self.contentWidth, cornerRadius: 16)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = player.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal)
                .multilineTextAlignment(.center)
        }
    }

    /// What the file is on the left, how it is rated on the right, in a panel the width of the
    /// artwork above it.
    @ViewBuilder
    private var infoBox: some View {
        let stars = ratingRow
        // Present whenever it *could* hold something, rather than once the badge has arrived: a box
        // that appears a moment after the song starts pushes everything below it down, which is the
        // same first-time-only jump the seek bar used to make.
        if app.settings.showsCodecInfo || ratingsShown {
            HStack(spacing: 12) {
                if player.isBuffering, shownBadge == nil {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Buffering…")
                            .font(.caption2.monospaced())
                    }
                    .foregroundStyle(colors.secondaryForeground)
                } else {
                    codecBadgeView
                }
                Spacer(minLength: 8)
                stars
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: Self.contentWidth)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colors.foreground.opacity(0.1))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(colors.foreground.opacity(0.16), lineWidth: 0.5)
                    }
            }
        }
    }

    /// Whether the stars are shown at all — the setting and the server both
    /// have a say, and an empty box would be worse than none.
    private var ratingsShown: Bool {
        track != nil
            && app.settings.ratingVisibility.showsOnNowPlaying
            && app.provider?.capabilities.contains(.ratings) == true
    }

    // MARK: Title

    private var titleBlock: some View {
        // Artist, then track, then album — each on its own line, since two
        // long names side by side truncate each other.
        VStack(spacing: 4) {
            artistLine

            HStack(spacing: 8) {
                // Travels rather than wrapping or truncating: two lines of
                // title pushed everything below it around whenever a long one
                // came up, and an ellipsis simply hides the end.
                MarqueeText(
                    text: track?.title ?? "Nothing playing",
                    font: .title3.weight(.semibold),
                    rolls: app.settings.rollsTitle
                )
                .foregroundStyle(colors.foreground)
                if let track {
                    favouriteButton(track)
                }
            }

            albumLine
                .font(.body)
                .lineLimit(1)
        }
        // Exactly the sleeve's width, and nothing beyond it: padding on top
        // of this made the row wider than the sheet, which pushed the whole
        // page off centre.
        .frame(maxWidth: Self.contentWidth)
    }

    @ViewBuilder
    private var artistLine: some View {
        if let track, let name = track.artistName {
            let credited = actions.creditedArtists(for: track)
            if credited.count > 1 {
                Menu {
                    ForEach(credited) { artist in
                        Button(artist.name) { navigate(.artist(artist.id, name: artist.name)) }
                    }
                } label: {
                    artistText(name)
                }
            } else if let artistID = track.artistID {
                Button {
                    navigate(.artist(artistID))
                } label: {
                    artistText(name)
                }
                .buttonStyle(.plain)
            } else {
                artistText(name)
            }
        }
    }

    private func artistText(_ name: String) -> some View {
        MarqueeText(text: name, font: .title3, rolls: app.settings.rollsArtist)
            .foregroundStyle(colors.secondaryForeground)
    }

    @ViewBuilder
    private var albumLine: some View {
        if let albumID = track?.albumID, let name = track?.albumName {
            Button {
                navigate(.album(albumID))
            } label: {
                albumText(name)
            }
            .buttonStyle(.plain)
        } else if let name = track?.albumName {
            albumText(name)
        }
    }

    /// The album, with its year pinned beside it: a long title travels to
    /// show itself, and the year stays put rather than scrolling out of view.
    private func albumText(_ name: String) -> some View {
        HStack(spacing: 5) {
            MarqueeText(text: name, font: .body, rolls: app.settings.rollsAlbum)
            if let year = track?.year ?? albumYear {
                // The year holds its place; the title is what gives way and
                // travels to show itself.
                Text(verbatim: "(\(String(year)))")
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .foregroundStyle(colors.secondaryForeground)
    }

    /// How wide to hold the badge's slot, in characters.
    private var badgeSlot: Int {
        guard app.settings.showsCodecInfo else { return 0 }
        var longest = shownBadge?.count ?? 0
        guard player.currentIndex != nil else { return longest }
        // `upNext`, not `queue.dropFirst(currentIndex + 1)`: a controlled device's `queue` is
        // [current] + its Up Next window while `currentIndex` is the target's real position, so
        // dropping by it skipped that many real upcoming songs (R-23).
        for item in player.upNext(limit: Self.badgeLookahead) {
            // The prediction, not a measurement: nothing has opened these
            // files yet. It is the same answer the current track's badge
            // shows before the engine has had a look at it.
            guard let ahead = CodecBadge.playing(
                item.track,
                settings: app.settings,
                expensiveNetwork: player.streamsWithMobilePolicy
            ) else { continue }
            longest = max(longest, ahead.count)
        }
        return longest
    }

    /// How many songs ahead the slot is measured against. See `badgeSlot`
    /// for why this is small.
    private static let badgeLookahead = 2

    /// What is actually playing: the file's own format, or the conversion
    /// when the streaming policy calls for one.
    private var codecBadge: String? {
        guard app.settings.showsCodecInfo, let track else { return nil }
        // What the engine actually opened, once it has; the policy's
        // expectation only until then.
        if let format = player.playingFormat,
           let measured = CodecBadge.measured(
               format,
               track: detailedTrack ?? track,
               settings: app.settings
           ) {
            return measured
        }
        // §4.8.1: "The codec chip shows the target's badge.
        guard !app.remote.isControlling else { return nil }
        return CodecBadge.playing(
            detailedTrack ?? track,
            settings: app.settings,
            expensiveNetwork: player.streamsWithMobilePolicy
        )
    }

    @ViewBuilder
    private var codecBadgeView: some View {
        if let shownBadge {
            Text(shownBadge)
                // In the box it stands beside the stars: bigger than small
                // print, but not the stars' full height, where it started to
                // compete with them.
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(colors.secondaryForeground)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func favouriteButton(_ track: Track) -> some View {
        if app.provider?.capabilities.contains(.favorites) == true, player.canActOnLibrary {
            Button {
                actions.setFavorite(!track.isFavorite, id: track.id, kind: .track)
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(track.isFavorite ? AnyShapeStyle(.tint) : AnyShapeStyle(colors.secondaryForeground))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.isFavorite ? "Remove from favourites" : "Add to favourites")
        }
    }

    @ViewBuilder
    private var ratingRow: some View {
        if let track,
           app.settings.ratingVisibility.showsOnNowPlaying,
           player.canActOnLibrary,
           app.provider?.capabilities.contains(.ratings) == true {
            StarRatingControl(
                rating: track.rating,
                style: app.settings.ratingStyle,
                allowsHalfStars: app.provider?.capabilities.contains(.halfStarRatings) ?? false,
                palette: colors,
                // Sized for the box, where it sits beside text rather than
                // standing on a line of its own.
                size: 17,
                // Slide across them to rate, as in the tracklist popover.
                allowsDragging: true
            ) { newRating in
                actions.setRating(newRating, id: track.id)
            }
        }
    }

    // MARK: Transport

    private var scrubber: some View {
        VStack(spacing: 6) {
            ProgressScrubber(
                progress: fraction,
                samples: waveform,
                style: app.settings.progressStyle,
                palette: colors
            ) { value, isFinal in
                let total = max(player.duration ?? 0, 0.001)
                scrubTime = value * total
                isScrubbing = !isFinal
                if isFinal { player.seek(to: scrubTime) }
            }
            .accessibilityLabel("Playback position")
            // A new track is a new bar, not the old one running backwards.
            .id("\(track?.id.rawValue ?? "none")-\(player.positionJumps)")
            HStack {
                Text(timeText(isScrubbing ? scrubTime : player.currentTime))
                Spacer(minLength: 8)
                Spacer(minLength: 8)
                // Tap to switch between the track's length and what is left
                // of it.
                Text(trailingTimeText)
                    .contentShape(Rectangle())
                    .onTapGesture { app.settings.showsRemainingTime.toggle() }
                    .accessibilityLabel(app.settings.showsRemainingTime ? "Time remaining" : "Track length")
                    .accessibilityHint("Switches between length and time remaining")
            }
            // Big enough to read at a glance from arm's length; they are the
            // one thing on this screen you look at while doing something else.
            .font(.subheadline)
            .foregroundStyle(colors.secondaryForeground)
            .monospacedDigit()
        }
        .frame(maxWidth: Self.contentWidth)
    }

    private var trailingTimeText: String {
        let total = player.duration ?? 0
        guard app.settings.showsRemainingTime else { return timeText(total) }
        let elapsed = isScrubbing ? scrubTime : player.currentTime
        return "-" + timeText(max(total - elapsed, 0))
    }

    private var fraction: Double {
        let total = player.duration ?? 0
        guard total > 0 else { return 0 }
        return (isScrubbing ? scrubTime : player.currentTime) / total
    }

    private func toggleGlyph(_ symbol: String, isOn: Bool) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(isOn ? AnyShapeStyle(playerPalette.buttonGlyph) : AnyShapeStyle(colors.secondaryForeground))
            .frame(width: 34, height: 34)
            .background {
                if isOn {
                    Circle().fill(playerPalette.accent)
                }
            }
    }

    private var secondaryControls: some View {
        HStack(spacing: 24) {
            Button {
                player.toggleShuffle()
            } label: {
                toggleGlyph("shuffle", isOn: player.isShuffled)
            }
            .accessibilityLabel(player.isShuffled ? "Stop shuffling" : "Shuffle")

            Button {
                player.cycleRepeatMode()
            } label: {
                toggleGlyph(player.repeatMode.symbolName, isOn: player.repeatMode.isOn)
            }
            .accessibilityLabel(player.repeatMode.label)

            Button {
                app.openDJ { showDJSheet = true }
            } label: {
                Image("DJTurntable")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(app.dj?.active != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(colors.secondaryForeground))
            }
            .accessibilityLabel(app.dj?.active.map { "DJ: \($0.label) is on" } ?? "DJ")

            RoutePickerView(tint: colors.secondaryForeground)
                .frame(width: 32, height: 32)
                .accessibilityLabel("Audio output")

            // Held behind `Equatable` for the reason set out in `PlayerOverflowMenu`: this body
            // runs twice a second while anything is playing, and an inline menu would be rebuilt
            // under the finger every time it did.
            PlayerOverflowMenu(
                track: track,
                hasLyrics: lyrics != nil,
                isSleepTimerActive: player.isSleepTimerActive,
                hasUpNext: player.hasUpNext,
                // The classic screen has the heart on the page itself, so
                // it is not repeated here.
                canFavorite: false,
                canStartRadio: app.provider?.capabilities.contains(.similarItems) == true && player.canActOnLibrary,
                canAddToPlaylist: app.provider?.capabilities.contains(.playlists) == true && player.canActOnLibrary,
                mixName: app.remote.isControlling ? nil : player.queueOrigin.radioName,
                remoteDeviceName: app.remote.controlledDeviceName,
                glyph: .circled(colors.secondaryForeground),
                credited: track.map { actions.creditedArtists(for: $0) } ?? [],
                onLyrics: { showLyrics = true },
                onSleepTimer: { showSleepTimer = true },
                onToggleFavorite: { _ in },
                onStartRadio: { actions.startRadio(from: $0) },
                onAddToPlaylist: { app.requestAddToPlaylist([$0]) },
                onSaveMix: {
                    guard let name = player.queueOrigin.radioName else { return }
                    app.requestAddToPlaylist(
                        player.queue.map(\.track),
                        suggesting: MediaActions.playlistName(for: name)
                    )
                },
                onNavigate: { navigate($0) },
                onClearUpNext: { player.clearUpNext() },
                onStop: {
                    if app.settings.confirmsStopAndClear {
                        confirmingStop = true
                    } else {
                        stopAndDismiss()
                    }
                },
                onDisconnect: { app.remote.disconnect() }
            )
            .equatable()
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    // MARK: Navigation

    /// Hands the destination to the root, which dismisses this sheet and pushes onto the tab
    /// underneath.
    private func holdForTheSleeve() async {
        guard let artwork = track?.artwork,
              let loader = app.artwork
        else { return }
        // The size both artwork-led layouts ask for: the bleeding sleeve
        // names it outright, and the framed square rounds up to it on every
        // iPhone the app runs on.
        _ = await loader.image(for: artwork, bucket: 1200)
    }

    private func navigate(_ request: AppModel.NavigationRequest) {
        app.requestNavigation(request)
        // See the identical wrapping, and why, in `stopAndDismiss()`.
        withAnimation { onClose() }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.isFinite ? min(max(0, seconds), 1_000_000) : 0).formatted(.time(pattern: .minuteSecond))
    }
}

/// AirPlay / output picker.
struct RoutePickerView: UIViewRepresentable {
    var tint: Color = .secondary

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor(tint)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // Guarded rather than assigned outright: SwiftUI calls this on every update to the page it
        // sits on, which on Now Playing is twice a second for as long as anything is playing, and
        // the tint almost never differs between two of them.
        let color = UIColor(tint)
        guard uiView.tintColor != color else { return }
        uiView.tintColor = color
    }
}

private extension View {
    /// A queue row's hairline, drawn only in the iPad rail.
    func railRowSeparator(_ inRail: Bool, tint: Color, margin: CGFloat) -> some View {
        self
            .listRowSeparator(inRail ? .visible : .hidden, edges: inRail ? .bottom : .all)
            .listRowSeparatorTint(tint)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] - (inRail ? margin : 0) }
    }
}

/// The rail's Smart-continue switch: a small capsule with a round knob and its label beside it, in
/// the artwork's own colours.
private struct RailSwitchStyle: ToggleStyle {
    let on: Color
    let off: Color
    let knob: Color
    let animation: Animation?

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(animation) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? on : off)
                    Circle().fill(knob).padding(2)
                }
                .frame(width: 28, height: 17)
                configuration.label
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// History and Up Next as the iPad rail's segmented control: a rounded track with the chosen half
/// lifted onto a light pill, the way the design draws it.
private struct RailTabs: View {
    let selection: NowPlayingView.QueueTab
    let track: Color
    let selectedFill: Color
    let selectedText: Color
    let unselectedText: Color
    let animation: Animation?
    let onSelect: (NowPlayingView.QueueTab) -> Void

    @Namespace private var pill

    private static let height: CGFloat = 40
    private static let inset: CGFloat = 3
    private static let radius: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            segment(.history)
            segment(.upNext)
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(track)
        }
    }

    private func segment(_ which: NowPlayingView.QueueTab) -> some View {
        let selected = selection == which
        return Text(which.title)
            .font(.subheadline.weight(.semibold))
            // Never wrapped: two labels and a chevron share one narrow row.
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(selected ? selectedText : unselectedText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Self.radius - Self.inset, style: .continuous)
                        .fill(selectedFill)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation(animation) { onSelect(which) } }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The collapsed queue tab's label, reading bottom to top.
private struct RotatedRailLabel: View {
    let text: String
    let color: Color

    @State private var unrotatedSize: CGSize = .zero

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(1)
            .foregroundStyle(color)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { unrotatedSize = $0 }
            .rotationEffect(.degrees(90))
            .frame(width: unrotatedSize.height, height: unrotatedSize.width)
    }
}
