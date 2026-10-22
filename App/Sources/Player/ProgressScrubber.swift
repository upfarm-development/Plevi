import SwiftUI

/// The playback position, as a line or as the track's own waveform.
struct ProgressScrubber: View {
    /// 0...1.
    let progress: Double
    var samples: [Float]?
    var style: ProgressStyle = .line
    /// False while the card carrying the bar is still rising: nothing on the bar animates then.
    var animates = true
    var palette: ArtworkPalette = .neutral
    /// Called continuously while dragging, and once more on release.
    let onScrub: (Double, _ isFinal: Bool) -> Void

    @State private var dragProgress: Double?

    /// How tall a measured level draws.
    private static let displayGain: Float = 1.5

    /// Where the loud end of a track is lifted towards when the track is quiet.
    private static let loudEndHeight: Float = 0.45

    /// How much of the way to `loudEndHeight` a quiet track is lifted: 0 is
    /// the old fixed lift for everything, 1 is all the way.
    private static let liftShare: Float = 0.5

    /// The most a quiet track is lifted, about 20 dB. Past that it is mostly
    /// noise being drawn large.
    private static let maxLift: Float = 10

    /// How quickly the contrast eases off as a track is lifted.
    private static let contrastEasing: Float = 0.35

    /// How far the difference between a track's loud and quiet moments is widened before drawing.
    private static let contrast: Float = 1.6

    /// What to draw for the bar while its card is rising.
    static func samples(
        _ loaded: [Float]?, atOpening opening: [Float]?, style: ProgressStyle, hasRisen: Bool
    ) -> [Float]? {
        guard style != .line else { return nil }
        // A shape that was already in hand on the card's first frame is drawn
        // from the start: nothing about the bar changes during the rise, so it
        // travels with the card like everything else.
        if let opening { return hasRisen ? loaded : opening }
        // One that arrives while the card is moving is held back until it has landed: heights
        // changing mid-rise were what left the bar behind at its final place on an iPad cold
        // launch.
        guard hasRisen else { return [Float](repeating: 0, count: WaveformSampler.barCount) }
        return loaded
    }

    private var shown: Double {
        min(max(dragProgress ?? progress, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let samples, !samples.isEmpty, style != .line {
                    if style == .curve {
                        curve(samples, width: proxy.size.width, height: proxy.size.height)
                    } else {
                        waveform(samples, width: proxy.size.width, height: proxy.size.height)
                    }
                } else {
                    line(height: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            // Every touch on the bar is handled in UIKit, tap and drag alike.
            .overlay {
                ScrubGestures(
                    onSeek: { fraction in onScrub(fraction, true) },
                    onScrub: { fraction, isFinal in
                        dragProgress = isFinal ? nil : fraction
                        onScrub(fraction, isFinal)
                    }
                )
            }
        }
        // The height comes from the *style*, not from whether the shape has arrived yet.
        .frame(height: style == .line ? 8 : 40)
        // The bar is drawn and touched, never a control VoiceOver can find:
        // it was unreachable without sight. Adjustable, so swipe up or down
        // moves the position by a twentieth of the song.
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int((shown * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: onScrub(min(progress + step, 1), true)
            case .decrement: onScrub(max(progress - step, 0), true)
            @unknown default: break
            }
        }
    }

    private func line(height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(palette.foreground.opacity(0.22))
                .frame(height: 5)
            GeometryReader { proxy in
                Capsule()
                    .fill(palette.foreground)
                    .frame(width: proxy.size.width * shown, height: 5)
            }
            .frame(height: 5)
        }
        .frame(height: height, alignment: .center)
    }

    /// Bars fill from the left as the track plays, in the artwork's own
    /// colour — the played part in the page's text colour, the rest of it
    /// faint behind.
    private func waveform(_ allSamples: [Float], width: CGFloat, height: CGFloat) -> some View {
        // Separate bars need room to be separate.
        let samples = Self.thinned(Self.shaped(allSamples), to: Self.barLimit(forWidth: width))
        let count = samples.count
        let spacing: CGFloat = 1.5
        let barWidth = max(1, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        return HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                let played = Double(index) / Double(max(count - 1, 1)) <= shown
                Capsule()
                    // A floor so silence is still a visible bar rather than a
                    // gap in the strip.
                    .frame(
                        width: barWidth,
                        height: max(3, min(height, CGFloat(sample) * height))
                    )
                    .foregroundStyle(
                        played ? palette.foreground : palette.foreground.opacity(0.25)
                    )
            }
        }
        .frame(width: width, height: height)
        .animation(animates ? .linear(duration: 0.2) : nil, value: shown)
        .animation(animates ? .easeOut(duration: 0.3) : nil, value: allSamples)
    }

    /// One bar and the gap after it, in points, at the density the phone has
    /// always drawn.
    private static let barPitch: CGFloat = 4

    /// Never fewer than this, so a narrow bar still reads as a waveform.
    private static let fewestBars = 60

    /// How many bars fit `width` at the usual pitch. The stored shape is
    /// `WaveformSampler.barCount` points, which is as fine as it gets.
    static func barLimit(forWidth width: CGFloat) -> Int {
        max(fewestBars, Int((width / barPitch).rounded()))
    }

    /// Widens each point's distance from the track's median.
    static func shaped(_ samples: [Float]) -> [Float] {
        guard samples.count > 1 else { return samples }
        let sorted = samples.sorted()
        let loudEnd = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        let wanted = loudEnd > 0 ? loudEndHeight / loudEnd : displayGain
        let lift = wanted > displayGain
            ? min(maxLift, displayGain * powf(wanted / displayGain, liftShare))
            : displayGain
        let spread = 1 + (contrast - 1) * powf(displayGain / lift, contrastEasing)
        let median = sorted[sorted.count / 2] * lift
        return samples.map { min(1, max(0, median + ($0 * lift - median) * spread)) }
    }

    /// Groups points and keeps the loudest of each, so peaks survive.
    static func thinned(_ samples: [Float], to limit: Int) -> [Float] {
        guard samples.count > limit, limit > 0 else { return samples }
        let perGroup = Double(samples.count) / Double(limit)
        return (0..<limit).map { group in
            let start = Int(Double(group) * perGroup)
            let end = max(start + 1, Int(Double(group + 1) * perGroup))
            return samples[start..<min(end, samples.count)].max() ?? 0
        }
    }

    /// The same shape drawn as one smooth band rather than separate bars —
    /// mirrored about the centre line, played part solid, the rest faint
    /// behind it.
    private func curve(_ samples: [Float], width: CGFloat, height: CGFloat) -> some View {
        let shaped = Self.shaped(samples)
        return WaveformCurve(samples: shaped)
            .fill(palette.foreground.opacity(0.25))
            .overlay(alignment: .leading) {
                WaveformCurve(samples: shaped)
                    .fill(palette.foreground)
                    .frame(width: width)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * shown)
                    }
            }
            .frame(width: width, height: height)
            .animation(animates ? .linear(duration: 0.2) : nil, value: shown)
    }
}

