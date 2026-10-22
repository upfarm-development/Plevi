import Foundation

/// What every DJ strategy is forbidden to repeat.
public struct DJRepeatWindow: Sendable {
    /// Recently played, oldest first, capped at `historyCapacity`.
    private var history: [MediaID] = []
    private var historySet: Set<MediaID> = []
    /// Everything currently sitting in the queue — not just what a DJ put
    /// there. The user's own picks are just as much "already coming up" as
    /// a DJ's.
    private var queued: Set<MediaID> = []

    /// The same two halves, keyed on `songKeys(for:)` instead of a catalog id.
    private var songHistory: [Set<String>] = []
    private var songHistorySet: Set<String> = []
    /// Song keys of everything queued, with how many queued ids claim each.
    private var queuedSongCounts: [String: Int] = [:]
    private var queuedKeys: [MediaID: Set<String>] = [:]
    private var queuedSongs: Set<String> { Set(queuedSongCounts.keys) }

    public let historyCapacity: Int

    public init(historyCapacity: Int = 50) {
        self.historyCapacity = historyCapacity
    }

    /// Whether a track may be offered right now — by its own catalog id, not by what recording it
    /// is.
    public func excludes(_ id: MediaID) -> Bool {
        historySet.contains(id) || queued.contains(id)
    }

    /// Whether this recording — by its artist and title — is already
    /// playing, queued, or recently played under some other catalog id.
    public func excludesSong(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        return songHistorySet.contains(key) || queuedSongCounts[key] != nil
    }

    /// The same question asked with every key a recording answers to.
    public func excludesSong(anyOf keys: Set<String>) -> Bool {
        guard !keys.isEmpty else { return false }
        return !keys.isDisjoint(with: songHistorySet) || keys.contains { queuedSongCounts[$0] != nil }
    }

    /// Marks a track as played, aging out the oldest entry in each half
    /// once its window is full.
    public mutating func recordPlayed(_ track: Track) {
        recordPlayed(id: track.id)
        let keys = Self.songKeys(for: track)
        if !keys.isEmpty { recordSong(keys) }
    }

    private mutating func recordPlayed(id: MediaID) {
        guard historyCapacity > 0 else { return }
        if let existing = history.firstIndex(of: id) {
            // Heard again — moves to the front of the window rather than
            // being counted twice, so replaying a song does not shrink how
            // far back the window actually reaches.
            history.remove(at: existing)
        } else {
            historySet.insert(id)
        }
        history.append(id)
        while history.count > historyCapacity {
            let dropped = history.removeFirst()
            // Only truly gone if it is not sitting in the window twice,
            // which cannot happen after the de-dup above, but stays correct
            // if that ever changes.
            if !history.contains(dropped) { historySet.remove(dropped) }
        }
    }

    private mutating func recordSong(_ keys: Set<String>) {
        guard historyCapacity > 0 else { return }
        // Heard again — the entry moves to the front rather than being
        // counted twice. "Again" means any key in common, since two
        // spellings of one credit are one recording.
        if let existing = songHistory.firstIndex(where: { !$0.isDisjoint(with: keys) }) {
            songHistory.remove(at: existing)
        }
        songHistory.append(keys)
        while songHistory.count > historyCapacity {
            songHistory.removeFirst()
        }
        // Rebuilt from the list rather than patched alongside it.
        songHistorySet = songHistory.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// Replaces the "currently queued" half of both exclusion sets wholesale — called whenever a DJ
    /// is about to pick, so it always sees the real queue rather than a stale copy of one it built
    /// itself.
    public mutating func setQueued<S: Sequence>(_ tracks: S) where S.Element == Track {
        var incoming = Set<MediaID>()
        var fresh: [(MediaID, Set<String>)] = []
        for track in tracks where incoming.insert(track.id).inserted {
            if queuedKeys[track.id] == nil {
                fresh.append((track.id, Self.songKeys(for: track)))
            }
        }

        let gone = queuedKeys.keys.filter { !incoming.contains($0) }
        for id in gone {
            for key in queuedKeys[id] ?? [] {
                if let count = queuedSongCounts[key], count > 1 {
                    queuedSongCounts[key] = count - 1
                } else {
                    queuedSongCounts[key] = nil
                }
            }
            queuedKeys[id] = nil
        }
        for (id, keys) in fresh {
            queuedKeys[id] = keys
            for key in keys { queuedSongCounts[key, default: 0] += 1 }
        }
        queued = incoming
    }

    /// Every id currently excluded, for callers that want to hand a whole set to a query rather
    /// than call `excludes(_:)` per candidate.
    public var excludedIDs: Set<MediaID> {
        historySet.union(queued)
    }

    /// The song-identity equivalent of `excludedIDs` — every recording, by
    /// artist and title, this window already knows to steer around.
    public var excludedSongKeys: Set<String> {
        songHistorySet.union(queuedSongs)
    }

    public var isEmpty: Bool {
        historySet.isEmpty && queued.isEmpty
    }

    /// A normalised identity for the recording itself — the artist who owns it and the title —
    /// rather than for one catalog entry of it.
    public static func songKey(for track: Track) -> String? {
        guard let credit = track.artistName else { return nil }
        let artist = leadArtist(of: credit)
        guard !artist.isEmpty else { return nil }
        let title = withoutCredit(track.title)
        guard !title.isEmpty else { return nil }
        return "\(artist)|\(title)"
    }

    /// Every identity a recording answers to.
    public static func songKeys(for track: Track) -> Set<String> {
        guard let credit = track.artistName else { return [] }
        let title = withoutCredit(track.title)
        guard !title.isEmpty else { return [] }
        var keys: Set<String> = []
        let lead = leadArtist(of: credit)
        if !lead.isEmpty { keys.insert("\(lead)|\(title)") }
        let everyone = creditedNames(of: credit)
        if !everyone.isEmpty {
            keys.insert("\(everyone.joined(separator: "+"))|\(title)")
        }
        return keys
    }

    /// Every artist a credit names, lowercased and sorted.
    static func creditedNames(of credit: String) -> [String] {
        var parts = [credit.lowercased()]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// What comes between two names in a credit.
    static let separators = [
        " feat. ", " feat ", " featuring ", " ft. ", " ft ",
        " & ", " x ", " with ", ", ", " and ", " vs. ", " vs ",
    ]

    /// The first artist a credit names, which is the one whose recording it is however the rest of
    /// the line is punctuated.
    public static func leadArtist(of credit: String) -> String {
        let lowered = credit.lowercased()
        var cut = lowered.endIndex
        for separator in separators {
            if let found = lowered.range(of: separator), found.lowerBound < cut {
                cut = found.lowerBound
            }
        }
        return String(lowered[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A title with any trailing "(feat.
    static func withoutCredit(_ title: String) -> String {
        let lowered = title.lowercased()
        var cut = lowered.endIndex
        for opener in ["(feat", "(ft", "(featuring", "[feat", "[ft", "[featuring"] {
            if let found = lowered.range(of: opener), found.lowerBound < cut {
                cut = found.lowerBound
            }
        }
        return String(lowered[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
