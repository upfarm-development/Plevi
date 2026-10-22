import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// Keeping what is on screen: as a shelf on Home, or as a playlist.
struct KeepListActions: View {
    let subject: LibraryFilter.Subject
    let filter: LibraryFilter
    /// The order the list is showing, so a playlist is written in the order
    /// on screen rather than in whatever order the database answers in.
    let songOrder: LibraryIndex.SongOrder?
    let albumOrder: AlbumFilter?
    let direction: LibraryIndex.SortDirection

    @Environment(AppModel.self) private var app
    @State private var saving: Target?
    @State private var name = ""
    @State private var problem: String?

    /// What a list can be kept as.
    enum Target: String, Identifiable {
        case shelf
        case playlist
        case smartPlaylist

        var id: String { rawValue }

        var title: String {
            switch self {
            case .shelf: "Save as Home Shelf"
            case .playlist: "Save as Playlist"
            case .smartPlaylist: "Save as Smart Playlist"
            }
        }

        var icon: String {
            switch self {
            case .shelf: "rectangle.grid.1x2"
            case .playlist: "music.note.list"
            case .smartPlaylist: "wand.and.stars"
            }
        }
    }

    var body: some View {
        // Always its own control, never folded into another menu: this is a menu carrying alerts,
        // and one of those inside another menu's content simply does not get built — see
        // `AlbumCollectionView`, where it was, and where nothing was drawn.
        Menu {
            buttons
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .accessibilityLabel("Keep this list")
        .alert(saving?.title ?? "", isPresented: Binding(
            get: { saving != nil },
            set: { if !$0 { saving = nil } }
        )) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { saving = nil }
            Button("Save") {
                if let saving { save(as: saving) }
            }
        } message: {
            Text(explanation)
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(targets) { target in
            Button {
                name = ""
                saving = target
            } label: {
                Label(target.title, systemImage: target.icon)
            }
        }
        if targets.isEmpty {
            // Said rather than left as an empty menu, which reads as a
            // broken button.
            Text("A list of artists is not a shelf or a playlist.")
        }
    }

    private var explanation: String {
        switch saving {
        case .shelf:
            "A shelf on Home, rebuilt from these rules every time you look — in the order shown here."
        case .playlist:
            "A playlist on the server, holding what is listed here now, in this order."
        case .smartPlaylist:
            "A playlist the server keeps up to date, and one Plexamp and the Plex apps can see too."
        case nil:
            ""
        }
    }

    /// What this list can be kept as, given what it is about and what the
    /// server can do.
    private var targets: [Target] {
        guard subject != .artists else { return [] }
        var out: [Target] = [.shelf, .playlist]
        if app.provider?.capabilities.contains(.smartPlaylists) == true,
           case .success = filter.smartQuery() {
            out.append(.smartPlaylist)
        }
        return out
    }

    private func save(as target: Target) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            problem = "Give it a name first."
            return
        }
        switch target {
        case .shelf:
            app.saveCustomSection(CustomHomeSection(
                name: trimmed,
                filter: filter,
                sort: CustomHomeSection.SavedSort(
                    songOrder: songOrder,
                    albumOrder: albumOrder,
                    direction: direction
                )
            ))
            app.showNote("Added “\(trimmed)” to Home")
        case .playlist:
            Task { await savePlaylist(named: trimmed) }
        case .smartPlaylist:
            Task { await saveSmartPlaylist(named: trimmed) }
        }
        saving = nil
    }

    /// The most songs one saved playlist takes: the songs list's own ceiling,
    /// so "Save as Playlist" keeps what the list shows.
    nonisolated private static let songCap = 100_000
    /// Records expanded into songs, taken in the order shown.
    nonisolated private static let albumCap = 5_000

    /// The song ids to save, and whether the list held more than the cap.
    nonisolated private static func songIDs(
        index: LibraryIndex,
        subject: LibraryFilter.Subject,
        filter: LibraryFilter,
        songOrder: LibraryIndex.SongOrder?,
        albumOrder: AlbumFilter?,
        direction: LibraryIndex.SortDirection
    ) -> (ids: [MediaID], cut: Bool) {
        switch subject {
        case .songs:
            // One past the cap, to know whether there was more.
            let rows = (try? index.tracks(
                matching: filter, order: songOrder, direction: direction, limit: songCap + 1
            )) ?? []
            return (rows.prefix(songCap).map(\.id), rows.count > songCap)
        case .albums:
            let albums = (try? index.albums(
                matching: filter, order: albumOrder, direction: direction, limit: albumCap + 1
            )) ?? []
            var ids: [MediaID] = []
            for album in albums.prefix(albumCap) {
                if Task.isCancelled { break }
                ids += ((try? index.tracks(inAlbum: album.id)) ?? []).map(\.id)
            }
            return (ids, albums.count > albumCap)
        case .artists:
            return ([], false)
        }
    }

    private func savePlaylist(named name: String) async {
        guard let provider = app.provider, let index = app.libraryIndex else { return }
        // A playlist is songs.
        let (subject, filter, songOrder, albumOrder, direction) =
            (self.subject, self.filter, self.songOrder, self.albumOrder, self.direction)
        let (ids, cut) = await Task.detached(priority: .userInitiated) {
            Self.songIDs(
                index: index, subject: subject, filter: filter,
                songOrder: songOrder, albumOrder: albumOrder, direction: direction
            )
        }.value
        guard !ids.isEmpty else {
            problem = "This list has no songs in it."
            return
        }
        do {
            // In batches: every song is an id in the request, and eight
            // thousand of them in one is past what a proxy will carry.
            _ = try await provider.createPlaylistInBatches(name: name, trackIDs: ids)
            let made = "Made “\(name)” — \(ids.count.counted("song"))"
            app.showNote(cut ? made + " (the list had more; the first were kept)" : made)
        } catch {
            problem = (error as? ProviderError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func saveSmartPlaylist(named name: String) async {
        guard let provider = app.provider else { return }
        guard case .success(let query) = filter.smartQuery() else {
            problem = "These rules cannot be written as a smart playlist."
            return
        }
        do {
            _ = try await provider.createSmartPlaylist(name: name, query: query)
            app.showNote("Made “\(name)” on the server")
        } catch {
            problem = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
        }
    }
}
