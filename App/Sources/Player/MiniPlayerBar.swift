import SwiftUI
import PleviDomain

/// Compact player shown above the tab bar; tapping opens the full player, long-pressing offers the
/// queue, sleep timer, and stopping altogether.
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.horizontalSizeClass) private var sizeClass
    let onTap: () -> Void
    var onShowSleepTimer: () -> Void = {}

    /// Asked here rather than by the root, so the question can be anchored to
    /// the button it came from — as it is on the full player.
    @State private var confirmingStop = false
    /// Bumped on every stop request, to knock at the fingertip the moment the
    /// hold registers. Without it a long press that has worked feels like one
    /// that has not.
    @State private var stopRequests = 0

    var body: some View {
        // the bar stays up while controlling an idle target — otherwise
        // the bar disappears and nothing shows that the next tap will play there.
        if app.activePlayer.currentTrack != nil || app.remote.isControlling || app.remote.isConnecting {
            let track = app.activePlayer.currentTrack
            Group {
                if placement == .inline {
                    inline(track)
                } else {
                    expanded(track)
                }
            }
            // Puts back the symbolic default the root replaced, so the
            // glass can adjust these words to what is under this capsule.
            // See the note above the type.
            .foregroundStyle(.foreground)
            .frame(maxWidth: sizeClass == .regular ? regularWidth : .infinity)
            .contentShape(Rectangle())
            // A context menu does not open reliably inside the tab bar's accessory slot, so
            // press-and-hold goes straight to the action.
            .gesture(
                LongPressGesture(minimumDuration: 0.6)
                    .onEnded { _ in requestStop() }
                    .exclusively(before: TapGesture().onEnded { onTap() })
            )
            .sensoryFeedback(.impact(weight: .medium), trigger: stopRequests)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the full player. Press and hold to stop and clear the queue.")
        }
    }

    /// On an iPad the tab bar is a pill across the top, and a mini player stretched the width of
    /// the screen looks lost beside it.
    private var regularWidth: CGFloat {
        let labelled = 2
            + (app.settings.showsPlaylistsTab ? 1 : 0)
            + (app.settings.showsDownloadsTab ? 1 : 0)
        return max(340, 80 + 90 * CGFloat(labelled))
    }

    private func expanded(_ track: Track?) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: track?.artwork ?? nil, size: 36, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(track?.title ?? "Not Playing")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(secondLine(track))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            playPauseButton
            nextButton
        }
        .padding(.horizontal, 12)
    }

    private func inline(_ track: Track?) -> some View {
        HStack(spacing: 8) {
            Text(track?.title ?? secondLine(track))
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 0)
            playPauseButton
        }
        .padding(.horizontal, 12)
    }

    /// §4.8.2: "Stop playing on Kitchen iPad and clear its queue?" while
    /// remote — the same wording `NowPlayingView`'s own confirmation asks.
    private var stopConfirmationTitle: String {
        guard let name = app.remote.controlledDeviceName else { return "Stop playing and clear the queue?" }
        return "Stop playing on \(name) and clear its queue?"
    }

    /// §4.8.1: "Kitchen iPad · Miles Davis", or "Reconnecting to Kitchen
    /// iPad…" — the ordinary artist line everywhere else.
    private func secondLine(_ track: Track?) -> String {
        if app.remote.isReconnecting {
            return "Reconnecting to \(app.remote.lastControlledDeviceName ?? "another device")…"
        }
        guard app.remote.isControlling || app.remote.isConnecting else { return track?.artistName ?? "" }
        guard app.remote.isConnecting, !app.remote.isConnected else {
            let name = app.remote.controlledDeviceName ?? "another device"
            guard let track else { return name }
            return "\(name) · \(track.artistName ?? track.title)"
        }
        // "Reconnecting" only for a re-dial of the device this one was just controlling; a first
        // connection is "Connecting".
        let name = app.remote.connectingDeviceName ?? "another device"
        return "\(app.remote.isRedialling ? "Reconnecting" : "Connecting") to \(name)…"
    }

    /// Tap plays or pauses; holding stops and clears the queue.
    private var playPauseButton: some View {
        Image(systemName: app.activePlayer.isPlaying ? "pause.fill" : "play.fill")
            .font(.title3)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            // Exclusive, for the reason on the bar above — holding here used
            // to stop the queue and toggle playback on the way out.
            .gesture(
                LongPressGesture(minimumDuration: 0.6)
                    .onEnded { _ in requestStop() }
                    .exclusively(
                        before: TapGesture().onEnded { app.activePlayer.togglePlayPause() }
                    )
            )
            .accessibilityLabel(app.activePlayer.isPlaying ? "Pause" : "Play")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Stop and clear queue") { requestStop() }
            .popover(isPresented: $confirmingStop) {
                VStack(spacing: 10) {
                    Text(stopConfirmationTitle)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Stop and Clear", role: .destructive) {
                        confirmingStop = false
                        app.activePlayer.stop()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(18)
                .frame(maxWidth: 260)
                .presentationCompactAdaptation(.popover)
            }
    }

    /// Asks first only if the setting says to; the action is deliberate
    /// either way.
    private func requestStop() {
        stopRequests += 1
        if app.settings.confirmsStopAndClear {
            confirmingStop = true
        } else {
            app.activePlayer.stop()
        }
    }

    private var nextButton: some View {
        Button {
            app.activePlayer.next(automatic: false)
        } label: {
            Image(systemName: "forward.fill")
                .font(.title3)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!app.activePlayer.hasNext)
        .accessibilityLabel("Next track")
    }
}
