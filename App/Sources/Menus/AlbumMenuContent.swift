import SwiftUI
import PleviDomain

/// Everything you can do to an album, in one order, in every place.
struct AlbumMenuContent: View {
    let album: Album
    let actions: MediaActions

    private var app: AppModel { actions.app }

    private var canAddToPlaylist: Bool {
        app.provider?.capabilities.contains(.playlists) == true
    }

    private var canAddToCollection: Bool {
        app.provider?.capabilities.contains(.collectionEditing) == true
    }

    var body: some View {
        // The ways of starting it, on one row of glyphs rather than three rows of words.
        ControlGroup {
            Button("Play", systemImage: "play.fill") {
                actions.playAlbum(album)
            }
            Button("Shuffle", systemImage: "shuffle") {
                actions.playAlbum(album, shuffled: true)
            }
            if app.provider?.capabilities.contains(.similarItems) == true {
                Button("Album Radio", systemImage: "dot.radiowaves.left.and.right") {
                    Task {
                        guard let seed = await actions.tracks(inAlbum: album.id).first else { return }
                        actions.startRadio(from: seed)
                    }
                }
            }
        }
        .controlGroupStyle(.compactMenu)

        // And the two ways of putting it after what is playing.
        if actions.canAddToQueue {
            ControlGroup {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    actions.playNext(album: album)
                }
                Button("Add to Queue", systemImage: "text.append") {
                    actions.addToQueue(album: album)
                }
            }
            .controlGroupStyle(.compactMenu)
        }

        if app.downloads != nil {
            Divider()
            DownloadMenuItems(kind: .album(album), actions: actions)
        }

        // The two ways of filing this somewhere, together and on their own.
        // Pinning shared their group before, which read as three things of
        // a kind when it is two and one.
        if canAddToPlaylist || canAddToCollection {
            Divider()
            if canAddToPlaylist {
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    Task { app.requestAddToPlaylist(await actions.tracks(inAlbum: album.id)) }
                }
            }
            if canAddToCollection {
                Button("Add to Collection…", systemImage: "rectangle.stack.badge.plus") {
                    app.requestAddToCollection(CollectionAddition(
                        kind: .albums,
                        itemIDs: [album.id],
                        what: "“\(album.name)”"
                    ))
                }
            }
        }

        Divider()
        PinMenuItem(item: PinnedItem(album: album), pins: app.pins)

        Divider()
        if app.provider?.capabilities.contains(.favorites) == true {
            Button(
                album.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: album.isFavorite ? "heart.slash" : "heart"
            ) {
                actions.setFavorite(!album.isFavorite, id: album.id, kind: .album)
            }
        }
        if app.provider?.capabilities.contains(.ratings) == true {
            RatingMenu(
                title: "Rate Album",
                current: album.rating,
                allowsHalfStars: actions.allowsHalfStars
            ) { newRating in
                actions.setRating(newRating, id: album.id)
            }
        }
    }
}
