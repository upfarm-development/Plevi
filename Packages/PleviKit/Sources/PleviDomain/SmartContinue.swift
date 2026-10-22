import Foundation

/// Carries a queue on past its end, with music drawn from the whole of it.
public enum SmartContinue {
    /// How many songs seed the blend. Enough for a queue to have a shape,
    /// few enough that the wait is one round of requests rather than ten.
    public static let seedCount = 6
    /// How many neighbours each seed contributes before blending.
    public static let neighboursPerSeed = 25
    /// How much is added when the queue runs out. Long enough not to keep
    /// asking, short enough that it follows where the listening has got to
    /// rather than where it started.
    public static let additionLength = 30
    /// How many songs may be left before the queue is topped up.
    public static let topUpWhenRemaining = 5
    /// At most this many songs from one artist, or from one record.
    public static let perArtist = 2
    public static let perAlbum = 2

    /// The rating below which a song is not offered, matching what every station and mix already
    /// applies — see `DJRatingFloor` and `LibraryIndex.favoriteRatingThreshold`, which is the same
    /// 2.5 and cannot be reached from here because the…
    public static let ratingFloor = 2.5

    /// The songs to seed from: a spread across what played, and always the most recent.
    public static func seeds(from played: [Track], limit: Int = seedCount) -> [Track] {
        guard !played.isEmpty, limit > 0 else { return [] }
        guard played.count > limit else { return deduplicated(played) }
        // One seed is the most recent. The spread below divides by
        // `limit - 1`, which for a limit of one is 0 × ∞ = NaN and traps in
        // `Int(_:)`.
        if limit == 1, let last = played.last { return [last] }

        var picked: [Track] = []
        // Evenly spaced, so the beginning and middle are represented too.
        let step = Double(played.count - 1) / Double(limit - 1)
        for position in 0..<limit {
            let index = Int((Double(position) * step).rounded())
            if played.indices.contains(index) { picked.append(played[index]) }
        }
        if let last = played.last { picked.append(last) }
        return Array(deduplicated(picked).prefix(limit))
    }

    /// The same idea as `seeds(from:limit:)` — a spread across what played, and always the most
    /// recent — but with the choice within each stretch left to chance, so the same queue does not
    /// ask about the same six songs every time.
    public static func variedSeeds<G: RandomNumberGenerator>(
        from played: [Track],
        limit: Int = seedCount,
        using generator: inout G
    ) -> [Track] {
        guard let last = played.last, limit > 0 else { return [] }
        // Nothing to choose between: every song is a seed.
        guard played.count > limit else { return deduplicated(played) }
        if limit == 1 { return [last] }

        let earlier = Array(played.dropLast())
        let stretches = limit - 1
        var picked: [Track] = []
        for stretch in 0..<stretches {
            let lower = stretch * earlier.count / stretches
            let upper = max(lower, (stretch + 1) * earlier.count / stretches - 1)
            picked.append(earlier[Int.random(in: lower...upper, using: &generator)])
        }
        picked.append(last)
        return Array(deduplicated(picked).prefix(limit))
    }

    private static func deduplicated(_ tracks: [Track]) -> [Track] {
        var seen: Set<MediaID> = []
        return tracks.filter { seen.insert($0.id).inserted }
    }

    /// Blends each seed's neighbours into one running order.
    public static func blend(
        _ neighbours: [[Track]],
        excluding excluded: Set<MediaID>,
        alreadyHeard: [Track] = [],
        limit: Int = additionLength,
        ratingFloor: Double = ratingFloor
    ) -> [Track] {
        // "Only as much as was asked for": `spread` stops on reaching the
        // limit, which a limit of zero never does, so it used to return
        // everything ranked.
        guard limit > 0 else { return [] }
        let (scores, bestRank, byID) = scored(neighbours, excluding: excluded, ratingFloor: ratingFloor)

        let ranked = scores.keys
            .sorted { left, right in
                let leftScore = scores[left] ?? 0
                let rightScore = scores[right] ?? 0
                if leftScore != rightScore { return leftScore > rightScore }
                // Level on breadth: the closer neighbour goes first.
                let leftRank = bestRank[left] ?? Int.max
                let rightRank = bestRank[right] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                // And a stable answer rather than whatever the dictionary
                // happened to hold, so the same queue blends the same way.
                return (byID[left]?.title ?? "") < (byID[right]?.title ?? "")
            }
            .compactMap { byID[$0] }

        return spread(ranked, limit: limit, alreadyHeard: alreadyHeard)
    }

