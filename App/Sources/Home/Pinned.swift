import Foundation
import PleviDomain

/// Something kept on the Home screen on purpose.
struct PinnedItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case album
        case artist
        case playlist
        case collection
    }

    var kind: Kind
    var mediaID: MediaID
    var title: String
    var subtitle: String?
    var artwork: ArtworkID?
    /// Records or artists, for a pinned collection. Nil for everything else,
    /// and absent from anything pinned before collections could be — which
    /// is why it is optional rather than defaulted.
    var collectionKind: MediaCollection.Kind?

    var id: String { "\(kind.rawValue):\(mediaID.rawValue)" }

    init(album: Album) {
        kind = .album
        mediaID = album.id
        title = album.name
        subtitle = album.artistName
        artwork = album.artwork
    }

    init(artist: Artist) {
        kind = .artist
        mediaID = artist.id
        title = artist.name
        subtitle = nil
        artwork = artist.artwork
    }

    /// A set gathered on the server.
    init(collection: MediaCollection) {
        kind = .collection
        mediaID = collection.id
        title = collection.name
        subtitle = collection.itemCount.map {
            $0.counted(collection.kind == .albums ? "album" : "artist")
        }
        artwork = collection.artwork
        collectionKind = collection.kind
    }

    init(playlist: Playlist) {
        kind = .playlist
        mediaID = playlist.id
        title = playlist.name
        subtitle = playlist.trackCount.map { $0.counted("song") }
        artwork = playlist.artwork
    }

    /// A playlist to open, rebuilt from what was pinned. The detail screen
    /// fetches the songs itself, so a name and an id are enough to get there.
    /// The collection to open, rebuilt from what was pinned.
    var asCollection: MediaCollection? {
        guard kind == .collection, let collectionKind else { return nil }
        return MediaCollection(
            id: mediaID, name: title, kind: collectionKind,
            itemCount: nil, artwork: artwork
        )
    }

    var asPlaylist: Playlist {
        Playlist(id: mediaID, name: title, artwork: artwork)
    }
}

/// What is pinned to Home, in the order it should appear.
@MainActor
@Observable
final class PinBoard {
    /// Where pins lived before they were kept per library.
    private static let legacyKey = "home.pinned"

    private let defaults: UserDefaults
    private var library: ServerID?

    private(set) var items: [PinnedItem] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Points the board at a library. Called whenever one is connected.
    func use(library: ServerID?) {
        guard library != self.library else { return }
        self.library = library
        items = library.flatMap(load) ?? []
    }

    private func key(for library: ServerID) -> String {
        "home.pinned.\(library.rawValue.uuidString)"
    }

    private func load(_ library: ServerID) -> [PinnedItem] {
        if let data = defaults.data(forKey: key(for: library)),
           let saved = try? JSONDecoder().decode([PinnedItem].self, from: data) {
            return saved
        }
        // Nothing stored for this library yet. If pins were kept before they
        // were per-library, they are this library's — whichever connects
        // first is the one they were made in.
        if let data = defaults.data(forKey: Self.legacyKey),
           let inherited = try? JSONDecoder().decode([PinnedItem].self, from: data) {
            defaults.removeObject(forKey: Self.legacyKey)
            defaults.set(data, forKey: key(for: library))
            return inherited
        }
        return []
    }

    func isPinned(_ item: PinnedItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    /// Newest first: the thing just pinned is the thing being listened to.
    func pin(_ item: PinnedItem) {
        guard !isPinned(item) else { return }
        items.insert(item, at: 0)
        write()
    }

    func unpin(_ item: PinnedItem) {
        items.removeAll { $0.id == item.id }
        write()
    }

    /// Brings pinned playlists up to date with the playlists as the server has them now.
    func refresh(playlists: [Playlist]) {
        guard items.contains(where: { $0.kind == .playlist }) else { return }
        let fresh = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for index in items.indices where items[index].kind == .playlist {
            guard let playlist = fresh[items[index].mediaID] else { continue }
            let updated = PinnedItem(playlist: playlist)
            var item = items[index]
            item.title = updated.title
            if updated.subtitle != nil { item.subtitle = updated.subtitle }
            if updated.artwork != nil { item.artwork = updated.artwork }
            if item != items[index] {
                items[index] = item
                changed = true
            }
        }
        if changed { write() }
    }

    func toggle(_ item: PinnedItem) {
        isPinned(item) ? unpin(item) : pin(item)
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: offsets, toOffset: destination)
        write()
    }

    private func write() {
        guard let library, let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key(for: library))
    }
}
