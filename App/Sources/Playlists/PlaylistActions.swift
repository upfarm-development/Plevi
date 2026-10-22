import SwiftUI
import Observation
import PleviDomain
import PleviLibraryIndex

/// Playlist mutations, shared by every screen that can change one.
@MainActor
@Observable
final class PlaylistStore {
    private(set) var playlists: [Playlist] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    /// Bumped by every refresh, so counts still arriving for the list that
    /// was replaced do not write themselves into the new one.
    private var countGeneration = 0

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var isSupported: Bool {
        app.provider?.capabilities.contains(.playlists) ?? false
    }

    func refresh() async {
        // Offline the list is whatever it was; asking the server would only
        // replace it with an error.
        guard !app.isOffline else { return }
        guard let provider = app.provider, isSupported else { return }
        isLoading = true
        countGeneration += 1
        let generation = countGeneration
        do {
            let fetched = try await provider.playlists()
            // A newer refresh started while this one was in the air, and the
            // answers can arrive in either order: the older one must not
            // write over the newer, nor clear the flag it is still using.
            guard generation == countGeneration else { return }
            playlists = fetched.map(withKnownCount)
            lastError = nil
            // The names go to the index too, so a song filter can ask which
            // playlists a song is in — see `FilterField.playlistName`. Names
            // only: what is in them is fetched when something asks.
            rememberForFiltering(playlists)
            app.pins.refresh(playlists: playlists)
        } catch {
            guard generation == countGeneration else { return }
            // A call that was called off says nothing about the server, and
            // must not read as "could not load".
            if !error.isCancelledFetch { lastError = message(for: error) }
        }
        isLoading = false
        // The list is on screen by now; the corrected counts arrive after it.
        await correctSmartCounts(generation: generation)
    }

    /// Hands the playlist names to the index.
    private func rememberForFiltering(_ playlists: [Playlist]) {
        guard let index = app.libraryIndex else { return }
        try? index.saveIndexedPlaylists(
            playlists.map { IndexedPlaylistRecord(id: $0.id.rawValue, name: $0.name) }
        )
    }

    /// Replaces the song count Plex gives for a smart playlist with the real one.
    private func correctSmartCounts(generation: Int) async {
        guard let provider = app.provider else { return }
        let smart = playlists.filter(\.isSmart).map(\.id)
        guard !smart.isEmpty else { return }

        await withTaskGroup(of: (MediaID, Int?).self) { group in
            var next = 0
            func ask(_ id: MediaID) {
                group.addTask {
                    let total = try? await provider.playlistPage(id: id, offset: 0, limit: 1).total
                    return (id, total)
                }
                next += 1
            }
            while next < min(Self.countsAtOnce, smart.count) { ask(smart[next]) }
            for await (id, total) in group {
                guard generation == countGeneration else { return }
                if let total { apply(count: total, to: id) }
                if next < smart.count { ask(smart[next]) }
            }
        }
    }

    /// How many count requests are in the air at once. Enough to finish a
    /// long list of playlists quickly, few enough not to fall on a home
    /// server all at once over a slow link.
    private static let countsAtOnce = 4

    /// Counts already worked out for smart playlists this session.
    private var corrected: [MediaID: Int] = [:]

    /// A playlist as it arrived, with the count corrected if that has already been worked out — and
    /// with the stale one taken off if it has not.
    private func withKnownCount(_ playlist: Playlist) -> Playlist {
        guard playlist.isSmart else { return playlist }
        var known = playlist
        known.trackCount = corrected[playlist.id]
        // Its length is stale for the same reason and cannot be corrected
        // this cheaply, so it is dropped rather than shown wrong.
        known.duration = nil
        return known
    }

