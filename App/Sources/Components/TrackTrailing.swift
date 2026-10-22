import SwiftUI
import PleviDomain

/// The trailing end of a row in a list of songs: the length of the song, or the bars that say it is
/// the one playing.
struct TrackTrailing: View {
    let duration: TimeInterval?
    let isCurrent: Bool
    /// One of the record's standouts, which the marker says as well as the
    /// number does — see `AlbumDetailView.positionColumn`.
    var isHot: Bool = false
    /// Whether this row style puts the length at the trailing edge at all.
    /// When it does not, the slot only ever holds the playing bars, and it is
    /// their width that has to be reserved instead.
    var showsDuration: Bool = true
    var font: Font = .footnote
    var palette: ArtworkPalette = .neutral

    var body: some View {
        ZStack(alignment: .trailing) {
            reserved.hidden()
            content
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var reserved: some View {
        if showsDuration {
            // Five characters, so everything up to an hour reserves the same width.
            Text(verbatim: "00:00")
                .font(font)
                .monospacedDigit()
        } else {
            playingBars
        }
    }

    @ViewBuilder
    private var content: some View {
        if isCurrent {
            playingBars
        } else if showsDuration, let duration {
            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                .font(font)
                .foregroundStyle(palette.secondaryForeground)
                .monospacedDigit()
        }
    }

    private var playingBars: some View {
        Image(systemName: "waveform")
            .font(.caption)
            .foregroundStyle(
                isHot ? AnyShapeStyle(palette.hotAccent) : AnyShapeStyle(.tint)
            )
            .accessibilityLabel("Now playing")
    }
}
