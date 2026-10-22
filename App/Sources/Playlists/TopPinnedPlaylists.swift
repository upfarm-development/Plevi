import Foundation
import PleviDomain

/// Playlists held at the top of the playlists list.
@MainActor
@Observable
final class TopPinnedPlaylists {
    private let defaults: UserDefaults
    private var library: ServerID?

    private(set) var ids: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func use(library: ServerID?) {
        guard library != self.library else { return }
        self.library = library
        ids = library.map { Set(defaults.stringArray(forKey: key(for: $0)) ?? []) } ?? []
    }

    private func key(for library: ServerID) -> String {
        "playlists.pinnedToTop.\(library.rawValue.uuidString)"
    }

    func isPinned(_ playlist: Playlist) -> Bool {
        ids.contains(playlist.id.rawValue)
    }

    func toggle(_ playlist: Playlist) {
        if isPinned(playlist) {
            ids.remove(playlist.id.rawValue)
        } else {
            ids.insert(playlist.id.rawValue)
        }
        write()
    }

    private func write() {
        guard let library else { return }
        defaults.set(Array(ids), forKey: key(for: library))
    }
}
