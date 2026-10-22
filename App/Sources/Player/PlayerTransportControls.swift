import SwiftUI
import AVFoundation
import PleviDomain

/// The play/pause, previous/next, shuffle and repeat row — the same buttons, sizes and tint logic
/// on `ModernPlayerPage` and `IPadPlayerPane`.
struct PlayerTransportRow: View {
    let palette: PlayerPalette
    let player: any PlaybackControlling
    /// Long-pressing the play button. The screen above decides whether that
    /// asks first.
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                player.toggleShuffle()
            } label: {
                toggleGlyph("shuffle", isOn: player.isShuffled)
            }
            .accessibilityLabel(player.isShuffled ? "Stop shuffling" : "Shuffle")

            Spacer(minLength: 8)

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(palette.text)
            }
            .accessibilityLabel("Previous track")

            Spacer(minLength: 8)

            playButton

            Spacer(minLength: 8)

            Button {
                player.next(automatic: false)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(palette.text.opacity(player.hasNext ? 1 : 0.3))
            }
            .accessibilityLabel("Next track")
            .disabled(!player.hasNext)

            Spacer(minLength: 8)

            Button {
                player.cycleRepeatMode()
            } label: {
                toggleGlyph(player.repeatMode.symbolName, isOn: player.repeatMode.isOn)
            }
            .accessibilityLabel(player.repeatMode.label)
        }
        .buttonStyle(.plain)
    }

    /// Shuffle and repeat, on or off.
    private func toggleGlyph(_ symbol: String, isOn: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20))
            .foregroundStyle(isOn ? Color.accentColor : palette.text.opacity(0.6))
            .frame(width: 34, height: 34)
    }

    /// The one filled control on the screen. Tap plays or pauses; holding it
    /// stops and clears the queue, as everywhere else in the app.
    private var playButton: some View {
        ZStack {
            Circle()
                .fill(palette.buttonFill)
                .frame(width: 78, height: 78)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 30))
                .foregroundStyle(palette.buttonGlyph)
                // Nudged off centre, because a triangle's centre of area is
                // not the centre of the box it is drawn in and a play glyph
                // sitting true in a circle looks to be leaning back.
                .offset(x: player.isPlaying ? 0 : 2)
        }
        .contentShape(.circle)
        .onTapGesture { player.togglePlayPause() }
        .onLongPressGesture(minimumDuration: 0.6) { onStop() }
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Stop and clear queue") { onStop() }
    }
}

/// The disc, AirPlay and ··· glyphs together — identical on `ModernPlayerPage` and
/// `IPadPlayerPane`, which only differ in how each arranges the three within its own utility row
/// (left-anchored vs. centred as a cluster).
struct PlayerUtilityGlyphs: View {
    let app: AppModel
    let palette: PlayerPalette
    let track: Track?
    /// The words, when the server has them for this song. Nil takes the
    /// button away rather than dimming it.
    let lyrics: Lyrics?
    /// Resolved by the caller, once per track, rather than looked up again
    /// here — see `IPadPlayerPane.creditedArtists`/`ModernPlayerPage`'s own,
    /// which this row shares a track with `artistLine`.
    let credited: [Artist]
    /// What to call the output route before the first one is known —
    /// "iPhone" or "iPad", matching whichever pane is asking.
    let routeNameFallback: String
    let onDJ: () -> Void
    let onLyrics: () -> Void
    let onSleepTimer: () -> Void
    let onNavigate: (AppModel.NavigationRequest) -> Void
    let onStop: () -> Void

    /// What is playing through, for the pill. Read once and then kept up to
    /// date, since asking the session on every redraw is a trip into
    /// CoreAudio for a string that changes twice an hour.
    @State private var routeName: String
    @State private var showingDevicePicker = false
    /// One name per mounted button, so two of them on screen do not release each other's browse (R-10).
    @State private var browseOwner = "player-\(UUID().uuidString)"

    private var player: any PlaybackControlling { app.activePlayer }
    private var actions: MediaActions { MediaActions(app: app) }

    init(
        app: AppModel,
        palette: PlayerPalette,
        track: Track?,
        lyrics: Lyrics?,
        credited: [Artist],
        routeNameFallback: String,
        onDJ: @escaping () -> Void,
        onLyrics: @escaping () -> Void,
        onSleepTimer: @escaping () -> Void,
        onNavigate: @escaping (AppModel.NavigationRequest) -> Void,
        onStop: @escaping () -> Void
    ) {
        self.app = app
        self.palette = palette
        self.track = track
        self.lyrics = lyrics
        self.credited = credited
        self.routeNameFallback = routeNameFallback
        self.onDJ = onDJ
        self.onLyrics = onLyrics
        self.onSleepTimer = onSleepTimer
        self.onNavigate = onNavigate
        self.onStop = onStop
        _routeName = State(initialValue: Self.currentRouteName(fallback: routeNameFallback))
    }

