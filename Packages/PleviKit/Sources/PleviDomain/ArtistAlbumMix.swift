import Foundation

/// The Artist & Album Mixer: a queue built from a hand-picked set of artists and albums, leaning
/// whichever way the listener asked it to.
public enum ArtistAlbumMix {
    /// How long a mix runs. The same 200 every other radio in the app uses —
    /// see `RadioStations.queueLength`, which this deliberately matches so a
    /// mix is the same kind of thing as a station.
    public static let queueLength = 200

    /// Which way the mix leans.
    public enum Emphasis: String, CaseIterable, Hashable, Sendable, Codable {
        case shuffle
        case rarelyPlayed
        case topRated
        case popular

        public var title: String {
            switch self {
            case .shuffle: "Shuffle"
            case .rarelyPlayed: "Rarely Played"
            case .topRated: "Top Rated"
            case .popular: "Popular"
            }
        }

        public var subtitle: String {
            switch self {
            case .shuffle: "Everything, evenly"
            case .rarelyPlayed: "The ones you've hardly heard"
            case .topRated: "The ones you rated highest"
            case .popular: "The ones played most"
            }
        }

        public var symbol: String {
            switch self {
            case .shuffle: "shuffle"
            case .rarelyPlayed: "moon.stars"
            case .topRated: "star"
            case .popular: "chart.bar.fill"
            }
        }
    }

    /// What one track is worth to the draw under a given emphasis.
    public static func weight(for track: Track, emphasis: Emphasis) -> Double {
        switch emphasis {
        case .shuffle:
            return 1

        case .rarelyPlayed:
            // Unplayed is the top of this scale, not an outlier above it: a library freshly moved
            // from another server can have every count at zero, and a curve that spiked there would
            // make those the only songs a mix ever drew.
            let plays = max(track.playCount ?? 0, 0)
            return 1 + 8 / Double(plays + 1)

        case .topRated:
            // Four stars and up is what "top rated" is asking for, so the step from 3.5 to 4 is the
            // big one.
            guard let rating = track.rating?.value else { return 1 }
            if rating >= 4.5 { return 24 }
            if rating >= 4 { return 16 }
            if rating >= 3.5 { return 6 }
            return 2

        case .popular:
            // Compressed rather than proportional: play counts are heavily skewed, and weighting by
            // the raw number would hand a mix to the one song played four hundred times.
            let plays = max(track.playCount ?? 0, 0)
            return 1 + 4 * log(Double(plays) + 1)
        }
    }

    /// The tracks a mix will actually consider: the selection, minus anything rated below the
    /// floor.
    public static func pool(
        from tracks: [Track],
        ratingFloor: Double
    ) -> [Track] {
        var seen: Set<MediaID> = []
        var kept: [Track] = []
        for track in tracks where DJRatingFloor.passes(track, atLeast: ratingFloor) {
            guard seen.insert(track.id).inserted else { continue }
            kept.append(track)
        }
        return kept
    }

    /// A mix: the pool, drawn under the emphasis, then spread so the same artist does not run on
    /// and on.
    public static func build(
        pool: [Track],
        limit: Int = queueLength,
        emphasis: Emphasis,
        artistCount: Int,
        using generator: inout some RandomNumberGenerator
    ) -> [Track] {
        let drawn = sample(pool, limit: limit, emphasis: emphasis, using: &generator)
        return spread(drawn, artistCount: artistCount)
    }

    /// Weighted sampling without replacement — which songs get in, *and* the order they arrive in.
    public static func sample(
        _ pool: [Track],
        limit: Int,
        emphasis: Emphasis,
        using generator: inout some RandomNumberGenerator
    ) -> [Track] {
        guard limit > 0, !pool.isEmpty else { return [] }
        let keyed = pool.map { track -> (track: Track, key: Double) in
            let weight = max(weight(for: track, emphasis: emphasis), .leastNormalMagnitude)
            // The floor keeps a zero draw from becoming an infinite key.
            let uniform = max(Double.random(in: 0..<1, using: &generator), .leastNormalMagnitude)
            return (track, pow(uniform, 1 / weight))
        }
        return keyed
            .sorted { $0.key > $1.key }
            .prefix(limit)
            .map(\.track)
    }

    /// How many of the same artist may play back to back before it stops
    /// reading as a mix and starts reading as an album.
    static let maximumRun = 2

    /// Whether every group can still be kept `run` apart once one track has
    /// been taken from `taken` — see `spread`, which is the only caller and
    /// where the arithmetic is explained.
    private static func leaves(
        _ remaining: [String: Int], arrangeableAfter taken: String, of total: Int, run: Int
    ) -> Bool {
        let left = total - 1
        for (name, count) in remaining {
            let after = name == taken ? count - 1 : count
            guard after > 0 else { continue }
            if after > (left - after + 1) * run { return false }
        }
        return true
    }

    /// The earliest track belonging to whichever group has the most left to
    /// place — the choice that can never strand anything.
    private static func mostRemaining(
        in pending: [Track],
        remaining: [String: Int],
        key: (Track) -> String,
        excluding blocked: String? = nil
    ) -> Int? {
        pending.indices
            .filter { blocked == nil || key(pending[$0]) != blocked }
            .min { left, right in
                let leftCount = remaining[key(pending[left])] ?? 0
                let rightCount = remaining[key(pending[right])] ?? 0
                return leftCount == rightCount ? left < right : leftCount > rightCount
            }
    }

    /// Reorders so one artist does not dominate a stretch of the queue.
    public static func spread(_ tracks: [Track], artistCount: Int) -> [Track] {
        let key: (Track) -> String = artistCount >= 3
            ? { ($0.artistName ?? "").lowercased() }
            : { ($0.albumName ?? "").lowercased() }
        let run = artistCount >= 3 ? maximumRun : 1

        var pending = tracks
        var remaining: [String: Int] = pending.reduce(into: [:]) { $0[key($1), default: 0] += 1 }
        var out: [Track] = []
        out.reserveCapacity(tracks.count)
        var lastKey: String?
        var runLength = 0

        while !pending.isEmpty {
            let blocked = (lastKey != nil && runLength >= run) ? lastKey : nil
            let index: Int
            if blocked == nil {
                // Free to take anything, so take the best song still going — this is the step that
                // keeps the emphasis's order — but only if doing so leaves the rest arrangeable.
                let leading = key(pending[0])
                index = leaves(remaining, arrangeableAfter: leading, of: pending.count, run: run)
                    ? 0
                    : mostRemaining(in: pending, remaining: remaining, key: key) ?? 0
            } else {
                // A separator is needed.
                index = mostRemaining(
                    in: pending, remaining: remaining, key: key, excluding: blocked
                ) ?? 0
            }

            let picked = pending.remove(at: index)
            let pickedKey = key(picked)
            remaining[pickedKey] = (remaining[pickedKey] ?? 1) - 1
            out.append(picked)

            if pickedKey == lastKey {
                runLength += 1
            } else {
                lastKey = pickedKey
                runLength = 1
            }
        }
        return out
    }
}
