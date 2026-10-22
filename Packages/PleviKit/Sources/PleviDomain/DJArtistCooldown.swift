import Foundation

/// Keeps a DJ from stacking several picks by the same artist into one gap, or into the next gap
/// right after it — the same repeat-avoidance idea `DJRepeatWindow` applies to individual tracks,
/// one level up.
public struct DJArtistCooldown: Sendable {
    private var recent: [String] = []
    public let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = capacity
    }

    public func excludes(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        return recent.contains(key)
    }

    /// Moves a repeat to the front rather than double-counting it, the same
    /// way `DJRepeatWindow.recordPlayed` treats a track heard again.
    public mutating func record(_ key: String?) {
        guard let key, !key.isEmpty else { return }
        recent.removeAll { $0 == key }
        recent.append(key)
        while recent.count > capacity { recent.removeFirst() }
    }

    /// The identity a track's artist cools down under — its id where the server gave one, its
    /// credited name otherwise.
    public static func key(for track: Track) -> String? {
        if let id = track.artistID?.rawValue { return id }
        let name = track.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// Picks up to `limit` tracks from a ranked pool, skipping anything by an artist already
    /// cooling down or already taken earlier in this same pick — without ever handing back fewer
    /// than the pool can honestly supply.
    public func diversePick(from ranked: [Track], limit: Int) -> [Track] {
        guard limit > 0 else { return [] }
        var picked: [Track] = []
        var usedThisPick: Set<String> = []
        for track in ranked {
            guard picked.count < limit else { break }
            let key = Self.key(for: track)
            if let key, excludes(key) || usedThisPick.contains(key) { continue }
            picked.append(track)
            if let key { usedThisPick.insert(key) }
        }
        guard picked.count < limit else { return picked }
        for track in ranked where !picked.contains(where: { $0.id == track.id }) {
            guard picked.count < limit else { break }
            picked.append(track)
        }
        return picked
    }
}