    private func apply(count: Int, to id: MediaID) {
        corrected[id] = count
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].trackCount != count else { return }
        playlists[index].trackCount = count
        playlists[index].duration = nil
    }

    @discardableResult
    /// - Parameter refreshing: whether to fetch the playlists again afterwards.
    func create(named name: String, tracks: [Track] = [], refreshing: Bool = true) async -> Playlist? {
        guard let provider = app.provider else { return nil }
        do {
            let created = try await provider.createPlaylist(
                name: name,
                trackIDs: tracks.map(\.id)
            )
            // Made from the picker with songs in it, which is the same act as
            // adding to one — and it is very likely the next one you reach
            // for, so it belongs at the head of the list.
            if !tracks.isEmpty { RecentPlaylistsStore.record(created) }
            if refreshing { await refresh() }
            return created
        } catch {
            app.showTransientError(message(for: error))
            return nil
        }
    }

    func rename(_ playlist: Playlist, to name: String) async {
        guard let provider = app.provider else { return }
        do {
            try await provider.renamePlaylist(id: playlist.id, name: name)
            await refresh()
        } catch {
            app.showTransientError(message(for: error))
        }
    }

    func add(_ tracks: [Track], to playlist: Playlist) async {
        guard let provider = app.provider, !tracks.isEmpty else { return }
        do {
            try await provider.addToPlaylist(id: playlist.id, trackIDs: tracks.map(\.id))
            // Only once the server has taken it. A playlist the add failed
            // against is not one you last added to, and putting it at the
            // head of the picker would offer the failure again first.
            RecentPlaylistsStore.record(playlist)
            membersChanged(playlist)
            app.showTransientError(
                tracks.count == 1
                    ? "Added to \(playlist.name)"
                    : "\(tracks.count.counted("song")) added to \(playlist.name)"
            )
            // And that is the whole of it.
        } catch {
            app.showTransientError(message(for: error))
        }
    }

    /// Removes rows by their entry IDs. A `conflict` means the playlist
    /// changed elsewhere; the caller should refetch and try again.
    func remove(entries: [PlaylistEntryID], from playlist: Playlist) async -> Bool {
        guard let provider = app.provider, !entries.isEmpty else { return false }
        do {
            try await provider.removeFromPlaylist(id: playlist.id, entries: entries)
            membersChanged(playlist)
            return true
        } catch {
            app.showTransientError(message(for: error))
            return false
        }
    }

    /// The index keeps a copy of what is in a playlist for filters and
    /// shelves that ask about it by name. A change made here leaves that copy
    /// wrong, so it is marked for fetching again and the shelves read anew.
    private func membersChanged(_ playlist: Playlist) {
        try? app.libraryIndex?.invalidateMembers(ofPlaylist: playlist.id.rawValue)
        app.bumpLibraryVersion()
    }

    func reorder(_ playlist: Playlist, orderedEntries: [PlaylistEntryID]) async -> Bool {
        guard let provider = app.provider,
              provider.capabilities.contains(.playlistReorder)
        else { return false }
        do {
            try await provider.reorderPlaylist(id: playlist.id, orderedEntries: orderedEntries)
            return true
        } catch {
            app.showTransientError(message(for: error))
            return false
        }
    }

    private func message(for error: any Error) -> String {
        (error as? ProviderError)?.errorDescription ?? error.localizedDescription
    }
}

/// Picks a playlist to add songs to, with the option to make a new one.
struct AddToPlaylistView: View {
    let tracks: [Track]
    /// What a new playlist made for these songs should be called, where the
    /// caller has an opinion — saving a mix does. Only ever fills the field
    /// in; the name typed is the name used.
    var suggestedName: String?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var store: PlaylistStore?
    @State private var creatingPlaylist = false
    @State private var newName = ""
    @State private var query = ""
    /// Set the moment a row or Create is tapped and never cleared before the
    /// sheet goes: a second tap while the first is still on the wire sent a
    /// second write, and put the song in twice or made two playlists.
    @State private var isWorking = false

    /// In the order the Playlists tab is showing them — the same setting — since looking for a
    /// playlist in a different order than the one you know is its own small tax.
    private var all: [Playlist] {
        // Held at the top here too.
        app.settings.playlistSorting.sorted(
            (store?.playlists ?? []).filter { !$0.isSmart },
            pinnedToTop: app.playlistTopPins.ids
        )
    }

