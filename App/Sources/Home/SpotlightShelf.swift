import SwiftUI
import PleviDomain

/// One artist for the week: a full-bleed portrait, a hook from their own biography, and the five
/// records that made the case for them — company to `EditorsChoiceShelf`'s single day-old pick, on
/// a longer clock so there is room to actually work…
struct SpotlightShelf: View {
    let artist: Artist
    let albums: [Album]
    let bio: String?
    let libraryAlbumCount: Int?
    let history: [SpotlightStore.HistoryEntry]
    /// The scroll view's own width, measured once above every shelf on
    /// Home — see `HomeView.body`. Only the iPad pair below reads it; the
    /// phone's poster and list have never needed to know their own width.
    var knownWidth: CGFloat = 0

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Bucket-picking only, not a layout size — the photo now sizes itself
    // to the card's own width (see `photo`), which isn't known this early.
    // Any value whose Retina multiple clears the loader's top bucket works.
    private static let posterPhotoHint: CGFloat = 400
    private static let scrimColor = Color(red: 0.04, green: 0.04, blue: 0.055)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isWideLayout {
                widePair
            } else {
                poster
                topAlbums
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: iPad — wide layout gate

    /// Whether the shelf draws the side-by-side pair below instead of the phone's poster-then-list
    /// arrangement.
    private var isWideLayout: Bool {
        guard !dynamicTypeSize.isAccessibilitySize else { return false }
        guard horizontalSizeClass == .regular, verticalSizeClass == .regular else { return false }
        return knownWidth >= Self.wideWidth
    }

    private static let wideWidth: CGFloat = 760

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Spotlight")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.44)
            Spacer()
            NavigationLink(value: SpotlightArchiveRoute(history: history)) {
                Text("Archive")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 14)
    }

    // MARK: Poster

    /// The whole poster is one `NavigationLink`'s label — a button/link cannot correctly nest
    /// another one inside it, so Shuffle and Full biography cannot live in that label too.
    private var poster: some View {
        NavigationLink(value: artist) { posterVisual }
            .buttonStyle(SpotlightPressStyle())
            .overlay(alignment: .bottomLeading) {
                actionRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            // Flattened to one layer before the corner is cut, and this is load-bearing rather than
            // tidiness.
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var posterVisual: some View {
        VStack(alignment: .leading, spacing: 0) {
            photo
            scrimContent
        }
        .background(Self.scrimColor)
        // Without this, a tap on a transparent stretch of the poster misses
        // the link entirely, since a link only ever hit-tests where its
        // label actually draws something by default.
        .contentShape(Rectangle())
    }

    /// The photo, shown clean the same way `ImmersiveHeader` shows an artist's picture, rather than
    /// carrying the title and bio over the top of it.
    private var photo: some View {
        ZStack(alignment: .topLeading) {
            SpotlightPortrait(artwork: artist.artwork, pointHeight: Self.posterPhotoHint)
            chip.padding(16)
            // Only so the seam where the photo meets the solid card below
            // isn't a hard line — the photo is otherwise shown clean.
            LinearGradient(
                stops: [
                    .init(color: Self.scrimColor.opacity(0), location: 0),
                    .init(color: Self.scrimColor, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 72)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
        .aspectRatio(10 / 9, contentMode: .fit)
        .clipped()
    }

    private var chip: some View {
        Text("ARTIST OF THE WEEK")
            .font(.system(size: 11, weight: .bold))
            .tracking(1.32)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.2), in: Capsule())
    }

    private var scrimContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(artist.name)
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.64)
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(metaLine)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.top, 4)

            if let bio {
                Text(Self.hook(from: bio))
                    .font(.system(size: 14))
                    .lineSpacing(14 * 0.5)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.top, 8)
            }

            // Not the real controls — see `poster`.
            actionRow
                .padding(.top, 16)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            Button {
                MediaActions(app: app).playArtist(artist, shuffled: true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Shuffle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color(red: 0.067, green: 0.067, blue: 0.078))
                .padding(.leading, 15)
                .padding(.trailing, 18)
                .padding(.vertical, 10)
                .background(.white.opacity(0.94), in: Capsule())
            }
            .buttonStyle(.plain)

            NavigationLink(value: artist) {
                Text("Full biography")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
    }

    /// "26 albums in your library" — no birth or death years: neither Plex nor Subsonic surfaces
    /// them, and a card that shows a dash where a date belongs reads as broken rather than as a
    /// design choice.
    private var metaLine: String {
        guard let count = libraryAlbumCount else { return "" }
        return count == 1 ? "1 album in your library" : "\(count) albums in your library"
    }

