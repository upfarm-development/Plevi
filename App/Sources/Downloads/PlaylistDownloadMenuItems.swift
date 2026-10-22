import SwiftUI
import PleviDomain

/// Keeping a playlist on the phone, from a list that does not hold its songs.
struct PlaylistDownloadMenuItems: View {
    let playlist: Playlist
    let actions: MediaActions

    private var downloads: DownloadManager? { actions.app.downloads }

    var body: some View {
        if let downloads {
            let isHeld = downloads.isRequested(.playlist(playlist.id))
            // A playlist that is wholly here has nothing to fetch, which the
            // record it was kept with can say; the playlist's own page asks
            // the same question of the whole list.
            if !isHeld || downloads.isMissingDownloads(playlist: playlist.id) {
                Button(
                    isHeld ? "Download Missing" : "Download",
                    systemImage: "arrow.down.circle"
                ) {
                    Task { await download() }
                }
            }
            if isHeld {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    actions.removeDownload(playlist: playlist)
                }
            }
        }
    }

    private func download() async {
        guard let provider = actions.app.provider else { return }
        guard let detail = try? await provider.playlist(id: playlist.id) else {
            actions.app.showTransientError("Couldn't read “\(playlist.name)” to download it.")
            return
        }
        let tracks = detail.entries.map(\.track)
        guard !tracks.isEmpty else {
            actions.app.showTransientError("“\(playlist.name)” has no songs to download.")
            return
        }
        actions.download(playlist: playlist, tracks: tracks)
    }
}