    /// What each candidate is worth, how near its nearest seed had it, and the track itself.
    private static func scored(
        _ neighbours: [[Track]],
        excluding excluded: Set<MediaID>,
        ratingFloor: Double
    ) -> (scores: [MediaID: Double], bestRank: [MediaID: Int], byID: [MediaID: Track]) {
        var scores: [MediaID: Double] = [:]
        var bestRank: [MediaID: Int] = [:]
        var byID: [MediaID: Track] = [:]
        for list in neighbours {
            let count = list.count
            guard count > 0 else { continue }
            for (rank, track) in list.enumerated()
            where !excluded.contains(track.id)
                && DJRatingFloor.passes(track, atLeast: ratingFloor) {
                let weight = 1 - Double(rank) / Double(count)
                scores[track.id, default: 0] += weight
                bestRank[track.id] = min(bestRank[track.id] ?? Int.max, rank)
                byID[track.id] = track
            }
        }
        return (scores, bestRank, byID)
    }

    /// How sharply a song's score favours it in `blend(...
    static let varietyExponent = 2.0

    /// The same blend with chance in it: a weighted random draw from everything the seeds turned
    /// up, rather than the highest scores every time.
    public static func blend<G: RandomNumberGenerator>(
        _ neighbours: [[Track]],
        excluding excluded: Set<MediaID>,
        alreadyHeard: [Track] = [],
        limit: Int = additionLength,
        ratingFloor: Double = ratingFloor,
        varied generator: inout G
    ) -> [Track] {
        guard limit > 0 else { return [] }
        let (scores, _, byID) = scored(neighbours, excluding: excluded, ratingFloor: ratingFloor)

        // Drawn in a fixed order, so a seeded generator gives the same answer
        // whatever order the dictionary happens to hold its keys in.
        var drawn: [(id: MediaID, key: Double)] = []
        for id in scores.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let weight = pow(scores[id] ?? 0, varietyExponent)
            guard weight > 0 else { continue }
            // Efraimidis–Spirakis: ordering by log(u) / weight is ordering by
            // u^(1/weight), which picks each next song with probability
            // proportional to its weight.
            let u = 1 - Double.random(in: 0..<1, using: &generator)
            drawn.append((id, log(u) / weight))
        }
        let ranked = drawn
            .sorted { $0.key != $1.key ? $0.key > $1.key : $0.id.rawValue < $1.id.rawValue }
            .compactMap { byID[$0.id] }

        return spread(ranked, limit: limit, alreadyHeard: alreadyHeard)
    }

    /// Takes the ranked list and thins it out, so no artist or record dominates.
    static func spread(_ ranked: [Track], limit: Int, alreadyHeard: [Track] = []) -> [Track] {
        var chosen: [Track] = []
        var heldBack: [Track] = []
        var byArtist: [String: Int] = [:]
        var byAlbum: [String: Int] = [:]
        var songsAlready = Set(alreadyHeard.map(songKey))

        for track in ranked {
            let artist = (track.artistName ?? "").lowercased()
            let album = (track.albumName ?? "").lowercased()
            // The same song on a single and on the album it later appeared on are two library
            // entries and one song.
            guard songsAlready.insert(songKey(track)).inserted else { continue }
            let artistCount = artist.isEmpty ? 0 : byArtist[artist, default: 0]
            let albumCount = album.isEmpty ? 0 : byAlbum[album, default: 0]
            if artistCount >= perArtist || albumCount >= perAlbum {
                heldBack.append(track)
                continue
            }
            chosen.append(track)
            if !artist.isEmpty { byArtist[artist] = artistCount + 1 }
            if !album.isEmpty { byAlbum[album] = albumCount + 1 }
            if chosen.count == limit { return chosen }
        }

        for track in heldBack where chosen.count < limit {
            chosen.append(track)
        }
        return chosen
    }

    /// What makes two library entries the same song: the title and the
    /// artist, with case, accents and spacing ignored. Not the album, which is
    /// the very thing that differs between copies.
    static func songKey(_ track: Track) -> String {
        func folded(_ text: String?) -> String {
            (text ?? "")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        return "\(folded(track.artistName))\u{1F}\(folded(track.title))"
    }
}