    /// The bio hook is one sentence, shorter than `EditorsChoiceShelf`'s
    /// own review excerpt — this sits over a photograph, not a page
    /// background, and has far less room to stay readable in.
    private static func hook(from biography: String) -> String {
        EditorsChoice.excerpt(from: biography, limit: 130)
    }

    // MARK: Top albums

    private var topAlbums: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Top albums")
                .font(.system(size: 18, weight: .bold))
                .tracking(-0.18)
                .padding(.top, 22)

            ForEach(albums) { album in
                NavigationLink(value: album) {
                    TopAlbumRow(album: album)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - iPad — side-by-side pair
    //
    // Everything below this line draws only behind `isWideLayout` and is
    // new for this redesign. `poster` and `topAlbums` above are the
    // phone's own views and are not called from here — this is a second,
    // independent arrangement of the same artist and albums, not a
    // restyling of those two.

    private var widePair: some View {
        HStack(alignment: .top, spacing: 20) {
            wideArtistCard
                .frame(maxWidth: .infinity)
            wideAlbumsCard
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 420)
    }

    /// The artist half of the pair: the same photo, chip, biography hook and actions the phone's
    /// `poster` already draws, recomposed as a full-bleed card with the words over the photograph
    /// instead of on a solid block beneath it — the shape the…
    private var wideArtistCard: some View {
        NavigationLink(value: artist) { wideArtistVisual }
            .buttonStyle(SpotlightPressStyle())
            .overlay(alignment: .bottomLeading) {
                // The real Shuffle and Full biography controls — see the invisible copy inside
                // `wideArtistVisual`, which only reserves their space.
                actionRow
                    .padding(.horizontal, 28)
                    .padding(.bottom, 26)
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 2)
    }

    private var wideArtistVisual: some View {
        ZStack(alignment: .topLeading) {
            SpotlightPortrait(artwork: artist.artwork, pointHeight: Self.posterPhotoHint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Clear at the top, where the chip sits on its own material, to solid near-black at the
            // foot, where the words need it — `Self.scrimColor` rather than plain black so this
            // reads as the same surface the phone's solid block below the photo…
            LinearGradient(
                stops: [
                    .init(color: Self.scrimColor.opacity(0), location: 0),
                    .init(color: Self.scrimColor.opacity(0.82), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            chip.padding(16)

            VStack(alignment: .leading, spacing: 0) {
                Text(artist.name)
                    .font(.system(size: 38, weight: .bold))
                    .tracking(-0.76)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(metaLine)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)

                if let bio {
                    Text(Self.hook(from: bio))
                        .font(.system(size: 14.5))
                        .lineSpacing(14.5 * 0.55)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .frame(maxWidth: 440, alignment: .leading)
                        .padding(.top, 8)
                }

                // Not the real controls — see `wideArtistCard`'s overlay.
                // Present only so this block reserves exactly the height
                // and width they need.
                actionRow
                    .padding(.top, 16)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(minHeight: 420, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// The albums half of the pair: the same five rows `topAlbums` already lists, given a card of
    /// their own — a background, a heading row and a closing link, none of which the phone's
    /// borderless list needs beside a poster that already carries the…
    private var usesCriticRating: Bool {
        app.provider?.capabilities.contains(.criticRatings) == true
    }

    private var wideAlbumsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Top albums")
                    .font(.system(size: 19, weight: .bold))
                Spacer()
                // Which rating, rather than whose.
                Text(usesCriticRating ? "by critic rating" : "by your rating")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                    NavigationLink(value: album) {
                        WideTopAlbumRow(album: album)
                    }
                    .buttonStyle(.plain)
                    if index < albums.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                            .frame(height: 1)
                    }
                }
            }
            .padding(.top, 18)

            Spacer(minLength: 12)

            NavigationLink(value: artist) {
                Text(seeAllAlbumsLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 420, maxHeight: .infinity)
        .background(wideCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 2)
    }

    private var seeAllAlbumsLabel: String {
        guard let count = libraryAlbumCount else { return "See all albums" }
        return "See all \(count) album\(count == 1 ? "" : "s")"
    }

    /// The albums card's own ground — the same two colours
    /// `EditorsChoiceShelf.surface` sits its card on, so Home's two big
    /// cards read as one design language rather than two.
    private var wideCardSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.11)
            : Color(red: 0.945, green: 0.945, blue: 0.957)
    }
}

/// One row of the five — cover, title and year, and the rating that put it
/// here, on whichever scale actually rated it.
private struct TopAlbumRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(artwork: album.artwork, size: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let year = album.year {
                    Text(String(year))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let rating {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                    Text(rating)
                        .monospacedDigit()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        // The same reason the poster above needs one: a link hit-tests only where its label
        // actually draws.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The critic score where there is one, said out of ten exactly as stored; a listener's own
    /// stars, out of five, where there is not.
    private var rating: String? {
        if let critic = album.criticRating {
            return "\(Self.wholeOrOneDecimal(critic))/10"
        }
        if let stars = album.rating {
            return "\(Self.wholeOrOneDecimal(stars.value))/5"
        }
        return nil
    }

    private var accessibilityLabel: String {
        var label = album.displayName
        if let year = album.year { label += ", \(year)" }
        if let critic = album.criticRating {
            label += ", critic rating \(Self.wholeOrOneDecimal(critic)) out of 10"
        } else if let stars = album.rating {
            label += ", \(Self.wholeOrOneDecimal(stars.value)) out of 5 stars"
        }
        return label
    }

    /// `fileprivate` rather than `private`: `WideTopAlbumRow` below formats
    /// the same two rating scales for the iPad card and reuses this rather
    /// than a second copy of it.
    fileprivate static func wholeOrOneDecimal(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }
}

/// The same row `TopAlbumRow` draws, sized for the iPad card instead of the phone's list — a
/// smaller cover, and a title that wraps to a second line rather than truncating, since the card
/// has a fixed row height to spend on it rather than a…
private struct WideTopAlbumRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(artwork: album.artwork, size: 48, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let year = album.year {
                    Text(String(year))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if let rating {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                    Text(rating)
                        .monospacedDigit()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 68)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Same two scales as `TopAlbumRow.rating`, never converted between
    /// them — see that property.
    private var rating: String? {
        if let critic = album.criticRating {
            return "\(TopAlbumRow.wholeOrOneDecimal(critic))/10"
        }
        if let stars = album.rating {
            return "\(TopAlbumRow.wholeOrOneDecimal(stars.value))/5"
        }
        return nil
    }

    private var accessibilityLabel: String {
        var label = album.displayName
        if let year = album.year { label += ", \(year)" }
        if let critic = album.criticRating {
            label += ", critic rating \(TopAlbumRow.wholeOrOneDecimal(critic)) out of 10"
        } else if let stars = album.rating {
            label += ", \(TopAlbumRow.wholeOrOneDecimal(stars.value)) out of 5 stars"
        }
        return label
    }
}

/// Artist artwork for the poster, loaded and bucketed the way `ArtworkView` loads any other cover —
/// this exists separately from it only because `ArtworkView` always draws a fixed, caller-known
/// size, and this one sizes itself to whatever frame…
private struct SpotlightPortrait: View {
    let artwork: ArtworkID?
    let pointHeight: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    /// The photograph if it is already in memory, asked without awaiting — see the same property on
    /// `EditorsChoiceWideArtwork`, and the note on `ArtworkView.alreadyInMemory` that both come
    /// from.
    private var alreadyInMemory: UIImage? {
        guard let artwork, let loader = app.artwork else { return nil }
        return loader.cachedImage(
            for: artwork,
            bucket: ArtworkLoader.bucket(forPointSize: pointHeight, scale: displayScale)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ArtworkPlaceholder.artist.fill()
                if let image = image ?? alreadyInMemory {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .clipped()
                        .transition(.opacity)
                } else {
                    ArtworkPlaceholder.artist.glyph()
                        .font(.system(size: pointHeight * 0.2))
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: taskKey) {
            guard let artwork, let loader = app.artwork else { return }
            let bucket = ArtworkLoader.bucket(forPointSize: pointHeight, scale: displayScale)
            let hadOne = image ?? alreadyInMemory
            let loaded = await loader.image(for: artwork, bucket: bucket)
            guard !Task.isCancelled else { return }
            if hadOne == nil {
                withAnimation(.easeIn(duration: 0.15)) { image = loaded }
            } else {
                image = loaded
            }
        }
    }

    private var taskKey: String {
        let subject = artwork.map { "\($0.rawValue)|\(Int(pointHeight))" } ?? "none"
        let server = app.servers.activeServerID?.rawValue.uuidString ?? "no-server"
        return "\(subject)|\(server)|\(app.artworkStage)"
    }
}

/// The press treatment the poster shares with `EditorsChoiceShelf`'s own
/// card: the whole thing shrinks slightly.
private struct SpotlightPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
