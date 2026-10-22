import SwiftUI

/// Play, Shuffle and the menu, as a row of labelled controls under a page's artwork.
struct HeaderActionRow<Menu: View>: View {
    /// How much room the row is taking.
    enum Layout {
        /// A line of its own under the artwork, with the words on the
        /// buttons. Play is the widest and the only solid one.
        case labelled
        /// Three squares at the end of a line something else is already using — a block of details
        /// on the left, these on the right.
        case compact
    }

    var layout: Layout = .labelled
    let onPlay: () -> Void
    let onShuffle: () -> Void
    /// The other kind of shuffle, revealed by holding the button — see `PlayShuffleButtons`, the
    /// round controls this replaced, which had the same long press.
    var alternativeShuffle: AlternativeShuffle?
    let palette: ArtworkPalette
    /// How much the two quieter controls stand out from the page. A little
    /// more on a lighter page, where the same value disappears.
    var quietFill: Double = 0.13
    var isDisabled = false
    /// The step down to whatever comes next. A list of songs wants a clear
    /// one; a headed section like About brings its own space and wants
    /// almost none.
    var bottomGap: CGFloat = 26
    /// How far in from its own edges the row sits.
    var horizontalInset: CGFloat = HeaderFade.titleInset
    /// The width to divide, where the caller already knows it.
    var fixedWidth: CGFloat?
    @ViewBuilder var menu: Menu

    /// Whether the other kind of shuffle is being offered — see
    /// `shuffleControl`.
    @State private var offeringAlternative = false

    /// The share of the room each takes, in the proportion the design asks
    /// for. Written as the numbers themselves rather than as fractions, so
    /// changing one does not mean re-deriving the other.
    private static var playShare: CGFloat { 1.7 }
    private static var shuffleShare: CGFloat { 1.1 }
    private static var height: CGFloat { 50 }
    /// Small enough to stand beside two lines of text without towering over
    /// them, big enough to stay a comfortable target.
    private static var compactSide: CGFloat { 44 }
    private static var gap: CGFloat { 10 }
    private static var corner: CGFloat { 14 }

    var body: some View {
        switch layout {
        case .labelled: labelledRow
        case .compact: compactRow
        }
    }

    /// Three squares, aligned from the right, for a line that is shared.
    private var compactRow: some View {
        HStack(spacing: Self.gap) {
            square(systemImage: "play.fill", solid: true, label: "Play", action: onPlay)
            shuffleControl { squareLabel(systemImage: "shuffle", solid: false) }
                .modifier(interactiveDimming)
                .accessibilityLabel("Shuffle")
            menu
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .frame(width: Self.compactSide, height: Self.compactSide)
                .background(quiet, in: .rect(cornerRadius: Self.corner))
        }
    }

    private func square(
        systemImage: String,
        solid: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            squareLabel(systemImage: systemImage, solid: solid)
        }
        .modifier(interactiveDimming)
        .accessibilityLabel(label)
    }

    /// A square's face, without deciding what pressing it does — so the
    /// shuffle one can wear the same face on a menu instead of a button.
    private func squareLabel(systemImage: String, solid: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(solid ? palette.background : palette.foreground)
            .frame(width: Self.compactSide, height: Self.compactSide)
            .background(
                solid ? AnyShapeStyle(palette.foreground) : AnyShapeStyle(quiet),
                in: .rect(cornerRadius: Self.corner)
            )
    }

    private var labelledRow: some View {
        Group {
            if let fixedWidth {
                row(dividing: fixedWidth)
            } else {
                MeasuredWidth { width in row(dividing: width) }
            }
        }
    }

    private func row(dividing width: CGFloat) -> some View {
        let room = max(0, width - horizontalInset * 2 - Self.gap * 2 - Self.height)
        let unit = room / (Self.playShare + Self.shuffleShare)
        return HStack(spacing: Self.gap) {
            play
                .frame(width: unit * Self.playShare)
            shuffle
                .frame(width: unit * Self.shuffleShare)
            menuButton
        }
        .frame(height: Self.height)
        .padding(.horizontal, horizontalInset)
        // Close under the words — they belong to the same block — and a
        // clear step before what follows, which is a different one.
        .padding(.top, 8)
        .padding(.bottom, bottomGap)
    }

    /// The solid one. Its label takes the *page's* colour rather than a fixed
    /// black: on a page the artwork made pale, the button is dark and the
    /// words on it have to be light, which is the same rule the other way up.
    private var play: some View {
        Button(action: onPlay) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Play")
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(palette.background)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.foreground, in: .rect(cornerRadius: Self.corner))
        }
        .modifier(interactiveDimming)
    }

    private var shuffle: some View {
        shuffleControl {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                Text("Shuffle")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(quiet, in: .rect(cornerRadius: Self.corner))
        }
        .modifier(interactiveDimming)
    }

    /// Shuffle: a plain button where there is nothing else to offer, and one that also holds the
    /// other kind where there is.
    @ViewBuilder
    private func shuffleControl(@ViewBuilder label: () -> some View) -> some View {
        if let alternative = alternativeShuffle {
            label()
                .contentShape(.rect)
                // Gestures rather than a `Button`, which is what made the
                // same arrangement unreliable on the mini player: a button
                // consumes the press, so the hold never arrived.
                .onTapGesture { onShuffle() }
                .onLongPressGesture(minimumDuration: 0.4) { offeringAlternative = true }
                .popover(isPresented: $offeringAlternative, arrowEdge: .bottom) {
                    Button {
                        offeringAlternative = false
                        alternative.action()
                    } label: {
                        Label(alternative.title, systemImage: alternative.icon)
                            .font(.system(size: 16))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .contentShape(.rect)
                    }
                    // The row's own wash would otherwise spread onto the
                    // icon — the same reset the "…" menus carry.
                    .tint(Color.primary)
                    .foregroundStyle(Color.primary)
                    // Without this a popover becomes a sheet on a phone,
                    // which is a great deal of screen for one line.
                    .presentationCompactAdaptation(.popover)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: alternative.title, alternative.action)
        } else {
            Button(action: onShuffle) { label() }
        }
    }

    /// The plain style, greyed and untappable while disabled — the three
    /// lines every button in this row shares, square or labelled.
    private var interactiveDimming: some ViewModifier {
        InteractiveDimming(isDisabled: isDisabled)
    }

    private var menuButton: some View {
        menu
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.foreground)
            .frame(width: Self.height, height: Self.height)
            .background(quiet, in: .rect(cornerRadius: Self.corner))
    }

    /// Struck from the page's own foreground, so it is a light wash on a dark
    /// page and a dark one on a light page. A fixed white would vanish
    /// against a pale cover.
    private var quiet: Color {
        palette.foreground.opacity(quietFill)
    }
}

/// The plain style, greyed and untappable while disabled.
private struct InteractiveDimming: ViewModifier {
    let isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
    }
}



extension Duration {
    /// A length said the way a person says it — "38 min", "20 hr 53 min" — rather than as a clock
    /// reading.
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr"
        }
        // A record under a minute long still has a length worth saying.
        return "\(max(1, minutes)) min"
    }
}
