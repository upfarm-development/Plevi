import SwiftUI

/// One line of text that travels sideways when it does not fit, so a long title can be read in full
/// rather than ending in an ellipsis.
struct MarqueeText: View {
    let text: String
    var font: Font = .subheadline
    /// Points a second. Slow enough to read, quick enough not to nag.
    var speed: Double = 24
    /// Seconds held at each end.
    var pause: Double = 1.5
    /// How many times it travels out and back before settling.
    var cycles = 1
    /// When off, the line simply truncates — the same text, standing still.
    var rolls = true
    /// Whether this takes all the width it is offered.
    var fillsWidth = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var fullWidth: CGFloat = 0
    /// Which words the line has travelled for, or nil while it is at rest.
    @State private var travelledFor: String?
    /// Bumped to start the cycle again — on returning to the app, and by the
    /// view being built afresh when the player is opened.
    @State private var run = 0

    var body: some View {
        if rolls {
            rolling
        } else {
            Text(text)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var rolling: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            // Asked for, the full width offered rather than the width the truncated line happened
            // to use.
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(alignment: .leading) {
                // Never clipped, never shrunk, never seen: only measured.
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
            }
            .overlay { window }
    }

    private var window: some View {
        GeometryReader { proxy in
            let overflow = max(0, fullWidth - proxy.size.width)
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .offset(x: travelledFor == text ? -overflow : 0)
                // Always leading.
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .leading
                )
                .clipped()
                // A new song is a new line, not the old one with different words in it.
                .id("\(text)|\(run)")
                // Keyed on the text *and* the distance: a new song, or a width
                // that changes, starts the cycle over rather than leaving the
                // line stranded mid-travel.
                .task(id: "\(text)|\(Int(overflow))|\(run)") { await roll(overflow: overflow) }
                // A new song starts at the beginning, and gets there without
                // travelling: whatever the last one was doing when it ended,
                // the next one should not be seen finishing it.
                .onChange(of: text) { _, _ in
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { travelledFor = nil }
                }
                // Genuinely coming back, not a dip to `.inactive` and straight back — Control
                // Center, a call, the app switcher — which passes through `.active` too without
                // ever backgrounding the app.
                .onChange(of: scenePhase) { old, phase in
                    if phase == .active, old == .background { run &+= 1 }
                }
        }
    }

    private func roll(overflow: CGFloat) async {
        let words = text
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { travelledFor = nil }
        guard overflow > 0 else { return }
        let travelTime = Double(overflow) / speed
        for _ in 0..<cycles {
            try? await Task.sleep(for: .seconds(pause))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: travelTime)) { travelledFor = words }

            try? await Task.sleep(for: .seconds(travelTime + pause))
            guard !Task.isCancelled else { return }
            // Back the way it came, at the same speed.
            withAnimation(.linear(duration: travelTime)) { travelledFor = nil }

            try? await Task.sleep(for: .seconds(travelTime))
            guard !Task.isCancelled else { return }
        }
        // Left where it started, and still.
    }
}
