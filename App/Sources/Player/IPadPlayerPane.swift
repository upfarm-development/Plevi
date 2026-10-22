import SwiftUI
import PleviDomain

/// The iPad player pane: artwork, names, seek bar and transport, standing beside a queue rail
/// (`NowPlayingView.queueRail`) instead of scrolling above one long list the way `ModernPlayerPage`
/// does on iPhone.
struct IPadPlayerPane: View {
    let palette: PlayerPalette
    let artwork: ArtworkID?
    let waveform: [Float]?
    let badge: String?
    var badgeSlot: Int = 0
    let albumYear: Int?
    let error: String?
    /// The window's own shape, not the device's — a Stage Manager pane lying on its side gets this
    /// arrangement even on an iPad held upright, matching `PageMetrics.isOnItsSide` everywhere else
    /// this question is asked.
    let isLandscape: Bool
    /// Whether the rail beside this pane is open — the artwork is allowed
    /// noticeably more room when it is not, which is the only reason this
    /// pane needs to know about the rail at all.
    let railExpanded: Bool
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    let onNavigate: (AppModel.NavigationRequest) -> Void
    /// Long-pressing the play button. The screen above decides whether that
    /// asks first.
    let onStop: () -> Void
    let onSleepTimer: () -> Void
    let lyrics: Lyrics?
    let onLyrics: () -> Void
    let onDJ: () -> Void
    /// The corner button's action — the one thing this pane has that
    /// `ModernPlayerPage` does not, since iPhone has no room for a rail to
    /// need disambiguating from and gets by on the drag alone.
    let onClose: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the metadata block and the controls block actually measured at, so the artwork gets
    /// exactly what they leave over rather than an estimate — the same technique `ModernPlayerPage`
    /// measures `wordsHeight`/`controlsHeight` with, and for the…
    @State private var metadataSize: CGSize?
    @State private var controlsSize: CGSize?
    /// Resolved once per track rather than in both `artistLine` and the overflow menu — `body`
    /// re-runs roughly twice a second while playing, and this is a synchronous SQLite read the two
    /// used to each make on their own.
    @State private var creditedArtists: [Artist] = []
    @State private var showingDevicePicker = false
    /// Whether the player has finished rising into place.
    @State private var hasRisen = false
    /// The shape as it was on this card's first frame; see `ProgressScrubber.samples`.
    @State private var openingShape = FirstValue<[Float]>()
    /// `positionJumps` as the card opened, so the seek bar keeps one identity
    /// until it has landed. See where it is used.
    @State private var jumpsWhenOpened: Int?