/// A value remembered from the first time it was asked for, so a view can tell
/// what it was given on its first frame from what arrived later. A reference
/// type held in `@State`, so asking in `body` changes nothing SwiftUI watches.
final class FirstValue<Value> {
    private var taken = false
    private var first: Value?

    func value(_ current: Value?) -> Value? {
        if !taken { taken = true; first = current }
        return first
    }
}

/// A track's shape as a single closed curve, mirrored about the centre.
struct WaveformCurve: Shape {
    let samples: [Float]
    /// Already lifted: see `ProgressScrubber.shaped`.
    var gain: CGFloat = 1
    /// Never quite zero: silence should still be a line through the middle,
    /// not a gap where the shape disappears.
    var floor: CGFloat = 0.06

    /// Above this many points, the shape is drawn as straight segments.
    private static let smoothingLimit = 120

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path(rect) }
        let middle = rect.midY
        let step = rect.width / CGFloat(samples.count - 1)

        func point(_ index: Int, above: Bool) -> CGPoint {
            let level = min(1, max(floor, CGFloat(samples[index]) * gain))
            let offset = level * rect.height / 2
            return CGPoint(x: CGFloat(index) * step, y: above ? middle - offset : middle + offset)
        }

        var path = Path()
        path.move(to: point(0, above: true))
        addSmoothLine(to: &path, above: true, point: point)
        path.addLine(to: point(samples.count - 1, above: false))
        addSmoothLine(to: &path, above: false, point: point, reversed: true)
        path.closeSubpath()
        return path
    }

    private func addSmoothLine(
        to path: inout Path,
        above: Bool,
        point: (Int, Bool) -> CGPoint,
        reversed: Bool = false
    ) {
        let indices = reversed
            ? Array((0..<(samples.count - 1)).reversed())
            : Array(1..<samples.count)
        var previous = point(reversed ? samples.count - 1 : 0, above)
        let smooths = samples.count <= Self.smoothingLimit
        for index in indices {
            let next = point(index, above)
            if smooths {
                let mid = CGPoint(x: (previous.x + next.x) / 2, y: (previous.y + next.y) / 2)
                path.addQuadCurve(to: mid, control: previous)
            } else {
                path.addLine(to: next)
            }
            previous = next
        }
        path.addLine(to: previous)
    }
}


/// Tap-to-seek and drag-to-scrub for the bar, in UIKit.
private struct ScrubGestures: UIViewRepresentable {
    /// A tap: seek there and be done.
    let onSeek: (Double) -> Void
    /// A sideways drag: called continuously, then once more on release.
    let onScrub: (Double, _ isFinal: Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.pan(_:))
        )
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tap(_:))
        )
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.onScrub = onScrub
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSeek: onSeek, onScrub: onScrub)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSeek: (Double) -> Void
        var onScrub: (Double, Bool) -> Void

        init(onSeek: @escaping (Double) -> Void, onScrub: @escaping (Double, Bool) -> Void) {
            self.onSeek = onSeek
            self.onScrub = onScrub
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let fraction = fraction(of: recognizer) else { return }
            onSeek(fraction)
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let fraction = fraction(of: recognizer) else { return }
            switch recognizer.state {
            case .began, .changed:
                onScrub(fraction, false)
            case .ended, .cancelled, .failed:
                onScrub(fraction, true)
            default:
                break
            }
        }

        /// Whether this is a sideways drag.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// Alongside the list's own scrolling rather than instead of it. A
        /// sideways drag is nothing a vertical list wants anyway.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        private func fraction(of recognizer: UIGestureRecognizer) -> Double? {
            guard let view = recognizer.view, view.bounds.width > 0 else { return nil }
            return min(max(recognizer.location(in: view).x / view.bounds.width, 0), 1)
        }
    }
}
