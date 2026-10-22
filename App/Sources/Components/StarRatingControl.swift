import SwiftUI
import PleviDomain

/// Compact star rating for a track row.
struct StarRatingControl: View {
    let rating: StarRating?
    let style: RatingStyle
    /// Whether the *server* can store halves. Whether they are actually
    /// offered is that and the chosen style together, since a server that
    /// keeps halves is no reason to make someone aim at half a star.
    var allowsHalfStars = false
    /// Stars are drawn from the page's own text colour rather than the
    /// system's tertiary grey, which can all but disappear against a strongly
    /// coloured background.
    var palette: ArtworkPalette = .neutral
    /// Star size. The player wants these bigger than a track row does, and
    /// scaling the view up instead would leave the tap targets small — what
    /// you can hit has to grow with what you can see.
    var size: CGFloat?
    /// Lets a finger slide across the stars to rate, as well as tapping one.
    /// Off by default: inside a scrolling list a horizontal drag on a small
    /// control is as likely to be the start of a scroll as a rating.
    var allowsDragging = false
    let onSet: (StarRating?) -> Void

    /// What the stars are showing: the rating being dragged out if there is
    /// one, otherwise what is stored.
    @State private var dragValue: Double?
    @State private var rowWidth: CGFloat = 0

    private var value: Double {
        dragValue ?? rating?.value ?? 0
    }

    private var currentStars: Int {
        rating?.wholeStars ?? 0
    }

    private var halfStars: Bool {
        style.usesHalfStars && allowsHalfStars
    }

    private var spokenValue: String {
        guard value > 0 else { return "Not rated" }
        return value == value.rounded() ? Int(value).counted("star") : "\(value) stars"
    }

    var body: some View {
        switch style {
        case .fiveStars, .fiveStarsHalf:
            starRow
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rating")
            .accessibilityValue(spokenValue)
        case .singleStar:
            starButton(1, size: size ?? 13)
                .accessibilityLabel(currentStars > 0 ? "Rated" : "Not rated")
        }
    }

    @ViewBuilder
    private var starRow: some View {
        let stars = HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                starButton(star, size: size ?? 10)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }

        if allowsDragging {
            // A distance rather than none, so a still finger is still a tap:
            // the taps belong to the stars themselves and only movement means
            // "drag me a rating".
            stars.gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { drag in
                        // Sideways only. On Now Playing this control sits in a
                        // list that scrolls to the queue, and a finger moving
                        // down the screen means scroll, not "rate me two".
                        guard abs(drag.translation.width) > abs(drag.translation.height) else {
                            return
                        }
                        dragValue = draggedRating(atX: drag.location.x)
                    }
                    .onEnded { drag in
                        guard dragValue != nil else { return }
                        let chosen = draggedRating(atX: drag.location.x)
                        dragValue = nil
                        onSet(StarRating(chosen))
                    }
            )
        } else {
            stars
        }
    }

    /// Where along the row the finger is, as a rating.
    private func draggedRating(atX x: CGFloat) -> Double {
        guard rowWidth > 0 else { return value }
        let fraction = min(max(x / rowWidth, 0), 1)
        let raw = fraction * 5
        if halfStars {
            return min(5, max(0.5, (raw * 2).rounded(.up) / 2))
        }
        return min(5, max(1, raw.rounded(.up)))
    }

    /// `star.fill`, `star.leadinghalf.filled` or `star`, for this position.
    private func symbol(for star: Int) -> String {
        if value >= Double(star) { return "star.fill" }
        if halfStars, value >= Double(star) - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }

    private func starButton(_ star: Int, size: CGFloat) -> some View {
        Image(systemName: symbol(for: star))
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(
                value >= Double(star) - 0.5
                    ? palette.foreground
                    : palette.foreground.opacity(0.45)
            )
            .frame(width: size + 8, height: size + 8)
            .contentShape(Rectangle())
            // Two targets per star where the server stores halves, so the left of a star is the
            // half and the right is the whole.
            .overlay {
                if halfStars {
                    HStack(spacing: 0) {
                        tapTarget(setting: Double(star) - 0.5)
                        tapTarget(setting: Double(star))
                    }
                } else {
                    tapTarget(setting: Double(star))
                }
            }
    }

    private func tapTarget(setting newValue: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                // Tapping the value already set clears it, which is the only
                // way to unrate without a separate control.
                onSet(value == newValue ? nil : StarRating(newValue))
            }
    }
}
