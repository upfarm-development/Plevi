import Foundation
import PleviDomain
import PleviLibraryIndex

/// The copy of the library that lives on the watch.
@MainActor
@Observable
final class WatchLibrary {
    let index: LibraryIndex
    let storage: ServerID
    private let downloadStore: DownloadStore

    init(index: LibraryIndex, storage: ServerID) {
        self.index = index
        self.storage = storage
        self.downloadStore = DownloadStore(serverID: storage)
    }

    /// The file for a song kept on this watch, read from the table and the disk and needing no
    /// server.
    func downloadedFile(for id: MediaID) -> URL? {
        guard let row = try? index.download(forTrack: id), row.state == .done else { return nil }
        return downloadStore.existingFile(named: row.fileName)
    }

    /// Opens the snapshot for a library, or nil when none has arrived.
    static func opened(storage: ServerID) -> WatchLibrary? {
        let url = LibraryStorage.indexURL(for: storage)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let index = try? LibraryIndex(databaseURL: url, serverID: storage) else { return nil }
        return WatchLibrary(index: index, storage: storage)
    }

    var isEmpty: Bool {
        ((try? index.stats().trackCount) ?? 0) == 0
    }

    var trackCount: Int {
        (try? index.stats().trackCount) ?? 0
    }

    // MARK: Lists

    /// A ceiling on every list.
    static let ceiling = 400

    func artists(downloadedOnly: Bool) -> [Artist] {
        ((try? index.artists(downloadedOnly: downloadedOnly)) ?? [])
            .prefix(Self.ceiling)
            .map { $0 }
    }

    func albums(downloadedOnly: Bool) -> [Album] {
        (try? index.albums(
            filter: .alphabeticalByName, offset: 0, limit: Self.ceiling,
            downloadedOnly: downloadedOnly
        )) ?? []
    }

    // MARK: Browsing by letter

    /// Which letters have anything under them, and how much.
    func albumInitials(downloadedOnly: Bool) -> [String: Int] {
        (try? index.albumInitialCounts(downloadedOnly: downloadedOnly)) ?? [:]
    }

    func artistInitials(downloadedOnly: Bool) -> [String: Int] {
        (try? index.artistInitialCounts(downloadedOnly: downloadedOnly)) ?? [:]
    }

    func albums(initials: Set<String>, downloadedOnly: Bool) -> [Album] {
        (try? index.albums(initials: initials, downloadedOnly: downloadedOnly)) ?? []
    }

    func artists(initials: Set<String>, downloadedOnly: Bool) -> [Artist] {
        (try? index.artists(initials: initials, downloadedOnly: downloadedOnly)) ?? []
    }

    func justAdded(downloadedOnly: Bool) -> [Album] {
        (try? index.albums(
            filter: .recentlyAdded, offset: 0, limit: 50,
            downloadedOnly: downloadedOnly
        )) ?? []
    }

    func albums(forArtist id: MediaID, downloadedOnly: Bool) -> [Album] {
        (try? index.albums(forArtist: id, downloadedOnly: downloadedOnly)) ?? []
    }

    func tracks(inAlbum id: MediaID) -> [Track] {
        (try? index.tracks(inAlbum: id)) ?? []
    }

    func album(id: MediaID) -> Album? {
        try? index.album(id: id)
    }

    /// The playlists kept whole on this watch.
    func downloadedPlaylists() -> [Playlist] {
        ((try? index.downloadedPlaylists()) ?? []).map { record in
            Playlist(
                id: MediaID(server: storage, rawValue: record.id),
                name: record.name,
                trackCount: record.tracks.count,
                artwork: record.artworkId.map { ArtworkID(server: storage, rawValue: $0) }
            )
        }
    }

    /// Its songs, in the order the playlist had them, and only the ones that really have a file
    /// behind them.
    func memberIDs(inDownloadedPlaylist id: MediaID) -> [MediaID] {
        guard let record = try? index.downloadedPlaylist(id: id) else { return [] }
        return record.tracks.map { MediaID(server: storage, rawValue: $0) }
    }

    func tracks(inDownloadedPlaylist id: MediaID) -> [Track] {
        guard let record = try? index.downloadedPlaylist(id: id) else { return [] }
        let present = downloadedTrackIDs()
        return record.tracks.compactMap { raw in
            guard present.contains(raw) else { return nil }
            return try? index.track(id: MediaID(server: storage, rawValue: raw))
        }
    }

    /// Which songs on this screen would actually play with the server gone.
    func downloadedTrackIDs() -> Set<String> {
        (try? index.downloadedTrackIDs()) ?? []
    }
}
