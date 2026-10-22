import SwiftUI
import PleviDomain

/// One well-reviewed record a day, art first, then what somebody wrote about it.
struct EditorsChoiceShelf: View {
    let album: Album
    /// The scroll view's own width, measured once above every shelf on
    /// Home — see `HomeView.body`. Only the iPad card below reads it; the
    /// phone card has never needed to know its own width.
    var knownWidth: CGFloat = 0

    /// Whether either half of the wide card is being pressed — see
    /// `wideCard`, which is what actually moves.
    @State private var isPressed = false

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// How tall the words under the sleeve came out — the title runs to two
    /// lines often enough that this cannot be assumed.
    @State private var textHeight: CGFloat = 0

    /// How far the fade takes to arrive at the card's own colour.
    private static let fadeRamp: CGFloat = 130

    /// The fade is the ramp plus however much room the words need, so the
    /// solid part always starts above the first line of them.
    private var fadeHeight: CGFloat {
        Self.fadeRamp + max(textHeight, 0) + 12
    }

    /// Where in that fade the card's own colour has fully arrived.
    private var rampShare: CGFloat {
        min(max(Self.fadeRamp / max(fadeHeight, 1), 0.05), 0.95)
    }

    /// The card's own ground, a step off the page — the surface the sleeve
    /// fades into, so the join is invisible.
    private var surface: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.11)
            : Color(red: 0.945, green: 0.945, blue: 0.957)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private var header: some View {
        Text("Editors' Choice")
            .font(.system(size: 22, weight: .bold))
            .tracking(-0.44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 14)
    }

    /// The phone's own card, completely untouched, for every window that
    /// fails `isWideLayout` — which includes every iPhone, since the app is
    /// portrait-only there and a phone is always compact horizontally.
    @ViewBuilder
    private var content: some View {
        if isWideLayout {
            wideCard
        } else {
            NavigationLink(value: album) { card }
                .buttonStyle(PressedCardStyle())
        }
    }

    // MARK: iPad — wide layout gate

    /// Whether the shelf draws the two-column editorial card below instead of the phone's card
    /// above.
    private var isWideLayout: Bool {
        guard !dynamicTypeSize.isAccessibilitySize else { return false }
        guard horizontalSizeClass == .regular, verticalSizeClass == .regular else { return false }
        return knownWidth >= Self.wideWidth
    }

    /// Under an iPad's 834-point portrait width, and well over a half-width
    /// Split View pane on a 13-inch, which is about 507.
    private static let wideWidth: CGFloat = 800

    /// How much of the card the sleeve takes.
    private var wideSleeveWidth: CGFloat {
        min(440, knownWidth * 0.40)
    }

    // MARK: The card

    private var card: some View {
        VStack(spacing: 0) {
            artworkBlock
            reviewBlock
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The sleeve at the card's full width, with the words sitting in the
    /// fade at the bottom of it.
    private var artworkBlock: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack(alignment: .bottomLeading) {
                ArtworkView(artwork: album.artwork, size: side, cornerRadius: 0)
                    .frame(width: side, height: side)

                // Pinned to the bottom and running a little past it, so the sleeve arrives at the
                // card's own colour with no hairline where the two meet.
                LinearGradient(
                    stops: [
                        .init(color: surface.opacity(0), location: 0),
                        .init(color: surface, location: rampShare),
                        .init(color: surface, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: fadeHeight)
                .padding(.bottom, -1)

                titleGroup
                    .padding(.horizontal, 20)
                    .padding(.bottom, 2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        textHeight = $0
                    }
            }
            .frame(width: side, height: side)
            .clipped()
        }
        // Square, so the sleeve is shown whole at any width — the card's
        // inner width and its artwork height are the same number.
        .aspectRatio(1, contentMode: .fit)
    }

    private var titleGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                // A step brighter than the design's tertiary.
                Text(Self.dateLabel.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.43)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            Text(album.displayName)
                .font(.system(size: 27, weight: .bold))
                .tracking(-0.54)
                .lineSpacing(-2)
                .foregroundStyle(.primary)
                .lineLimit(2)

            // The score the record was chosen on, said in the same breath as
            // who made it and when.
            HStack(spacing: 5) {
                Text(credit)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let score = album.criticRating {
                    Text(verbatim: "·")
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                        Text("\(Self.score(score))/10")
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(creditForVoiceOver)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var credit: String {
        let artist = album.artistName ?? "Unknown Artist"
        guard let year = album.year else { return artist }
        return "\(artist) · \(String(year))"
    }

    private var creditForVoiceOver: String {
        guard let score = album.criticRating else { return credit }
        return "\(credit). Critic rating \(Self.score(score)) out of 10"
    }

    /// Today, as the card says it: "FRIDAY 29 AUG".
    private static var dateLabel: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        return formatter.string(from: .now)
    }

    /// The writing, and nothing under it.
    @ViewBuilder
    private var reviewBlock: some View {
        if let review = album.review, !review.isEmpty {
            Text(EditorsChoice.excerpt(from: review))
                .font(.system(size: 16))
                .lineSpacing(16 * 0.55)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
    }

    /// Out of ten, to one place, without a trailing zero doing nothing.
    private static func score(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }

    // MARK: - iPad — wide card
    //
    // Everything below this line draws only behind `isWideLayout` and is
    // new for this redesign. Nothing above it — the phone's own `card` and
    // everything that builds it — is touched.

    private var wideCard: some View {
        HStack(spacing: 0) {
            wideTextColumn
            wideArtwork
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 2)
        // The press is the card's, not each half's.
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    /// The write-up, as one `NavigationLink`, with Play and the overflow menu drawn again on top as
    /// real controls once the label has reserved their space — the same split
    /// `SpotlightShelf.poster` makes for Shuffle and Full biography, and for the…
    private var wideTextColumn: some View {
        NavigationLink(value: album) { wideTextVisual }
            .buttonStyle(PressReportingStyle(isPressed: $isPressed))
            .overlay(alignment: .bottomTrailing) {
                wideActions
                    .padding(.trailing, 44)
                    .padding(.bottom, 42)
            }
    }

    private var wideTextVisual: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                wideEyebrow
                wideTitleGroup
                    .padding(.top, 12)
                wideBody
                    .padding(.top, 20)
            }
            Spacer(minLength: 24)
            wideBottomGroup
        }
        .padding(.vertical, 42)
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var wideEyebrow: some View {
        // The phone card's own date, read again rather than reformatted — `dateLabel` already
        // renders "FRIDAY 29 AUG" with no comma, and a second formatter built just to add one would
        // only mean the two cards could someday disagree about what today…
        Text("\(Self.dateLabel.uppercased()) · ALBUM OF THE DAY")
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(.secondary)
    }

    /// The review, and now the only writing on the card.
    @ViewBuilder
    private var wideBody: some View {
        if let review = album.review, !review.isEmpty {
            Text(EditorsChoice.excerpt(from: review, limit: 520))
                .font(.system(size: 17))
                .lineSpacing(17 * 0.6)
                .foregroundStyle(.primary)
                .lineLimit(9)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }

    /// What the record is, directly under what day it is.
    private var wideTitleGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(album.displayName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            wideMetaLine
        }
    }

    /// Nothing but the room the controls need.
    private var wideBottomGroup: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            wideActions
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The same credit and critic score the phone card already reads for
    /// VoiceOver — see `credit` and `creditForVoiceOver` — restyled at the
    /// wide card's own size.
    private var wideMetaLine: some View {
        HStack(spacing: 5) {
            Text(credit)
                .lineLimit(1)
            if let score = album.criticRating {
                Text(verbatim: "·")
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                    Text("\(Self.score(score))/10")
                        .monospacedDigit()
                }
                .fixedSize()
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(creditForVoiceOver)
    }

    /// Play and the overflow menu — the card's only controls that are not "go to this album", so
    /// they cannot live inside the link that already means that.
    private var wideActions: some View {
        HStack(spacing: 10) {
            Button {
                MediaActions(app: app).playAlbum(album)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 22)
                .frame(height: 46)
                .background(Color(.label), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(album.displayName)")

            Menu {
                AlbumMenuContent(album: album, actions: MediaActions(app: app))
                    .tint(Color.primary)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 46, height: 46)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .accessibilityLabel("More")
        }
    }

    /// The sleeve filling the card's fixed right column edge to edge.
    private var wideArtwork: some View {
        NavigationLink(value: album) {
            EditorsChoiceWideArtwork(artwork: album.artwork)
                .frame(width: wideSleeveWidth)
                .frame(minHeight: 430, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(PressReportingStyle(isPressed: $isPressed))
        .accessibilityHidden(true)
    }
}

/// Reports a press upward instead of answering it, so a card made of two
/// links can shrink as one thing.
private struct PressReportingStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

/// The press treatment the design asks for: the whole card shrinks slightly.
private struct PressedCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The sleeve for the wide card's right column, loaded the way `ArtworkView` loads any other cover
/// — this exists separately only because `ArtworkView` always draws a fixed square, and this column
/// is 440 wide by whatever the card's own height…
private struct EditorsChoiceWideArtwork: View {
    let artwork: ArtworkID?

    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    /// Bucket-picking only, not a layout size — see the same note on
    /// `SpotlightShelf.posterPhotoHint`.
    private static let pointHint: CGFloat = 440

    /// The sleeve if it is already in memory, asked without awaiting.
    private var alreadyInMemory: UIImage? {
        guard let artwork, let loader = app.artwork else { return nil }
        return loader.cachedImage(
            for: artwork,
            bucket: ArtworkLoader.bucket(forPointSize: Self.pointHint, scale: displayScale)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ArtworkPlaceholder.music.fill()
                if let image = image ?? alreadyInMemory {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if artwork == nil {
                    ArtworkPlaceholder.music.glyph()
                        .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.35))
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: taskKey) {
            guard let artwork, let loader = app.artwork else { return }
            let bucket = ArtworkLoader.bucket(forPointSize: Self.pointHint, scale: displayScale)
            // No fade over a picture already on screen — that is the same
            // sleeve arriving twice, and it reads as a flicker.
            let hadOne = image ?? alreadyInMemory
            let loaded = await loader.image(for: artwork, bucket: bucket)
            guard !Task.isCancelled else { return }
            if hadOne == nil {
                withAnimation(.easeIn(duration: 0.15)) { image = loaded }
            } else {
                image = loaded
            }
            if let loaded {
                PaletteLoader.warm(artwork, from: loaded, bucket: bucket)
            }
        }
    }

    private var taskKey: String {
        let subject = artwork.map { "\($0.rawValue)|\(Int(Self.pointHint))" } ?? "none"
        let server = app.servers.activeServerID?.rawValue.uuidString ?? "no-server"
        return "\(subject)|\(server)|\(app.artworkStage)"
    }
}
