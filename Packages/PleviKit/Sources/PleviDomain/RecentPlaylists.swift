import Foundation

/// The playlists songs were most recently added to, newest first.
public enum RecentPlaylists {
    /// How many the picker shows.
    public static let shown = 3

    /// How many are remembered.
    public static let kept = 12

    /// `remembered`, with `id` moved to the front.
    public static func recording(_ id: String, in remembered: [String]) -> [String] {
        var updated = remembered.filter { $0 != id }
        updated.insert(id, at: 0)
        return Array(updated.prefix(kept))
    }

    /// The remembered playlists that still exist, newest first, at most
    /// `shown` of them.
    public static func resolve(_ remembered: [String], among playlists: [Playlist]) -> [Playlist] {
        let byID = Dictionary(playlists.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        // Filtered before the count is taken, not after: with the second of
        // four gone from the server, three still exist and three is what the
        // head of the picker should show.
        return Array(remembered.compactMap { byID[$0] }.prefix(shown))
    }
}
