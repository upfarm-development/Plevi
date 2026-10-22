import SwiftUI
import PleviDomain

/// A song's rating as a number with one star after it — `2.5 ★` — which opens the full five-star
/// control when tapped.
struct RatingSummaryButton: View {
    let track: Track
    var palette: ArtworkPalette = .neutral
    /// Set to whatever the duration beside it uses, so the row reads as one
    /// line rather than two sizes side by side.
    var font: Font = .subheadline
    /// Ten bars instead of a number and a star. Ten is not a decoration: it
    /// is the scale the server stores, so a bar is exactly half a star and
    /// the shape down a list is the ratings themselves.
    var showsBars = false

    @Environment(AppModel.self) private var app
    @State private var isRating = false

    private var allowsHalfStars: Bool {
        app.provider?.capabilities.contains(.halfStarRatings) ?? false
    }

    /// The rating style from settings, with no exception made here: one
    /// star, five, or five with half steps means the same thing wherever a
    /// song can be rated.
    private var popoverStyle: RatingStyle {
        app.settings.ratingStyle
    }

    var body: some View {
        Button {
            isRating = true
        } label: {
            Group {
                if showsBars {
                    bars
                } else {
                    HStack(spacing: 3) {
                        if let rating = track.rating {
                            Text(Self.ratingText(rating.value))
                                .monospacedDigit()
                                // Never wrapped: the column is fixed, and "4.5"
                                // broken over two lines is what that costs.
                                .fixedSize()
                        }
                        Image(systemName: track.rating == nil ? "star" : "star.fill")
                    }
                    .font(font)
                    .foregroundStyle(
                        track.rating == nil ? palette.secondaryForeground : palette.foreground
                    )
                }
            }
            // A fixed column aligned to its right, so the ratings line up down
            // the list however wide each one is.
            .frame(width: showsBars ? 46 : 52, alignment: .trailing)
            // The whole column takes the tap, not just the star glyph. Only
            // the glyph was hit-testable at first, so a near miss fell through
            // to the row behind and played the song.
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            track.rating.map { "Rated \(Self.ratingText($0.value)) stars" } ?? "Not rated"
        )
        .accessibilityHint("Opens the rating control")
        .popover(isPresented: $isRating) {
            VStack(spacing: 10) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                StarRatingControl(
                    rating: track.rating,
                    style: popoverStyle,
                    allowsHalfStars: allowsHalfStars,
                    // The popover has the system's own background, so the
                    // page's colours would be invisible on it.
                    palette: .neutral,
                    size: 28,
                    // Room to slide here, unlike a track row: this control is
                    // alone on a popover with nothing behind it to scroll.
                    allowsDragging: true
                ) { newRating in
                    MediaActions(app: app).setRating(newRating, id: track.id)
                    isRating = false
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            // Without this a popover becomes a sheet on iPhone, which is a lot
            // of screen for five stars.
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Ten bars, filled from the left, one per half star.
    private var bars: some View {
        let filled = Int(((track.rating?.value ?? 0) * 2).rounded())
        return HStack(spacing: 1.5) {
            ForEach(0..<10, id: \.self) { index in
                Capsule()
                    .fill(
                        index < filled
                            ? palette.foreground
                            : palette.foreground.opacity(0.22)
                    )
                    .frame(width: 2.5, height: index < filled ? 14 : 9)
            }
        }
        .frame(height: 16)
    }

    /// `4.5`, but `4` rather than `4.0` — the half is what needs saying.
    static func ratingText(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}
