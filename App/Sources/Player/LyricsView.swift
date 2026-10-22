import SwiftUI
import PleviDomain

/// The words to the playing song.
struct LyricsView: View {
    let lyrics: Lyrics
    let palette: PlayerPalette
    let title: String
    let artist: String?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Off while a finger is on the page and for a moment after, so following
    /// the song does not drag the page out from under someone reading ahead.
    @State private var followsAlong = true
    @State private var releasedScrollAt: Date?

    /// How long a hand keeps control after letting go.
    private static let handHoldsFor: TimeInterval = 6

    private var player: any PlaybackControlling { app.activePlayer }

    /// The line being sung: the last one to have started.
    private var currentLine: Int? {
        guard lyrics.synced else { return nil }
        let now = player.currentTime - lyrics.offset
        var found: Int?
        for (index, line) in lyrics.lines.enumerated() {
            guard let start = line.start, start <= now else { break }
            found = index
        }
        return found
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: lyrics.synced ? 18 : 8) {
                    header
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        row(line, index: index)
                            .id(index)
                    }
                    // Room to bring the last line up to the middle of the
                    // page rather than leaving it stuck at the foot.
                    Color.clear.frame(height: 260)
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
            }
            .withoutBottomScrollEdgeBlur()
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .tracking {
                    followsAlong = false
                    releasedScrollAt = nil
                } else if !followsAlong, releasedScrollAt == nil {
                    releasedScrollAt = .now
                }
            }
            .onChange(of: currentLine) { _, line in
                guard followsAlong, let line else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    scroll.scrollTo(line, anchor: .center)
                }
            }
            .task(id: releasedScrollAt) {
                guard let releasedScrollAt else { return }
                try? await Task.sleep(for: .seconds(Self.handHoldsFor))
                guard !Task.isCancelled, self.releasedScrollAt == releasedScrollAt else { return }
                followsAlong = true
                if let line = currentLine {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        scroll.scrollTo(line, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { palette.ground.ignoresSafeArea() }
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.primaryText)
            if let artist {
                Text(artist)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.tertiaryText)
            }
            if !lyrics.synced {
                Text("Not timed to the music")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiaryText)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 22)
        .padding(.trailing, 44)
    }

    @ViewBuilder
    private func row(_ line: Lyrics.Line, index: Int) -> some View {
        if line.text.isEmpty {
            // A break between verses in an untimed sheet.
            Color.clear.frame(height: 10)
        } else {
            let isCurrent = index == currentLine
            Text(line.text)
                .font(.system(size: lyrics.synced ? 24 : 18, weight: lyrics.synced ? .bold : .regular))
                .foregroundStyle(colour(isCurrent: isCurrent, index: index))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture {
                    // Only where there is a moment to jump to.
                    guard let start = line.start else { return }
                    player.seek(to: max(0, start + lyrics.offset))
                }
                .accessibilityAddTraits(line.start == nil ? [] : .isButton)
                .animation(.easeInOut(duration: 0.25), value: isCurrent)
        }
    }

    /// The sung line bright, the ones behind it dimmer than the ones ahead —
    /// what has gone is done with, what is coming is what you want to see.
    private func colour(isCurrent: Bool, index: Int) -> Color {
        guard lyrics.synced else { return palette.text.opacity(0.85) }
        if isCurrent { return palette.text }
        if let current = currentLine, index < current { return palette.text.opacity(0.28) }
        return palette.text.opacity(0.45)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.text.opacity(0.7))
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(palette.text.opacity(0.1))
                        .frame(width: 34, height: 34)
                }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18)
        .padding(.top, 8)
        .accessibilityLabel("Close lyrics")
    }
}
