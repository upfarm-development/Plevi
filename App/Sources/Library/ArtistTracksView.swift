import SwiftUI
import PleviDomain

/// The long form of a song shelf on an artist's page: everything the shelf only had room to sample.
struct ArtistTracksView: View {
    enum Kind {
        /// Most played, the long version of Popular.
        case popular
        /// Everything by this artist you have rated, best first.
        case rated

        var title: String {
            switch self {
            case .popular: "Popular"
            case .rated: "My Favourites"
            }
        }

        /// Popular is a chart, and a chart with a hundred places is not one.
        var limit: Int {
            switch self {
            case .popular: 30
            case .rated: 500
            }
        }
    }

    @Environment(AppModel.self) private var app
    let artist: Artist
    let kind: Kind

    @State private var tracks: [Track] = []
    @State private var palette = PaletteLoader()

    private var actions: MediaActions { MediaActions(app: app) }

    /// The same setting the album page and playlists follow.
    private var rowStyle: TrackRowStyle {
        app.settings.trackRowStyle
    }

    private func showsRating(for track: Track) -> Bool {
        app.settings.ratingVisibility.showsInOtherLists
            && (app.provider?.capabilities.contains(.ratings) ?? false)
            && app.settings.showsStars(for: track.rating)
    }

    private var allowsHalfStars: Bool {
        app.provider?.capabilities.contains(.halfStarRatings) ?? false
    }

    private var style: PageStyle {
        app.settings.pageStyle
    }

    private var colors: ArtworkPalette {
        .forPage(style, artwork: palette.palette)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    row(track, position: index + 1, at: index)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background { PageBackground(style: style, artwork: palette.palette) }
        .toolbarColorScheme(colors.chromeScheme, for: .navigationBar)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView(
                    kind == .rated ? "Nothing rated yet" : "Nothing played yet",
                    systemImage: kind == .rated ? "star" : "chart.bar",
                    description: Text(
                        kind == .rated
                            ? "Songs you rate by \(artist.name) collect here."
                            : "Songs you play by \(artist.name) collect here."
                    )
                )
            }
        }
        .task(id: app.libraryVersion) { load() }
        .task(id: artist.artwork?.rawValue) {
            await palette.load(artwork: artist.artwork, using: app.artwork)
        }
    }

    private func row(_ track: Track, position: Int, at index: Int) -> some View {
        HStack(spacing: 10) {
            Text(String(position))
                .font(rowStyle.numberFont.monospacedDigit())
                .foregroundStyle(colors.secondaryForeground)
                // Wide enough for two digits at the larger size, or "10"
                // breaks over two lines. Three digits are shrunk to fit.
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: rowStyle == .numbered ? 28 : 20, alignment: .trailing)

            ArtworkView(artwork: track.artwork, size: 40, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(rowStyle.titleFont)
                    .foregroundStyle(colors.foreground)
                    .lineLimit(1)
                // Second line carries the album and the stars, as on an album
                // page; the single-star style sits inline at the other end.
                HStack(spacing: 8) {
                    if rowStyle.durationBesideArtist, let duration = track.duration {
                        Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                            .font(.footnote)
                            .foregroundStyle(colors.secondaryForeground)
                            .monospacedDigit()
                    }
                    if let album = track.albumName {
                        Text(album)
                            .font(.footnote)
                            .foregroundStyle(colors.secondaryForeground)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if showsRating(for: track),
                       app.settings.ratingStyle != .singleStar,
                       !rowStyle.ratingAsNumber {
                        rating(for: track)
                    }
                }
            }

            Spacer(minLength: 4)

            if rowStyle.ratingAsNumber {
                if showsRating(for: track) {
                    RatingSummaryButton(
                        track: track,
                        palette: colors,
                        font: rowStyle.durationFont,
                        showsBars: rowStyle.ratingAsBars
                    )
                }
            } else if showsRating(for: track), app.settings.ratingStyle == .singleStar {
                rating(for: track)
            }

            TrackTrailing(
                duration: track.duration,
                isCurrent: app.activePlayer.currentTrack?.id == track.id,
                showsDuration: !rowStyle.durationBesideArtist,
                font: rowStyle.durationFont,
                palette: colors
            )
        }
        .padding(.vertical, rowStyle.verticalPadding)
        // On the row, not behind it — see the album page's list.
        .contentShape(Rectangle())
        .onTapGesture { app.activePlayer.play(tracks, startingAt: index, from: .artist) }
        .trackContextMenu(track, actions: actions)
    }

    private func rating(for track: Track) -> some View {
        StarRatingControl(
            rating: track.rating,
            style: app.settings.ratingStyle,
            allowsHalfStars: allowsHalfStars,
            palette: colors,
            size: 12
        ) { newRating in
            actions.setRating(newRating, id: track.id)
        }
    }

    private func load() {
        guard let index = app.libraryIndex else { return }
        switch kind {
        case .popular:
            // The server's own popularity first — Plex ships a `ratingCount` with its music
            // metadata and Subsonic servers can answer from Last.fm, and either is a better answer
            // than "what this phone has played".
            let cached = (try? index.cachedArtistPage(for: artist.id))??.topTracks ?? []
            tracks = cached.isEmpty
                ? (try? index.topTracks(forArtist: artist.id, limit: kind.limit)) ?? []
                : Array(cached.prefix(kind.limit))
        case .rated:
            tracks = (try? index.ratedTracks(forArtist: artist.id, limit: kind.limit)) ?? []
        }
    }
}
