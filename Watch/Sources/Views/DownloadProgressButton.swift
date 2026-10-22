import SwiftUI

/// How far the downloads have got, in the corner of the screen, for as long as there are any.
struct DownloadProgressButton: View {
    let downloads: WatchDownloads

    /// Never quite empty.
    private static let leastVisibleArc: Double = 0.04

    /// The arc to draw, never below the floor.
    private var fraction: Double {
        (max(Self.leastVisibleArc, min(1, downloads.progress ?? 0)) * 100).rounded() / 100
    }

    private var isHeld: Bool { downloads.isPaused || downloads.isStalled }

    var body: some View {
        DownloadRing(fraction: fraction, isHeld: isHeld)
            .accessibilityLabel(isHeld ? "Downloads stopped" : "Downloading")
            // The count rather than the arc: the arc is floored, so announcing
            // it said "4 per cent" for an hour.
            .accessibilityValue(downloads.queueHeadline ?? "Starting")
    }
}

extension View {
    /// Puts the ring on a screen, for as long as songs are owed.
    func watchDownloadRing(_ downloads: WatchDownloads?) -> some View {
        toolbar {
            if let downloads, downloads.queueCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    DownloadProgressButton(downloads: downloads)
                }
            }
        }
    }
}

/// The ring itself, taking a number rather than the downloads, so it can be looked at on its own —
/// which is the only way anybody was going to check what it looks like at a quarter full without
/// waiting for a real download to be a quarter done.
struct DownloadRing: View {
    let fraction: Double
    /// Whether the queue is stopped, which the corner of a screen has to be
    /// able to say on its own — otherwise a held queue and a working one look
    /// identical from two screens away.
    var isHeld = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    isHeld ? Color.secondary : Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                // Twelve o'clock, the way every other progress ring on this
                // watch starts.
                .rotationEffect(.degrees(-90))
            Image(systemName: isHeld ? "pause.fill" : "arrow.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHeld ? Color.secondary : Color.accentColor)
        }
        .frame(width: 22, height: 22)
        .animation(.easeInOut(duration: 0.25), value: fraction)
    }
}
