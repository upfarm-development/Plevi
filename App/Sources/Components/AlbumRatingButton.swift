import SwiftUI
import PleviDomain

/// Rates a whole album from its header, beside Play and Shuffle.
struct AlbumRatingButton: View {
    let rating: StarRating?
    let style: RatingStyle
    var palette: ArtworkPalette?
    /// Matches `PlayShuffleButtons`; see there.
    var size: ControlMetrics.Size = .large
    /// Whether the *server* can store halves; see `StarRatingControl`.
    var allowsHalfStars = false
    let onSet: (StarRating?) -> Void

    @State private var showingPicker = false

    private var currentStars: Int {
        rating?.wholeStars ?? 0
    }

    private var value: Double {
        rating?.value ?? 0
    }

    private var halfStars: Bool {
        style.usesHalfStars && allowsHalfStars
    }

    private func symbol(for star: Int) -> String {
        if value >= Double(star) { return "star.fill" }
        if halfStars, value >= Double(star) - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }

    private var isRated: Bool {
        currentStars > 0
    }

    var body: some View {
        Button {
            if style == .singleStar {
                onSet(isRated ? nil : StarRating(stars: 1))
            } else {
                showingPicker = true
            }
        } label: {
            Image(systemName: isRated ? "star.fill" : "star")
                .font(ControlMetrics.font(size))
                .frame(width: ControlMetrics.side(size), height: ControlMetrics.side(size))
                .foregroundStyle(palette?.foreground ?? Color.accentColor)
        }
        .buttonStyle(.bordered)
        .controlSize(ControlMetrics.controlSize(size))
        .buttonBorderShape(.circle)
        .tint(palette.map { $0.foreground.opacity(0.22) } ?? Color.accentColor.opacity(0.15))
        .accessibilityLabel("Rate album")
        .accessibilityValue(isRated ? currentStars.counted("star") : "Not rated")
        .popover(isPresented: $showingPicker) {
            picker
                .presentationCompactAdaptation(.popover)
        }
    }

    private func pickerTarget(_ newValue: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                // Tapping the current value clears it, matching the rows.
                onSet(value == newValue ? nil : StarRating(newValue))
                showingPicker = false
            }
    }

    private var picker: some View {
        VStack(spacing: 14) {
            Text("Rate Album")
                .font(.headline)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: symbol(for: star))
                        .font(.title)
                        .foregroundStyle(value >= Double(star) - 0.5 ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                        // Two targets per star in half-step mode, as on the
                        // track rows: the left half sets the half.
                        .overlay {
                            if halfStars {
                                HStack(spacing: 0) {
                                    pickerTarget(Double(star) - 0.5)
                                    pickerTarget(Double(star))
                                }
                            } else {
                                pickerTarget(Double(star))
                            }
                        }
                        .accessibilityLabel(star.counted("star"))
                }
            }
            if isRated {
                Button("Clear Rating", role: .destructive) {
                    onSet(nil)
                    showingPicker = false
                }
                .font(.footnote)
            }
        }
        .padding(20)
    }
}