    private var player: any PlaybackControlling { app.activePlayer }
    private var track: Track? { player.currentTrack }
    private var actions: MediaActions { MediaActions(app: app) }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                topBar
                if isLandscape {
                    landscapeMiddle(paneSize: proxy.size)
                } else {
                    portraitMiddle(paneSize: proxy.size)
                    // Anchored to the seek bar rather than following the
                    // sleeve: opening or folding the rail changes how big
                    // the artwork is and nothing else on this screen.
                    portraitMetadata
                        .padding(.horizontal, Self.sidePadding)
                        .padding(.bottom, Self.metadataToSeekBarGap)
                }
                bottomBlock
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            // Everything on this page moves to its place together when the rail opens or folds.
            .animation(reduceMotion ? nil : Self.artworkSpring, value: railExpanded)
        }
        .task(id: track?.id) {
            creditedArtists = track.map { actions.creditedArtists(for: $0) } ?? []
        }
        .task {
            jumpsWhenOpened = player.positionJumps
            // Long enough for the spring in `RootView.RisesFromBelow`
            // (response 0.42) to have come to rest.
            try? await Task.sleep(for: .milliseconds(800))
            hasRisen = true
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            closeButton
            Spacer(minLength: 0)
            if app.remote.isControlling || app.remote.isReconnecting {
                deviceLine
            }
        }
        .padding(.horizontal, Self.sidePadding)
        .padding(.top, 8)
    }

    /// On the top bar's empty trailing side —
    /// see `ModernPlayerPage.deviceLine`'s own comment for what this still
    /// leaves out ("Also controlled from Alice's iPad").
    private var deviceLine: some View {
        let name = app.remote.controlledDeviceName ?? "another device"
        let text = app.remote.isReconnecting
            ? "Reconnecting to \(app.remote.lastControlledDeviceName ?? name)…"
            : player.currentTrack != nil ? "Playing on \(name)" : "Connected to \(name)"
        return DeviceLine(text: text, style: .capsule) { showingDevicePicker = true }
            .popover(isPresented: $showingDevicePicker) {
                DevicePicker(
                    rows: app.remote.pickerRows,
                    showAirPlayRow: false,
                    volume: app.remote.controlledPlayer?.offeredVolume,
                    footer: app.remote.lastError,
                    onSelect: { app.remote.selectDeviceRow(id: $0) },
                    onChangeVolume: { app.remote.controlledPlayer?.setOfferedVolume($0) })
                    .equatable()
            }
    }

    /// New for iPad: nothing on today's screen closes it except the drag, and a rail that can
    /// itself scroll needs a way to close the whole thing that does not have to guess which of two
    /// regions the drag belongs to.
    private var closeButton: some View {
        Button {
            withAnimation { onClose() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.text.opacity(0.7))
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(palette.text.opacity(0.1))
                        .frame(width: 34, height: 34)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    // MARK: Landscape

    private func landscapeMiddle(paneSize: CGSize) -> some View {
        let side = landscapeArtworkSide(paneSize: paneSize)
        return HStack(alignment: .bottom, spacing: Self.artworkGutter) {
            artworkView(side: side)
            landscapeMetadata
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Self.sidePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bounded by whatever the top bar and the measured controls block leave over, and separately
    /// by the width left once the metadata gets its own minimum column — whichever is tighter.
    private func landscapeArtworkSide(paneSize: CGSize) -> CGFloat {
        let reserved = Self.topBarHeight
            + (controlsSize?.height ?? Self.estimatedControlsHeight)
            + Self.middleGap * 2
        let heightBound = paneSize.height - reserved
        let widthBound = paneSize.width - Self.sidePadding * 2 - Self.artworkGutter - Self.landscapeMetadataMinWidth
        let cap = railExpanded ? Self.maxArtworkSideLandscapeExpanded : Self.maxArtworkSideLandscapeCollapsed
        return max(Self.minArtworkSide, min(heightBound, widthBound, cap))
    }

    /// Title, artist, album, then the rating and the badge beneath the album line rather than
    /// beside it — the album line runs the full width of the column this way, and never wraps
    /// fighting the badge for room.
    private var landscapeMetadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            artistLine
            albumLine
            HStack(spacing: 14) {
                ratingRow
                badgeView
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            errorView
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { metadataSize = $0 }
    }

    // MARK: Portrait

    /// The sleeve, centred both ways in whatever the top bar and the metadata block leave between
    /// them — equal space above and below, so it sits optically in the middle of the screen rather
    /// than hard against either neighbour.
    private func portraitMiddle(paneSize: CGSize) -> some View {
        artworkView(side: portraitArtworkSide(paneSize: paneSize))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Height-bound by what the top bar, the metadata block and the controls block leave over, less
    /// the room it keeps clear above and below itself — capped by width too, since a narrow
    /// portrait Stage Manager pane should not hand a square more…
    private func portraitArtworkSide(paneSize: CGSize) -> CGFloat {
        let reserved = Self.topBarHeight
            + Self.middleGap * 2
            + (metadataSize?.height ?? Self.estimatedMetadataHeight)
            + Self.metadataToSeekBarGap
            + (controlsSize?.height ?? Self.estimatedControlsHeight)
        let heightBound = paneSize.height - reserved
        let widthBound = paneSize.width - Self.sidePadding * 2
        let cap = railExpanded ? Self.maxArtworkSidePortraitExpanded : Self.maxArtworkSidePortraitCollapsed
        return max(Self.minArtworkSide, min(heightBound, widthBound, cap))
    }

    /// Left-aligned names, with the rating stacked over the badge on the trailing edge,
    /// bottom-aligned with the artist and album lines they stand beside — the title above has the
    /// whole width to itself, and there is no spare width under it to give…
    private var portraitMetadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    artistLine
                    albumLine
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    ratingRow
                    badgeView
                }
            }
            errorView
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { metadataSize = $0 }
    }

    // MARK: Artwork

    /// The existing framed sleeve's own corner and shadow — see
    /// `ModernPlayerPage.framedHeader` — at whatever size this pane works
    /// out it can afford.
    private func artworkView(side: CGFloat) -> some View {
        // Asked for at the largest this pane can ever draw it, not at `side`.
        ArtworkView(
            artwork: artwork, size: side, cornerRadius: Self.artworkCorner,
            requestSize: Self.maxArtworkSidePortraitCollapsed
        )
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
            .accessibilityHidden(true)
            .animation(reduceMotion ? nil : Self.artworkSpring, value: side)
    }

    // MARK: Words

    private var title: some View {
        MarqueeText(
            text: track?.title ?? "Nothing playing",
            font: .system(size: 40, weight: .bold),
            rolls: app.settings.rollsTitle,
            fillsWidth: true
        )
        // -2% of the point size, the same proportion the album and artist
        // pages' own wide headers use at their 40-point title.
        .tracking(-0.8)
        .foregroundStyle(palette.primaryText)
    }

    @ViewBuilder
    private var artistLine: some View {
        if let track, let name = track.artistName {
            let text = MarqueeText(text: name, font: .system(size: 20), rolls: app.settings.rollsArtist)
                .foregroundStyle(palette.secondaryText)
            if hasRisen, creditedArtists.count > 1 {
                Menu {
                    ForEach(creditedArtists) { artist in
                        Button(artist.name) { onNavigate(.artist(artist.id, name: artist.name)) }
                    }
                } label: { text }
            } else if let artistID = track.artistID {
                Button { onNavigate(.artist(artistID)) } label: { text }
                    .buttonStyle(.plain)
            } else {
                text
            }
        }
    }

    /// Album and year on one line, the year pinned so a long title travels
    /// without carrying it out of view — see `ModernPlayerPage.albumLine`.
    @ViewBuilder
    private var albumLine: some View {
        if let name = track?.albumName {
            let line = HStack(spacing: 6) {
                MarqueeText(text: name, font: .system(size: 16), rolls: app.settings.rollsAlbum)
                if let year = track?.year ?? albumYear {
                    Text(verbatim: "· \(String(year))")
                        .font(.system(size: 16))
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(palette.tertiaryText)

            if let albumID = track?.albumID {
                Button { onNavigate(.album(albumID)) } label: { line }
                    .buttonStyle(.plain)
            } else {
                line
            }
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let error {
            Text(error)
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .lineLimit(2)
                .padding(.top, 4)
        }
    }

    /// The codec chip, in a slot as wide as the longest badge coming up —
    /// see `ModernPlayerPage.badgeChip` for why it is measured rather than
    /// fixed.
    @ViewBuilder
    private var badgeView: some View {
        if player.isBuffering, badge == nil {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Buffering…")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(palette.tertiaryText)
        } else if let badge {
            ZStack(alignment: .leading) {
                Text(String(repeating: "0", count: badgeSlot))
                    .font(.system(size: 12, design: .monospaced))
                    .kerning(0.5)
                    .padding(.horizontal, 9)
                    .hidden()

                Text(badge.uppercased())
                    .font(.system(size: 12, design: .monospaced))
                    .kerning(0.5)
                    .foregroundStyle(palette.tertiaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(palette.text.opacity(0.22), lineWidth: 1)
                    }
            }
            .animation(nil, value: badge)
            .animation(nil, value: badgeSlot)
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
                palette: palette.asArtworkPalette(),
                size: 16,
                allowsDragging: true
            ) { newRating in
                actions.setRating(newRating, id: track.id)
            }
            // Spelled out for VoiceOver here rather than in the shared control, which every list
            // row in the app also draws from and has always read the shorter "3.5 stars" way —
            // changing that is a bigger change than this screen asked for.
            .accessibilityLabel("Rating")
            .accessibilityValue(spokenRating(track.rating))
        }
    }

    private func spokenRating(_ rating: StarRating?) -> String {
        guard let rating, rating.value > 0 else { return "Not rated" }
        let whole = Int(rating.value)
        let hasHalf = rating.value - Double(whole) >= 0.5
        let quantity = hasHalf ? "\(whole) and a half" : "\(whole)"
        return "Rated \(quantity) out of 5"
    }

    // MARK: Bottom block — seek bar, transport, utility row

    /// Everything a thumb reaches for, capped and centred as a cluster rather than stretched to the
    /// pane's own width — a bigger screen's buttons, not a slab; see `PageMetrics.actionRowWidth`
    /// for the same reasoning applied to Play and Shuffle on…
    private var bottomBlock: some View {
        VStack(spacing: 0) {
            scrubber
            Spacer(minLength: 0).frame(height: 22)
            transport
                .frame(maxWidth: Self.controlsMaxWidth)
            if let volume = player.offeredVolume {
                Spacer(minLength: 0).frame(height: 16)
                RemoteVolumeRow(volume: volume) { player.setOfferedVolume($0) }
                    .frame(maxWidth: Self.controlsMaxWidth)
            }
            Spacer(minLength: 0).frame(height: 16)
            utilityRow
        }
        .padding(.horizontal, Self.sidePadding)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { controlsSize = $0 }
    }

    /// The played part is always the accent here, the same rule the framed
    /// iPhone screen already follows — `tintsProgressLikeStars` only ever
    /// changes anything on the *bleeding* screen, which iPad never shows.
    private var scrubber: some View {
        VStack(spacing: 8) {
            ProgressScrubber(
                progress: PlayerTimeDisplay.fraction(player: player, isScrubbing: isScrubbing, scrubTime: scrubTime),
                samples: ProgressScrubber.samples(waveform, atOpening: openingShape.value(waveform), style: app.settings.progressStyle, hasRisen: hasRisen),
                style: app.settings.progressStyle,
                animates: hasRisen,
                palette: palette.asArtworkPalette(foreground: palette.accent)
            ) { value, isFinal in
                let total = max(player.duration ?? 0, 0.001)
                scrubTime = value * total
                isScrubbing = !isFinal
                if isFinal { player.seek(to: scrubTime) }
            }
            .accessibilityLabel("Playback position")
            // Not replaced while the card is still rising: a seek that lands then — a restored
            // session finding its place — would swap the bar for a new one, and the new one is
            // drawn where it finishes instead of travelling with everything else.
            .id("\(track?.id.rawValue ?? "none")-\(hasRisen ? player.positionJumps : (jumpsWhenOpened ?? player.positionJumps))")

            HStack {
                Text(PlayerTimeDisplay.text(isScrubbing ? scrubTime : player.currentTime))
                Spacer(minLength: 8)
                Text(
                    PlayerTimeDisplay.trailingTimeText(
                        player: player,
                        showsRemainingTime: app.settings.showsRemainingTime,
                        isScrubbing: isScrubbing,
                        scrubTime: scrubTime
                    )
                )
                    .contentShape(.rect)
                    .onTapGesture { app.settings.showsRemainingTime.toggle() }
                    .accessibilityLabel(app.settings.showsRemainingTime ? "Time remaining" : "Track length")
                    .accessibilityHint("Switches between length and time remaining")
            }
            .font(.system(size: 14))
            .monospacedDigit()
            .foregroundStyle(palette.tertiaryText)
        }
    }

    /// See `PlayerTransportRow`, shared with `ModernPlayerPage` — capped to
    /// `controlsMaxWidth` by the caller instead of pinned to the sleeve's
    /// own edges.
    private var transport: some View {
        PlayerTransportRow(palette: palette, player: player, onStop: onStop)
    }

    /// Centred as a cluster of three rather than left-anchored — the same
    /// `PlayerUtilityGlyphs` `ModernPlayerPage.utilityRow` draws, just given
    /// the middle of a wider row instead of its leading edge.
    private var utilityRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            PlayerUtilityGlyphs(
                app: app,
                palette: palette,
                track: track,
                lyrics: lyrics,
                credited: creditedArtists,
                routeNameFallback: "iPad",
                onDJ: onDJ,
                onLyrics: onLyrics,
                onSleepTimer: onSleepTimer,
                onNavigate: onNavigate,
                onStop: onStop
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: Measurements

    // Not `private`: `NowPlayingView.landscapePaneMinimum` adds this pane's
    // own margins, gutter and two stated minimums together to know how
    // narrow a window can go before this pane is crushed — see there.
    static let sidePadding: CGFloat = 40
    private static let topBarHeight: CGFloat = 52
    private static let artworkCorner: CGFloat = 18
    static let artworkGutter: CGFloat = 40
    static let landscapeMetadataMinWidth: CGFloat = 280
    static let minArtworkSide: CGFloat = 160
    /// Ceilings the sleeve is otherwise free to grow to, one pair per orientation — collapsing the
    /// rail hands this pane real room, and the artwork is meant to visibly answer that rather than
    /// stop at whatever looked right with the rail open.
    private static let maxArtworkSideLandscapeExpanded: CGFloat = 340
    private static let maxArtworkSideLandscapeCollapsed: CGFloat = 460
    private static let maxArtworkSidePortraitExpanded: CGFloat = 480
    private static let maxArtworkSidePortraitCollapsed: CGFloat = 620
    private static let controlsMaxWidth: CGFloat = 700
    private static let middleGap: CGFloat = 24
    /// The fixed gap between the metadata block and the seek bar under it in
    /// portrait. It is a constant, not a `Spacer`, because the block is meant
    /// to sit on the seek bar — the artwork is what flexes.
    private static let metadataToSeekBarGap: CGFloat = 24
    /// What the controls block is assumed to be tall before its first
    /// measurement lands — seek bar and times, transport, utility row.
    private static let estimatedControlsHeight: CGFloat = 190
    /// What the metadata block is assumed to be tall before its first
    /// measurement lands — the title, then the artist and album lines with
    /// the rating and badge stacked beside them.
    private static let estimatedMetadataHeight: CGFloat = 120
    private static let artworkSpring = Animation.spring(response: 0.42, dampingFraction: 0.88)

}
