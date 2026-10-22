import SwiftUI
import PleviDomain

/// The Home shelf of things kept there on purpose.
struct PinnedShelf: View {
    let cards: [PinnedCard]

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(HomeSection.pinned.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(cards) { card in
                        destination(for: card)
                            .contextMenu {
                                // A pinned album or artist offers everything it does anywhere else
                                // — the unpin is already in those menus, as the pin is elsewhere —
                                // rather than this one place reading as just "Unpin".
                                switch card.resolved {
                                case .album(let album):
                                    AlbumMenuContent(album: album, actions: MediaActions(app: app))
                                case .artist(let artist):
                                    ArtistMenuContent(artist: artist, actions: MediaActions(app: app))
                                case .collection(let collection):
                                    // A pinned collection offers what a
                                    // collection offers anywhere else, plus the
                                    // unpin every pinned card has.
                                    ControlGroup {
                                        Button("Play", systemImage: "play.fill") {
                                            MediaActions(app: app)
                                                .playCollection(collection, shuffled: false)
                                        }
                                        Button("Shuffle", systemImage: "shuffle") {
                                            MediaActions(app: app)
                                                .playCollection(collection, shuffled: true)
                                        }
                                    }
                                    .controlGroupStyle(.compactMenu)
                                    Button("Unpin from Home", systemImage: "pin.slash") {
                                        app.pins.unpin(card.item)
                                    }
                                default:
                                    Button("Unpin from Home", systemImage: "pin.slash") {
                                        app.pins.unpin(card.item)
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func destination(for card: PinnedCard) -> some View {
        switch card.resolved {
        case .album(let album):
            NavigationLink(value: album) { face(card) }
                .buttonStyle(.plain)
        case .artist(let artist):
            NavigationLink(value: artist) { face(card) }
                .buttonStyle(.plain)
        case .playlist(let playlist):
            NavigationLink(value: playlist) { face(card) }
                .buttonStyle(.plain)
                .warmsPlaylist(playlist)
        case .collection(let collection):
            NavigationLink(value: collection) { face(card) }
                .buttonStyle(.plain)
        case .gone:
            // Pinned, then removed from the library — or pinned before this
            // library finished syncing. It keeps its place rather than
            // vanishing without explanation, and says so when tapped.
            Button {
                app.showTransientError("\(card.item.title) isn't in your library any more.")
            } label: {
                face(card)
                    .opacity(0.5)
            }
            .buttonStyle(.plain)
        }
    }

    private func face(_ card: PinnedCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(
                artwork: card.item.artwork,
                size: Self.size,
                cornerRadius: card.item.kind == .artist ? Self.size / 2 : 8,
                placeholder: card.item.kind == .artist ? .artist : .music
            )
            Text(card.item.title)
                .font(.subheadline)
                .lineLimit(1)
            Text(card.item.subtitle ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.size, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.item.subtitle.map { "\(card.item.title), \($0)" } ?? card.item.title)
    }

    private static let size: CGFloat = 128
}

/// A pinned thing, with whatever the library could find to open when it is
/// tapped.
struct PinnedCard: Identifiable {
    enum Resolved {
        case album(Album)
        case artist(Artist)
        case playlist(Playlist)
        case collection(MediaCollection)
        case gone
    }

    let item: PinnedItem
    let resolved: Resolved

    var id: String { item.id }
}
