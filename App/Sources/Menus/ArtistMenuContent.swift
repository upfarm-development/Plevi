import SwiftUI
import PleviDomain

/// Everything you can do to an artist, in one order, in every place.
struct ArtistMenuContent: View {
    let artist: Artist
    let actions: MediaActions

    private var app: AppModel { actions.app }

    private var canAddToPlaylist: Bool {
        app.provider?.capabilities.contains(.playlists) == true
    }

    private var canAddToCollection: Bool {
        app.provider?.capabilities.contains(.collectionEditing) == true
    }

    var body: some View {
        // Glyphs on one row rather than words on four — see the note in `AlbumMenuContent`.
        ControlGroup {
            Button("Play", systemImage: "play.fill") {
                actions.playArtist(artist)
            }
            Button("Shuffle", systemImage: "shuffle") {
                actions.playArtist(artist, shuffled: true)
            }
            // Third glyph on the first row, where a song's and an album's
            // menus both keep theirs — a long press should reach for the
            // same place whatever it landed on.
            if app.provider?.capabilities.contains(.similarItems) == true {
                Button("Artist Radio", systemImage: "dot.radiowaves.left.and.right") {
                    actions.startRadio(fromArtist: artist)
                }
            }
        }
        .controlGroupStyle(.compactMenu)

        if actions.canAddToQueue {
            ControlGroup {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    actions.playNext(artist: artist)
                }
                Button("Add to Queue", systemImage: "text.append") {
                    actions.addToQueue(artist: artist)
                }
            }
            .controlGroupStyle(.compactMenu)
        }

        // Its own row rather than a fourth glyph on the first one: the three up there are what you
        // press to hear this artist, and this is a way of working through them.
        if app.provider?.capabilities.contains(.ratings) == true {
            Button("Play Unrated", systemImage: "star") {
                actions.playUnrated(artist: artist)
            }
        }

        if app.downloads != nil {
            Divider()
            DownloadMenuItems(kind: .artist(artist), actions: actions)
        }

        // The two ways of filing this somewhere, together.
        if canAddToPlaylist || canAddToCollection {
            Divider()
            if canAddToPlaylist {
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    Task { app.requestAddToPlaylist(await actions.tracks(byArtist: artist.id)) }
                }
            }
            if canAddToCollection {
                Button("Add to Collection…", systemImage: "rectangle.stack.badge.plus") {
                    app.requestAddToCollection(CollectionAddition(
                        kind: .artists,
                        itemIDs: [artist.id],
                        what: artist.name
                    ))
                }
            }
        }

        Divider()
        PinMenuItem(item: PinnedItem(artist: artist), pins: app.pins)

        if app.provider?.capabilities.contains(.favorites) == true {
            Divider()
            Button(
                artist.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: artist.isFavorite ? "heart.slash" : "heart"
            ) {
                actions.setFavorite(!artist.isFavorite, id: artist.id, kind: .artist)
            }
        }
    }
}
