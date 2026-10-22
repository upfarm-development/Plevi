import SwiftUI
import PleviDomain

/// "Download" or "Remove Download", for a whole album, artist or playlist.
struct DownloadMenuItems: View {
    enum Kind {
        case album(Album)
        case artist(Artist)
        case playlist(Playlist, tracks: [Track])
    }

    let kind: Kind
    let actions: MediaActions

    private var reason: DownloadReason {
        switch kind {
        case .album(let album): .album(album.id)
        case .artist(let artist): .artist(artist.id)
        case .playlist(let playlist, _): .playlist(playlist.id)
        }
    }

    /// Whether there is anything here to let go of.
    private var isRequested: Bool {
        guard let downloads = actions.app.downloads else { return false }
        switch kind {
        case .album(let album):
            if let held = foreignSongs(), held.contains(where: downloads.isDownloaded) { return true }
            return downloads.hasDownloads(album: album.id)
        case .artist(let artist):
            if let held = foreignSongs(), held.contains(where: downloads.isDownloaded) { return true }
            return downloads.hasDownloads(artist: artist.id)
        case .playlist(let playlist, _): return downloads.isRequested(.playlist(playlist.id))
        }
    }

    /// The songs of an album or an artist that belongs to another of this server's libraries — a
    /// result of a search across them — read from that library's index.
    private func foreignSongs() -> [MediaID]? {
        switch kind {
        case .album(let album):
            guard album.id.server != actions.app.libraryIndex?.server else { return nil }
            return actions.foreignTrackIDs(inAlbum: album.id)
        case .artist(let artist):
            guard artist.id.server != actions.app.libraryIndex?.server else { return nil }
            return actions.foreignTrackIDs(byArtist: artist.id)
        case .playlist: return nil
        }
    }

    /// Whether there is anything still to fetch.
    private var isMissing: Bool {
        guard let downloads = actions.app.downloads else { return true }
        if let foreign = foreignSongs() {
            // Not known to the index it came from either: say there is
            // something to fetch, which asking the server will settle.
            return foreign.isEmpty || foreign.contains { !downloads.isDownloaded($0) }
        }
        switch kind {
        case .album(let album): return downloads.isMissingDownloads(album: album.id)
        case .artist(let artist): return downloads.isMissingDownloads(artist: artist.id)
        case .playlist(_, let tracks):
            return tracks.contains { !downloads.isDownloaded($0.id) }
        }
    }

    var body: some View {
        // Two independent questions, and the menu asks both: is there anything left to fetch, and
        // is there anything here to let go of.
        if isMissing {
            Button(isRequested ? "Download Missing" : "Download", systemImage: "arrow.down.circle") {
                switch kind {
                case .album(let album): actions.download(album: album)
                case .artist(let artist): actions.download(artist: artist)
                case .playlist(let playlist, let tracks): actions.download(playlist: playlist, tracks: tracks)
                }
            }
        }

        if isRequested {
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                switch kind {
                case .album(let album): actions.removeDownload(album: album)
                case .artist(let artist): actions.removeDownload(artist: artist)
                case .playlist(let playlist, _): actions.removeDownload(playlist: playlist)
                }
            }
        }
    }
}