    var body: some View {
        Group {
            djGlyph
            outputPill
            remoteButton
            overflowMenu
        }
    }

    private static func currentRouteName(fallback: String) -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? fallback
    }

    /// Recolours when a DJ is running — a plain swap, this row's own idiom
    /// for "on," rather than the classic layout's circle-behind.
    private var djGlyph: some View {
        Button { app.openDJ(onDJ) } label: {
            Image("DJTurntable")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(app.dj?.active != nil ? palette.accent : palette.text.opacity(0.6))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.dj?.active.map { "DJ: \($0.label) is on" } ?? "DJ")
    }

    /// The way to send the sound somewhere else: the system's own AirPlay picker, always, drawn in
    /// the accent so it reads as the one control here that says where you are listening.
    private var outputPill: some View {
        RoutePickerView(tint: palette.accent)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Audio output, \(routeName)")
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                routeName = Self.currentRouteName(fallback: routeNameFallback)
            }
    }

    /// Where another Plevi on the network can be chosen to play, and which one is being controlled.
    @ViewBuilder
    private var remoteButton: some View {
        if app.remote.inUse {
            DeviceButton(
                state: deviceButtonState,
                localGlyph: "ipad.and.iphone",
                localTint: palette.text.opacity(0.6),
                controllingTint: palette.accent,
                size: 44
            ) { showingDevicePicker = true }
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
                .onAppear { app.remote.startBrowsing(owner: browseOwner) }
                .onDisappear { app.remote.stopBrowsing(owner: browseOwner) }
        }
    }

    private var deviceButtonState: DeviceButtonState { app.remote.deviceButtonState }

    /// Everything the screen has no room to show, including the two things this design drops on
    /// purpose: the heart, and going to the album or artist by tapping their names is still there,
    /// but favouriting has nowhere else to live.
    private var overflowMenu: some View {
        PlayerOverflowMenu(
            track: track,
            hasLyrics: lyrics != nil,
            isSleepTimerActive: player.isSleepTimerActive,
            hasUpNext: player.canEditQueue && player.hasUpNext,
            canFavorite: app.provider?.capabilities.contains(.favorites) == true && player.canActOnLibrary,
            canStartRadio: app.provider?.capabilities.contains(.similarItems) == true && player.canActOnLibrary,
            canAddToPlaylist: app.provider?.capabilities.contains(.playlists) == true && player.canActOnLibrary,
            // §4.8.1: "Save Mix as Playlist…" hidden while remote — the
            // controller only ever holds a window of the target's queue,
            // never the whole of what a mix would need saved.
            mixName: app.remote.isControlling ? nil : player.queueOrigin.radioName,
            remoteDeviceName: app.remote.controlledDeviceName,
            glyph: .bare(palette.text.opacity(0.6)),
            credited: credited,
            onLyrics: onLyrics,
            onSleepTimer: onSleepTimer,
            onToggleFavorite: { track in
                actions.setFavorite(!track.isFavorite, id: track.id, kind: .track)
            },
            onStartRadio: { actions.startRadio(from: $0) },
            onAddToPlaylist: { app.requestAddToPlaylist([$0]) },
            onSaveMix: {
                guard let name = player.queueOrigin.radioName else { return }
                app.requestAddToPlaylist(
                    player.queue.map(\.track),
                    suggesting: MediaActions.playlistName(for: name)
                )
            },
            onNavigate: onNavigate,
            onClearUpNext: { player.clearUpNext() },
            onStop: onStop,
            onDisconnect: { app.remote.disconnect() }
        )
        .equatable()
    }
}

/// Seek-bar time text and progress fraction — identical math on
/// `ModernPlayerPage` and `IPadPlayerPane`.
@MainActor
enum PlayerTimeDisplay {
    static func text(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.isFinite ? min(max(0, seconds), 1_000_000) : 0).formatted(.time(pattern: .minuteSecond))
    }

    static func trailingTimeText(
        player: any PlaybackControlling,
        showsRemainingTime: Bool,
        isScrubbing: Bool,
        scrubTime: TimeInterval
    ) -> String {
        let total = player.duration ?? 0
        guard showsRemainingTime else { return text(total) }
        let elapsed = isScrubbing ? scrubTime : player.currentTime
        return "-" + text(max(total - elapsed, 0))
    }

    static func fraction(player: any PlaybackControlling, isScrubbing: Bool, scrubTime: TimeInterval) -> Double {
        let total = player.duration ?? 0
        guard total > 0 else { return 0 }
        return (isScrubbing ? scrubTime : player.currentTime) / total
    }
}
