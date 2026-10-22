import Foundation
import PleviDomain

/// A playlist's songs as they are kept on the phone.
struct DownloadedPlaylistSource: PlaylistPageSource {
    let playlist: Playlist
    let tracks: [Track]

    func playlistPage(id: MediaID, offset: Int, limit: Int) async throws -> PlaylistPage {
        let slice = tracks.dropFirst(offset).prefix(limit)
        return PlaylistPage(
            playlist: playlist,
            entries: slice.map { track in
                PlaylistEntry(
                    // A downloaded playlist keeps songs, not the server's row ids for them.
                    entryID: PlaylistEntryID(server: track.id.server, rawValue: track.id.rawValue),
                    track: track
                )
            },
            total: tracks.count,
            returnedRows: slice.count
        )
    }
}
