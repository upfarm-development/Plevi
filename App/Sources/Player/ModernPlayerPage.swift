import SwiftUI
import PleviDomain

/// The two artwork-led playing screens: `Framed` and `Bleed`.
struct ModernPlayerPage: View {
    let layout: NowPlayingLayout
    let palette: PlayerPalette
    /// The sleeve to draw, which the page above holds back until the colour taken from it is ready
    /// — so the picture and the page change together rather than one chasing the other.
    let artwork: ArtworkID?
    let waveform: [Float]?
    /// The codec chip's text, already settled by the screen above so it does
    /// not empty and refill between two identical files.
    let badge: String?
    /// How many characters wide to hold the badge's slot — see
    /// `NowPlayingView.badgeSlot`, which works it out from what is actually
    /// coming up rather than from what the app could theoretically spell.
    var badgeSlot: Int = 0
    /// Plex keeps the year on the album, so the screen above looks it up.
    let albumYear: Int?
    /// Whatever went wrong last, if anything did.
    let error: String?
    let pageHeight: CGFloat
    let pageWidth: CGFloat
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    let onNavigate: (AppModel.NavigationRequest) -> Void
    /// Long-pressing the play button. The screen above decides whether that
    /// asks first.
    let onStop: () -> Void
    let onSleepTimer: () -> Void
    /// The words, when the server has them for this song. Nil takes the
    /// button away rather than dimming it: a glyph that is present but never
    /// works reads as broken, and most songs have no lyrics on most servers.
    let lyrics: Lyrics?
    let onLyrics: () -> Void
    let onDJ: () -> Void
    /// Whether the page behind is the blurred artwork rather than one colour,
    /// which decides how the bleeding sleeve is allowed to end.
    let dissolvesIntoBackground: Bool
    /// The colour it fades into when it is one colour: the artwork's own
    /// bottom edge where that is known, so the join shows no seam.
    let fadeTarget: Color
    /// The status bar's height, for the bleeding layout only: there the sleeve
    /// runs under it, and anything laid over the sleeve has to start below.
    var safeTop: CGFloat = 0

    @Environment(AppModel.self) private var app

    /// What the two blocks under the sleeve came to when they were last laid
    /// out. Nil until the first pass, which is what the estimates are for.
    @State private var wordsHeight: CGFloat?
    @State private var controlsHeight: CGFloat?
    /// Resolved once per track rather than in both `artistLine` and the overflow menu — `body`
    /// re-runs roughly twice a second while playing, and this is a synchronous SQLite read the two
    /// used to each make on their own.
    @State private var creditedArtists: [Artist] = []
    @State private var showingDevicePicker = false
    /// Whether the player has finished rising into place.
    @State private var hasRisen = false
    /// `positionJumps` as the card opened, so the seek bar keeps one identity
    /// until it has landed. See where it is used.
    @State private var jumpsWhenOpened: Int?

