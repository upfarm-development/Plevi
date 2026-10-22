import SwiftUI
import WatchKit
import AVFoundation

/// Gives the Digital Crown to the watch's own volume, the way Apple's own Now Playing screen does.
struct WatchVolumeControl: WKInterfaceObjectRepresentable {
    /// Whether this screen should currently own the crown.
    var isActive: Bool

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ wkInterfaceObject: WKInterfaceVolumeControl, context: Context) {
        // Asked for again on every update rather than once: this view has
        // no way to be told the crown was reassigned elsewhere behind its
        // back, and re-asking when already focused is a no-op, not a cost.
        if isActive {
            wkInterfaceObject.focus()
        } else {
            wkInterfaceObject.resignFocus()
        }
    }
}

/// The volume, shown while it is being changed and not after.
struct VolumeHUD: View {
    @State private var volume: Float?
    @State private var showing = false
    @State private var hide: Task<Void, Never>?
    /// Whether the screen is on and the app in front. The watch is worn: most
    /// of the time Now Playing is selected it is also wrist-down, dimmed, and
    /// not worth waking for.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private let session = AVAudioSession.sharedInstance()

    var body: some View {
        // Always built, and hidden by opacity rather than by not existing.
        HStack(spacing: 5) {
            Image(systemName: icon(for: volume ?? 0))
                .font(.system(size: 12))
                .frame(width: 14)
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: 54, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: 54 * CGFloat(volume ?? 0), height: 4)
                }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .opacity(showing ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: showing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Cancelled when the wrist goes down or the screen dims, and started again when it comes
        // back.
        .task(id: isAwake) {
            guard isAwake else { return }
            volume = session.outputVolume
            var last = session.outputVolume
            // Observed, with a slow poll as the backstop: `outputVolume` is key-value observable on
            // paper and the crown's change arrives through it at once, but an observation that
            // quietly stops arriving is not a bet a volume bar should be left to.
            let (changes, continuation) = AsyncStream<Float>.makeStream()
            let observation = VolumeObservation(session: session) { continuation.yield($0) }
            let backstop = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    continuation.yield(session.outputVolume)
                }
            }
            defer {
                observation.cancel()
                backstop.cancel()
                continuation.finish()
            }
            for await now in changes {
                guard abs(now - last) > 0.001 else { continue }
                last = now
                show(now)
            }
        }
    }

    private var isAwake: Bool { scenePhase == .active && !isLuminanceReduced }

    private func show(_ now: Float) {
        volume = now
        showing = true
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            showing = false
        }
    }

    private func icon(for volume: Float) -> String {
        switch volume {
        case ..<0.001: "speaker.slash.fill"
        case ..<0.34: "speaker.fill"
        case ..<0.67: "speaker.wave.1.fill"
        default: "speaker.wave.2.fill"
        }
    }
}

/// A key-value observation of the output volume, held so it can be let go of from wherever the
/// stream ends.
private final class VolumeObservation: @unchecked Sendable {
    private var observation: NSKeyValueObservation?

    init(session: AVAudioSession, _ report: @escaping @Sendable (Float) -> Void) {
        observation = session.observe(\.outputVolume, options: [.new]) { _, change in
            if let value = change.newValue { report(value) }
        }
    }

    func cancel() {
        observation?.invalidate()
        observation = nil
    }
}
