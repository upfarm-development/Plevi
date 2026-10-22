import Foundation
import PleviDomain

/// Where the picker's recent playlists are kept between launches.
enum RecentPlaylistsStore {
    static func record(_ playlist: Playlist, defaults: UserDefaults = .standard) {
        let key = key(for: playlist.id.server)
        let remembered = defaults.array(forKey: key) as? [String] ?? []
        defaults.set(RecentPlaylists.recording(playlist.id.rawValue, in: remembered), forKey: key)
    }

    /// The few for the head of the picker, resolved against the playlists the
    /// server has just given us.
    static func recent(among playlists: [Playlist], defaults: UserDefaults = .standard) -> [Playlist] {
        guard let server = playlists.first?.id.server else { return [] }
        let remembered = defaults.array(forKey: key(for: server)) as? [String] ?? []
        return RecentPlaylists.resolve(remembered, among: playlists)
    }

    private static func key(for server: ServerID) -> String {
        "playlists.recentlyAddedTo.\(server.rawValue.uuidString)"
    }
}