    private var player: any PlaybackControlling { app.activePlayer }
    private var track: Track? { player.currentTrack }
    private var actions: MediaActions { MediaActions(app: app) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .overlay(alignment: .topTrailing) { deviceCapsule }
            // Small, because the picture no longer stops well short of its
            // own foot: the fade now finishes a hair above the words.
            Spacer(minLength: 0).frame(height: gaps.underArtwork)
            words
            // The one flexible gap.
            Spacer(minLength: gaps.breathing)
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The names, and what the file is: everything between the sleeve and the flexible gap.
    private var words: some View {
        // Leading, not the default centre.
        VStack(alignment: .leading, spacing: 0) {
            metadata
            Spacer(minLength: 0).frame(height: gaps.betweenWords)
            technicalRow
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { record($0, into: $wordsHeight) }
    }

    /// Everything a thumb reaches for, measured for the same reason.
    private var controls: some View {
        VStack(spacing: 0) {
            scrubber
            Spacer(minLength: 0).frame(height: gaps.aboveTransport)
            transport
            if let volume = player.offeredVolume {
                Spacer(minLength: 0).frame(height: Self.volumeRowGap)
                // In the page's own margins, like every other row on it, and slim: it ran the width
                // of the screen, speaker glyphs cut off at its edges, and every point of height it
                // took pushed the glyph row further down.
                RemoteVolumeRow(volume: volume) { player.setOfferedVolume($0) }
                    .padding(.horizontal, Self.sidePadding)
            }
            Spacer(minLength: 0).frame(height: gaps.aboveUtility)
            utilityRow
            Spacer(minLength: 0).frame(height: gaps.underUtility)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { record($0, into: $controlsHeight) }
    }

    /// "It says where you are, in words the button has no room for."
    /// "Also controlled from Alice's iPad" isn't added yet — that needs `RemoteState.controllers`,
    /// which `TargetSession` doesn't populate (cross-session…
    @ViewBuilder
    private var deviceCapsule: some View {
        if app.remote.isControlling || app.remote.isReconnecting {
            let name = app.remote.controlledDeviceName ?? "another device"
            let text = app.remote.isReconnecting
                ? "Reconnecting to \(app.remote.lastControlledDeviceName ?? name)…"
                : player.currentTrack != nil ? "Playing on \(name)" : "Connected to \(name)"
            DeviceLine(text: text, style: .capsule) { showingDevicePicker = true }
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
                // Inside the corner of the framed square, or of the screen
                // below the status bar where the sleeve bleeds.
                .padding(.top, layout == .bleed ? safeTop + 8 : framedTopGap + 10)
                .padding(.trailing, layout == .bleed ? 16 : (pageWidth - framedSide) / 2 + 10)
        }
    }

    /// Keeps a measurement, but only one taken at the width the block will actually be.
    private func record(_ size: CGSize, into height: Binding<CGFloat?>) {
        guard size.width > pageWidth * 0.9 else { return }
        height.wrappedValue = size.height
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        switch layout {
        case .bleed: bleedHeader
        default: framedHeader
        }
    }

    /// The sleeve as a framed square.
    private var framedHeader: some View {
        let side = framedSide
        return VStack(spacing: 0) {
            Color.clear.frame(height: framedTopGap)
            // Pinned rather than asked for at `side`: on iPad this header also renders in a
            // resizable Split View or Stage Manager window, where `side` moves with
            // `pageWidth`/`pageHeight` and can cross a bucket boundary mid-resize — see…
            ArtworkView(artwork: artwork, size: side, cornerRadius: 18, requestSize: 1200)
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
        }
        .frame(maxWidth: .infinity)
    }

    /// The sleeve full width, dissolving into the page.
    private var bleedHeader: some View {
        BleedArtworkHeader(
            artwork: artwork,
            fallback: palette.ground,
            dissolvesIntoBackground: dissolvesIntoBackground,
            fadeTarget: fadeTarget,
            width: pageWidth,
            height: artworkHeight
        )
    }

    // MARK: Words

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            MarqueeText(
                text: track?.title ?? "Nothing playing",
                font: .system(size: layout == .bleed ? 32 : 30, weight: .bold),
                rolls: app.settings.rollsTitle,
                // Alone on its line, and the one line that should run the
                // full width of the sleeve: measured from its own truncated
                // copy it stopped twenty points short of the edge.
                fillsWidth: true
            )
            .tracking(-0.95)
            .foregroundStyle(palette.primaryText)

            artistLine
            albumLine

            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.sidePadding)
    }

    @ViewBuilder
    private var artistLine: some View {
        if let track, let name = track.artistName {
            let text = MarqueeText(text: name, font: .system(size: 17), rolls: app.settings.rollsArtist)
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

    /// Album and year on one line, with a middle dot between them — and the
    /// year pinned, so a long album title travels without taking the year
    /// out of view with it.
    @ViewBuilder
    private var albumLine: some View {
        if let name = track?.albumName {
            let line = HStack(spacing: 5) {
                MarqueeText(text: name, font: .system(size: 14), rolls: app.settings.rollsAlbum)
                if let year = track?.year ?? albumYear {
                    Text(verbatim: "· \(String(year))")
                        .font(.system(size: 14))
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

    /// What the file is, and what it is worth: the chip and then the stars, on one line under the
    /// names.
    private var technicalRow: some View {
        HStack(spacing: 12) {
            if player.isBuffering, badge == nil {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Buffering…")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.tertiaryText)
            } else if let badge {
                badgeChip(badge)
            }

            ratingRow

            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .padding(.horizontal, Self.sidePadding)
        // Nothing on this line glides. What movement is left — a chip
        // appearing where there was none — should simply be there on the next
        // frame rather than travelling into place.
        .animation(nil, value: badge)
        .animation(nil, value: badgeSlot)
    }

    /// The chip, in a slot as wide as the longest badge coming up.
    private func badgeChip(_ badge: String) -> some View {
        ZStack(alignment: .leading) {
            Text(String(repeating: "0", count: badgeSlot))
                .font(.system(size: 10, design: .monospaced))
                .kerning(0.5)
                .padding(.horizontal, 8)
                .hidden()

            Text(badge.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .kerning(0.5)
                .foregroundStyle(palette.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(palette.text.opacity(0.22), lineWidth: 1)
                }
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
                size: 13,
                allowsDragging: true
            ) { newRating in
                actions.setRating(newRating, id: track.id)
            }
        }
    }

    // MARK: Transport

    /// The played part is drawn in the accent on the framed screen and in the text colour on the
    /// bleeding one: over a picture that runs to the edges the accent is one more colour competing
    /// with the cover, while white simply reads as the page's…
    private var scrubber: some View {
        VStack(spacing: 6) {
            ProgressScrubber(
                progress: PlayerTimeDisplay.fraction(player: player, isScrubbing: isScrubbing, scrubTime: scrubTime),
                samples: waveform,
                style: app.settings.progressStyle,
                palette: palette.asArtworkPalette(
                    foreground: layout == .bleed && !app.settings.tintsProgressLikeStars
                        ? palette.text
                        : palette.accent
                )
            ) { value, isFinal in
                let total = max(player.duration ?? 0, 0.001)
                scrubTime = value * total
                isScrubbing = !isFinal
                if isFinal { player.seek(to: scrubTime) }
            }
            .accessibilityLabel("Playback position")
            // A new track is a new bar; see the classic screen.
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
            .font(.system(size: 13))
            .monospacedDigit()
            // The same quiet as the album line and the chip, rather than a
            // shade of its own a hair away from it.
            .foregroundStyle(palette.tertiaryText)
        }
        .padding(.horizontal, Self.sidePadding)
    }

    /// See `PlayerTransportRow`, shared with `IPadPlayerPane`.
    private var transport: some View {
        PlayerTransportRow(palette: palette, player: player, onStop: onStop)
            .padding(.horizontal, Self.sidePadding)
    }

    // MARK: Utility

    /// Together in the middle, rather than one at each edge: they are a set — which DJ is running,
    /// where the sound goes, everything else — and spread across the full width they read as
    /// unrelated buttons that happen to share a line.
    private var utilityRow: some View {
        HStack(spacing: 10) {
            PlayerUtilityGlyphs(
                app: app,
                palette: palette,
                track: track,
                lyrics: lyrics,
                credited: creditedArtists,
                routeNameFallback: "iPhone",
                onDJ: onDJ,
                onLyrics: onLyrics,
                onSleepTimer: onSleepTimer,
                onNavigate: onNavigate,
                onStop: onStop
            )
        }
        .padding(.horizontal, Self.sidePadding)
    }

    // MARK: Measurements

    /// The margin everything on the page is set in from.
    private static let sidePadding: CGFloat = 20

    /// What the two blocks under the sleeve come to before they have been measured, so the first
    /// frame is close rather than wildly wrong: three lines of names with the chip and stars, then
    /// the seek bar and its times, the transport, and the three…
    private static let estimatedWords: CGFloat = 118
    private static let estimatedControls: CGFloat = 222

    /// The gaps between the rows under the sleeve.
    private struct Gaps {
        var underArtwork: CGFloat
        var betweenWords: CGFloat
        var breathing: CGFloat
        var aboveTransport: CGFloat
        var aboveUtility: CGFloat
        /// Clear of the home indicator. The forty-four point tap targets
        /// carry a dozen points of air under the glyphs themselves, which is
        /// what lets the bleeding screen get away with so little here.
        var underUtility: CGFloat
    }

    private var gaps: Gaps {
        layout == .bleed
            ? Gaps(
                underArtwork: 12,
                betweenWords: 10,
                breathing: 18,
                aboveTransport: 16,
                aboveUtility: 10,
                underUtility: 12
            )
            : Gaps(
                // Twelve points more than the bleeding screen's, and twelve fewer above the sleeve
                // to pay for it: the square rises by that much and the words stay exactly where
                // they were, so what the change buys is air between the picture and the title…
                underArtwork: 24,
                betweenWords: 14,
                breathing: 18,
                aboveTransport: 24,
                aboveUtility: 18,
                // Sixteen points thinner than it was drawn.
                underUtility: 14
            )
    }

    /// Everything the page owes the words and the controls: the gap under
    /// the sleeve, the two measured blocks, and the one flexible gap at its
    /// minimum. What is left over is the bleeding sleeve's.
    private var roomBelowArtwork: CGFloat {
        gaps.underArtwork
            + (wordsHeight ?? Self.estimatedWords)
            + gaps.breathing
            + (controlsHeight ?? Self.estimatedControls)
    }

    private var framedSide: CGFloat {
        // Less the volume row's room while it is there: the square is bounded
        // by the width and takes no notice of what is below it, so the row
        // used to push the glyph row down the screen by its own height.
        let room = player.offeredVolume == nil ? 0 : Self.volumeRowRoom
        return min(pageWidth - Self.sidePadding * 2, pageHeight * 0.48) - room
    }

    /// The gap above the volume row, and what the row and that gap take in all.
    private static let volumeRowGap: CGFloat = 8
    private static let volumeRowRoom: CGFloat = 34

    /// Where the framed square starts.
    private var framedTopGap: CGFloat {
        let slack = pageHeight - (Self.framedBaseTopGap + framedSide + roomBelowArtwork)
        return Self.framedBaseTopGap + max(0, min(slack, Self.framedTopGapGive))
    }

    /// Ten, down from twenty-two, with those twelve points handed to the gap under the sleeve.
    private static let framedBaseTopGap: CGFloat = 10
    private static let framedTopGapGive: CGFloat = 22

    /// The bleeding sleeve takes the page less that, so nothing is spare.
    private var artworkHeight: CGFloat {
        min(pageWidth * 1.34, pageHeight - roomBelowArtwork)
    }

}

/// The bleeding sleeve itself, scrim and foot fade included.
private struct BleedArtworkHeader: View {
    let artwork: ArtworkID?
    let fallback: Color
    let dissolvesIntoBackground: Bool
    let fadeTarget: Color
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            BleedArtwork(artwork: artwork, fallback: fallback)
                .frame(width: width, height: height)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.72), location: 0),
                            .init(color: .black.opacity(0.30), location: 0.13),
                            .init(color: .black.opacity(0), location: 0.23),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .mask { dissolvesIntoBackground ? AnyView(bottomFade) : AnyView(Color.black) }
                .overlay {
                    if !dissolvesIntoBackground {
                        // Solid well before the foot, and solid the rest of the way.
                        LinearGradient(
                            stops: [
                                .init(color: fadeTarget.opacity(0), location: 0.58),
                                .init(color: fadeTarget.opacity(0.14), location: 0.70),
                                .init(color: fadeTarget.opacity(0.45), location: 0.81),
                                .init(color: fadeTarget.opacity(0.80), location: 0.90),
                                .init(color: fadeTarget, location: 0.97),
                                .init(color: fadeTarget, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
        }
        .frame(width: width, height: height)
    }

    /// Gone before the foot, for the same reason the wash above is solid
    /// before it: a picture still one per cent there in its last row draws a
    /// line, and a line is what this whole arrangement exists to avoid.
    private var bottomFade: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.66),
                .init(color: .black.opacity(0.55), location: 0.82),
                .init(color: .black.opacity(0.14), location: 0.92),
                .init(color: .clear, location: 0.98),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The cover at full width, scaled a little past it and cropped to its upper
/// part — the design asks for a picture that fills the head of the screen,
/// not a square with the page showing beside it.
private struct BleedArtwork: View {
    let artwork: ArtworkID?
    let fallback: Color

    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    @Environment(\.cardIsRising) private var cardIsRising

    /// The sleeve if it is already in memory, so the card opens with it on the
    /// first frame rather than receiving it while it rises.
    private var inMemory: UIImage? {
        guard let artwork, let loader = app.artwork else { return nil }
        return loader.cachedImage(for: artwork, bucket: 1200)
    }
    /// Which sleeve the picture on screen belongs to.
    @State private var shownArtwork: String = ""

    var body: some View {
        GeometryReader { proxy in
            // Big enough to cover the region whichever way it is shaped: the sleeve is now often
            // taller than it is wide, and a square sized only from the width would leave a band of
            // nothing above and below it.
            let side = max(proxy.size.width * 1.1, proxy.size.height)
            let overflow = side - proxy.size.height
            Group {
                if let shown = image ?? inMemory {
                    Image(uiImage: shown)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        // Biased upward, so what is cropped is the foot of
                        // the sleeve — which is where the fade is going to
                        // take it anyway.
                        .offset(y: -max(overflow, 0) * 0.12)
                        .id(shownArtwork)
                        .transition(cardIsRising ? .identity : .opacity)
                } else {
                    fallback
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: "\(artwork?.rawValue ?? "none")|\(app.artworkStage)") {
            guard let loader = app.artwork, let artwork else {
                image = nil
                shownArtwork = ""
                return
            }
            let loaded = await loader.image(for: artwork, bucket: 1200)
            guard !Task.isCancelled else { return }
            // The same curve and the same length as the colour behind it, which is the whole point:
            // the page eased and the sleeve cut, so however exactly the two were started together
            // the picture was always there first and the page caught up.
            withAnimation(cardIsRising ? nil : .easeIn(duration: 0.15)) {
                image = loaded
                shownArtwork = artwork.rawValue
            }
        }
    }
}