    private var term: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Matched the way the Finder does it: case and diacritics ignored, and anywhere in the name
    /// rather than only at its start, because playlists are named for what is in them and the word
    /// you remember is rarely the first one.
    private var matches: [Playlist] {
        guard !term.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(term) }
    }

    /// Only while the whole list is showing.
    private var recent: [Playlist] {
        guard term.isEmpty else { return [] }
        return RecentPlaylistsStore.recent(among: all)
    }

    /// Why the list could not be read, when that is why it is empty: offline, or the request
    /// failed, with nothing good from before to show.
    private var cannotList: String? {
        guard let store, store.playlists.isEmpty, !store.isLoading else { return nil }
        if app.isOffline { return "Playlists live on the server, so they need a connection." }
        return store.lastError
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = suggestedName ?? ""
                        creatingPlaylist = true
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                            .frame(
                                maxWidth: .infinity,
                                minHeight: CompactList.rowHeight,
                                alignment: .leading
                            )
                            .contentShape(.rect)
                    }
                    .listRowInsets(CompactList.rowInsets)
                    .disabled(isWorking || cannotList != nil)
                }

                if !recent.isEmpty {
                    Section("Recently Added To") {
                        ForEach(recent) { row(for: $0) }
                    }
                }

                // Headed only when there is a list above it to tell it apart
                // from. On its own it is the whole screen, and a heading over
                // the whole screen says nothing the title has not.
                if recent.isEmpty {
                    Section { ForEach(matches) { row(for: $0) } }
                } else {
                    Section("All Playlists") { ForEach(matches) { row(for: $0) } }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Find a playlist"
            )
            // A playlist is as likely to be named "80s hits" as "80s Hits",
            // and a field that quietly puts a capital on the first letter of
            // a search looks like it has corrected you.
            .textInputAutocapitalization(.never)
            .navigationTitle(tracks.count == 1 ? "Add to Playlist" : "Add \(tracks.count.counted("song"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if let store, all.isEmpty, !store.isLoading, let reason = cannotList {
                    if app.isOffline {
                        ContentUnavailableView(
                            "Can't load playlists",
                            systemImage: "wifi.slash",
                            description: Text(reason)
                        )
                    } else {
                        FetchFailureView(message: reason) { Task { await store.refresh() } }
                    }
                } else if let store, all.isEmpty, !store.isLoading {
                    ContentUnavailableView(
                        "No playlists to add to",
                        systemImage: "music.note.list",
                        description: Text(
                            store.playlists.isEmpty
                                ? "Create one to start collecting songs."
                                : "Every playlist here is a smart one, which follows a rule rather than holding songs."
                        )
                    )
                } else if !term.isEmpty, matches.isEmpty {
                    ContentUnavailableView.search(text: term)
                }
            }
            .alert("New Playlist", isPresented: $creatingPlaylist) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    newName = ""
                    guard !name.isEmpty, let store, !isWorking else { return }
                    isWorking = true
                    Task {
                        _ = await store.create(named: name, tracks: tracks, refreshing: false)
                        dismiss()
                    }
                }
            } message: {
                Text(
                    tracks.count == 1
                        ? "The song will be added to it."
                        : "\(tracks.count.counted("song")) will be added to it."
                )
            }
            .task {
                let store = store ?? PlaylistStore(app: app)
                self.store = store
                await store.refresh()
            }
        }
        .withoutBottomScrollEdgeBlur()
    }

    private func row(for playlist: Playlist) -> some View {
        Button {
            guard !isWorking else { return }
            isWorking = true
            Task {
                await store?.add(tracks, to: playlist)
                dismiss()
            }
        } label: {
            // Marked here as well, so the reason one is at the top is
            // visible rather than left to be guessed at.
            PlaylistRow(
                playlist: playlist,
                isPinnedToTop: app.playlistTopPins.isPinned(playlist)
            )
                .contentShape(.rect)
        }
        .listRowInsets(CompactList.rowInsets)
        .disabled(isWorking)
    }
}
