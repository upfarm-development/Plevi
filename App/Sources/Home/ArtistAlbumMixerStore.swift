import Foundation
import Observation
import PleviDomain
import PleviLibraryIndex

/// What the Artist & Album Mixer has been asked to draw from.
@MainActor
@Observable
final class ArtistAlbumMixerStore {
    /// One thing the listener picked, in the order they picked it.
    enum Item: Identifiable, Hashable {
        case artist(Artist)
        case album(Album)

        var id: String {
            switch self {
            case .artist(let artist): "artist:\(artist.id.rawValue)"
            case .album(let album): "album:\(album.id.rawValue)"
            }
        }

        var name: String {
            switch self {
            case .artist(let artist): artist.name
            case .album(let album): album.displayName
            }
        }

        /// The second line on a chip, where there is one worth showing.
        var detail: String? {
            switch self {
            case .artist: nil
            case .album(let album): album.artistName
            }
        }

        var artwork: ArtworkID? {
            switch self {
            case .artist(let artist): artist.artwork
            case .album(let album): album.artwork
            }
        }

        var mediaID: MediaID {
            switch self {
            case .artist(let artist): artist.id
            case .album(let album): album.id
            }
        }

        /// Which of the two this is — a round portrait and a square sleeve
        /// are drawn differently everywhere they appear together.
        var isArtist: Bool {
            if case .artist = self { return true }
            return false
        }
    }

    private(set) var selection: [Item] = []
    var emphasis: ArtistAlbumMix.Emphasis = .shuffle {
        didSet { persist() }
    }

    /// The library the selection belongs to, so a switch can be noticed.
    private var library: String?
    /// True only while `refresh` is putting a kept selection back.
    private var isRestoring = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEmpty: Bool { selection.isEmpty }

    /// How many distinct artists the selection reaches, which is what decides whether the mix is
    /// spread by artist or by album.
    var artistCount: Int {
        var names: Set<String> = []
        for item in selection {
            switch item {
            case .artist(let artist):
                names.insert(artist.name.lowercased())
            case .album(let album):
                if let artist = album.artistName, !artist.isEmpty {
                    names.insert(artist.lowercased())
                }
            }
        }
        return names.count
    }

    /// Albums the server called alike, per seed, kept for as long as the app is running.
    private var sonicCache: [MediaID: [Album]] = [:]

    func sonicNeighbours(of seed: MediaID) -> [Album]? { sonicCache[seed] }

    func rememberSonicNeighbours(_ albums: [Album], of seed: MediaID) {
        sonicCache[seed] = albums
    }

    /// What the selection comes to as plain ids, so the fetch behind it can
    /// happen off the main actor.
    func selectionIDs() -> (artists: [MediaID], albums: [MediaID]) {
        var artistIDs: [MediaID] = []
        var albumIDs: [MediaID] = []
        for item in selection {
            switch item {
            case .artist(let artist): artistIDs.append(artist.id)
            case .album(let album): albumIDs.append(album.id)
            }
        }
        return (artistIDs, albumIDs)
    }

    func contains(_ item: Item) -> Bool {
        selection.contains { $0.id == item.id }
    }

    /// Adds, or takes back out if it is already in — the same tap either way,
    /// so a row that shows a tick can be untapped without hunting for its
    /// chip.
    func toggle(_ item: Item) {
        if let index = selection.firstIndex(where: { $0.id == item.id }) {
            selection.remove(at: index)
        } else {
            selection.append(item)
        }
        persist()
    }

    func remove(_ item: Item) {
        selection.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        selection.removeAll()
        persist()
    }

    /// Reads the kept selection back, resolving each id against the library as it stands now.
    func refresh(index: LibraryIndex?) {
        guard let index else {
            selection = []
            library = nil
            return
        }
        let key = index.server.rawValue.uuidString
        guard key != library else { return }
        library = key
        isRestoring = true
        defer { isRestoring = false }
        emphasis = storedEmphasis(for: key)

        selection = storedSelection(for: key).compactMap { stored in
            switch stored.kind {
            case .artist:
                (try? index.artist(id: MediaID(server: index.server, rawValue: stored.id)))
                    .map(Item.artist)
            case .album:
                (try? index.album(id: MediaID(server: index.server, rawValue: stored.id)))
                    .map(Item.album)
            }
        }
    }

    /// Every song a selection reaches, floor already applied — see `LibraryIndex.mixerTracks`.
    nonisolated static func pool(
        index: LibraryIndex,
        artistIDs: [MediaID],
        albumIDs: [MediaID],
        downloadedOnly: Bool
    ) -> [Track] {
        let tracks = (try? index.mixerTracks(
            artistIDs: artistIDs, albumIDs: albumIDs, downloadedOnly: downloadedOnly
        )) ?? []
        return ArtistAlbumMix.pool(
            from: tracks, ratingFloor: LibraryIndex.favoriteRatingThreshold
        )
    }

    // MARK: Persistence

    private struct StoredItem: Codable {
        enum Kind: String, Codable { case artist, album }
        let kind: Kind
        let id: String
    }

    private static let selectionPrefix = "radio.mixer.selection.v1."
    private static let emphasisPrefix = "radio.mixer.emphasis.v1."

    private func storedSelection(for key: String) -> [StoredItem] {
        guard let data = defaults.data(forKey: Self.selectionPrefix + key),
              let saved = try? JSONDecoder().decode([StoredItem].self, from: data)
        else { return [] }
        return saved
    }

    private func storedEmphasis(for key: String) -> ArtistAlbumMix.Emphasis {
        guard let raw = defaults.string(forKey: Self.emphasisPrefix + key),
              let found = ArtistAlbumMix.Emphasis(rawValue: raw)
        else { return .shuffle }
        return found
    }

    private func persist() {
        guard !isRestoring, let library else { return }
        let stored = selection.map { item -> StoredItem in
            switch item {
            case .artist(let artist): StoredItem(kind: .artist, id: artist.id.rawValue)
            case .album(let album): StoredItem(kind: .album, id: album.id.rawValue)
            }
        }
        if let encoded = try? JSONEncoder().encode(stored) {
            defaults.set(encoded, forKey: Self.selectionPrefix + library)
        }
        defaults.set(emphasis.rawValue, forKey: Self.emphasisPrefix + library)
    }
}
