import SwiftUI
import PleviDomain

/// The sizes every tappable thing on this app is built from.
enum WatchMetrics {
    /// A row in one of the menus.
    static let row: CGFloat = 60
    /// A song in a list. Shorter than a menu row — there are many more of
    /// them and they are read as a column — but still over the floor.
    static let track: CGFloat = 54
    /// Play and Shuffle at the top of a collection.
    static let pill: CGFloat = 56
    static let corner: CGFloat = 20
}

/// A menu row: an icon, a label, and a chevron.
struct WatchRow<Trailing: View>: View {
    let title: String
    var systemImage: String?
    var value: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
            }
            Text(title)
                .font(.system(size: 17))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            trailing
        }
        .frame(minHeight: WatchMetrics.row)
        .contentShape(Rectangle())
    }
}

extension WatchRow where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil, value: String? = nil) {
        self.init(title: title, systemImage: systemImage, value: value) { EmptyView() }
    }
}

/// A row naming a record, an artist or a playlist: a sleeve and one or two
/// lines.
struct WatchMediaRow: View {
    let title: String
    var subtitle: String?
    var artwork: ArtworkID?
    /// Drawn as a circle for an artist, a rounded square for everything else.
    var isRound = false

    var body: some View {
        HStack(spacing: 10) {
            WatchArtworkView(artwork: artwork, side: 40, isRound: isRound)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: WatchMetrics.row)
        .contentShape(Rectangle())
    }
}

/// A song in a list: its number, its title, its length.
struct WatchTrackRow: View {
    let track: Track
    var number: Int?
    /// Dimmed when there is no file for it on this watch and no server to
    /// fetch one from, so a list offline says which of it will actually play.
    var isUnavailable = false

    var body: some View {
        HStack(spacing: 10) {
            if let number {
                Text("\(number)")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
            }
            Text(track.displayTitle)
                .font(.system(size: 17))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let duration = track.duration {
                Text(Self.length(duration))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: WatchMetrics.track)
        .opacity(isUnavailable ? 0.4 : 1)
        .contentShape(Rectangle())
    }

    static func length(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A sleeve, fetched at the size it will be drawn.
struct WatchArtworkView: View {
    let artwork: ArtworkID?
    let side: CGFloat
    var isRound = false

    @Environment(WatchModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: isRound ? "music.mic" : "music.note")
                        .font(.system(size: side * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        // Keyed on the connection as well as the picture.
        .task(id: "\(artwork?.rawValue ?? "")-\(model.connectionKey)") { await load() }
    }

    /// `AnyShape` rather than a `@ViewBuilder`: a builder returns a
    /// conditional *view*, and a conditional view is not a `Shape`.
    private var shape: AnyShape {
        isRound
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: side < 60 ? 5 : 10, style: .continuous))
    }

    private func load() async {
        // A song with no cover clears the last one rather than keeping it.
        guard let artwork, let loader = model.artwork else {
            if self.artwork == nil { image = nil }
            return
        }
        let bucket = WatchArtwork.bucket(forPointSize: side)
        // Whatever is already in memory, in this frame, so a scrolling list
        // does not blink a grey square on every cell it reuses.
        if let cached = loader.cached(artwork, bucket: bucket) {
            image = cached
            return
        }
        image = await loader.image(for: artwork, bucket: bucket)
    }
}

/// Nothing here, said plainly and without apology.
struct WatchEmptyView: View {
    let title: String
    var detail: String?
    var systemImage: String = "music.note.list"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }
}
