import SwiftUI
import UIKit

/// One station as a filled gradient button: an icon and a name, centred.
struct RadioTile: View {
    let station: RadioStation
    /// The button's width, or nil to fill whatever it is given — which is what
    /// the list layout wants and the grid does not.
    var width: CGFloat?
    var height: CGFloat
    /// Shared across the whole shelf rather than decided per button. See
    /// `labelSize(fitting:titles:)` for why.
    var labelSize: CGFloat

    @Environment(\.radioTileIsPressed) private var isPressed

    /// The design's 12.5pt was sized for a label sharing its line with the icon.
    static let baseLabelSize: CGFloat = 14
    /// Below this the label stops shrinking and starts truncating instead.
    static let minimumLabelSize: CGFloat = 11
    static let iconSide: CGFloat = 18
    static let sidePadding: CGFloat = 8
    static let verticalPadding: CGFloat = 8
    /// A floor, not a fixed gap: the icon is pinned to the top and the label to
    /// the bottom, and this is only what stops them touching on a short button.
    static let iconLabelGap: CGFloat = 4
    private static let corner: CGFloat = 10

    /// What the button stands, whatever is set inside it.
    static let standingHeight: CGFloat = 62

    /// The standing height, or whatever the contents genuinely need if those
    /// are ever set large enough to want more — so the two can never
    /// disagree and clip.
    static func height(labelSize: CGFloat) -> CGFloat {
        let line = UIFont.systemFont(ofSize: labelSize, weight: .semibold).lineHeight
        let needed = (verticalPadding * 2 + iconSide + iconLabelGap + line).rounded(.up)
        return max(standingHeight, needed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            station.icon.view
                .frame(width: Self.iconSide, height: Self.iconSide)
            Spacer(minLength: Self.iconLabelGap)
            Text(station.title)
                .font(.system(size: labelSize, weight: .semibold))
                .tracking(-0.2)
                // Never two lines: the buttons are a fixed height and a wrapped
                // label would either overflow it or force every button taller
                // for the sake of one.
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Self.sidePadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(width: width, height: height, alignment: .leading)
        .background(station.gradient)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        // No shadow, though the design asks for one at 40%. Nothing else on
        // Home casts a shadow, and six that did would lift the Radio shelf off
        // a page everything else sits flat on.
        .colorMultiply(isPressed ? Color(white: 0.92) : .white)
        .scaleEffect(isPressed ? 0.96 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.title). \(station.subtitle)")
    }

    /// The one label size the whole shelf uses: the design's 12.5pt where it fits, and the largest
    /// size that holds the longest name on one line where it does not.
    static func labelSize(fitting cellWidth: CGFloat, titles: [String]) -> CGFloat {
        let available = cellWidth - sidePadding * 2
        guard available > 0 else { return minimumLabelSize }

        let widest = titles.map { width(of: $0, at: baseLabelSize) }.max() ?? 0
        guard widest > available, widest > 0 else { return baseLabelSize }

        // Tracking is a fixed amount per character, so it does not scale with
        // the font — solving for the size means measuring at a trial size
        // rather than dividing once.
        var size = baseLabelSize
        while size > minimumLabelSize {
            let next = size - 0.1
            if titles.allSatisfy({ width(of: $0, at: next) <= available }) { return next }
            size = next
        }
        return minimumLabelSize
    }

    private static func width(of title: String, at size: CGFloat) -> CGFloat {
        (title as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .kern: -0.2,
        ]).width
    }
}

/// The mark on a station's button.
enum RadioIcon: Hashable {
    /// An SF Symbol, so the weights match the rest of the app.
    case symbol(String)
    /// Two faders, one set high and one low.
    case faders

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
        case .faders:
            FadersIcon()
        }
    }
}

/// Two faders, one knob high and one low, drawn in the design's 24×24 grid.
struct FadersIcon: View {
    private static let unit: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let s = proxy.size.width / Self.unit
            ZStack(alignment: .topLeading) {
                // The travel each fader runs along, quieter than the knob on
                // it — the same weight relationship the design's artwork has.
                bar(x: 8.6, y: 4, w: 2.2, h: 16, s: s).opacity(0.72)
                bar(x: 14.2, y: 4, w: 2.2, h: 16, s: s).opacity(0.72)
                // The knobs straddle their tracks, one high and one low.
                bar(x: 6, y: 6, w: 7.4, h: 3.6, s: s)
                bar(x: 11.6, y: 14.4, w: 7.4, h: 3.6, s: s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, s: CGFloat) -> some View {
        Capsule()
            .frame(width: w * s, height: h * s)
            .offset(x: x * s, y: y * s)
    }
}

/// Whether the button is being pressed, handed down from the button style.
private struct RadioTilePressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var radioTileIsPressed: Bool {
        get { self[RadioTilePressedKey.self] }
        set { self[RadioTilePressedKey.self] = newValue }
    }
}

/// Presses the button rather than the whole row, and tells it about it.
struct RadioTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.radioTileIsPressed, configuration.isPressed)
    }
}

extension Color {
    /// `0x4E7FE1` and its like, which is how the design names its colours.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
