import Foundation

/// What a smart shuffle can take into account.
public enum ShuffleSignal: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Higher rated comes up more often.
    case rating
    /// Longer since you heard it comes up more often. Never played counts as
    /// the longest possible time.
    case lastPlayed
    /// Less played comes up more often, over the whole life of the library
    /// rather than recently.
    case playCount

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rating: "Rating"
        case .lastPlayed: "Not played in a while"
        case .playCount: "Played least often"
        }
    }

    public var caption: String {
        switch self {
        case .rating: "Songs you rated highly come up more"
        case .lastPlayed: "The longer since you heard it, the more likely"
        case .playCount: "Favours songs you have played least"
        }
    }
}

/// How the shuffle is set up.
public struct SmartShuffleSettings: Codable, Hashable, Sendable {
    /// In order of importance, most important first. Each one counts half as
    /// much as the one above it, so the order is the weighting.
    public var ranking: [ShuffleSignal]
    /// Which of them are switched on.
    public var enabled: Set<ShuffleSignal>
    /// The fewest songs between two by the same artist. 0 turns it off.
    public var artistSpacing: Int
    /// The fewest songs between two from the same record.
    public var albumSpacing: Int

    public init(
        ranking: [ShuffleSignal] = ShuffleSignal.allCases,
        enabled: Set<ShuffleSignal> = Set(ShuffleSignal.allCases),
        artistSpacing: Int = 5,
        albumSpacing: Int = 3
    ) {
        self.ranking = ranking
        self.enabled = enabled
        self.artistSpacing = artistSpacing
        self.albumSpacing = albumSpacing
    }

    /// The ranking with anything missing appended, so a list saved before a
    /// signal existed still mentions every signal exactly once.
    public var completeRanking: [ShuffleSignal] {
        var seen = Set<ShuffleSignal>()
        var result = ranking.filter { seen.insert($0).inserted }
        result.append(contentsOf: ShuffleSignal.allCases.filter { !seen.contains($0) })
        return result
    }
}

/// A shuffle that is deliberately not uniform.
public enum SmartShuffle {
    /// What an unrated song is worth.
    public static let unratedStars = 3.0
    /// Beyond this, "ages ago" stops meaning anything more.
    public static let staleAfterDays = 365.0
    /// Everything keeps a floor of a chance, or a shuffle becomes a playlist.
    public static let floor = 0.08
    /// How far ahead the spacing pass will look for a song that fits.
    static let scanLimit = 64
    /// How far the tail of the spacing pass looks for the least bad song to
    /// place when nothing fits.
    static let tailScanLimit = 256

    /// Whether a particular shuffle should be the smart one.
    public static func isSmart(
        default byDefault: Bool,
        override: Bool? = nil,
        isAlbum: Bool
    ) -> Bool {
        guard !isAlbum else { return false }
        return override ?? byDefault
    }

    public static func order(
        _ tracks: [Track],
        settings: SmartShuffleSettings,
        now: Date = Date(),
        using generator: inout some RandomNumberGenerator
    ) -> [Track] {
        guard tracks.count > 1 else { return tracks }
        return orderedPositions(tracks, settings: settings, now: now, using: &generator)
            .map { tracks[$0] }
    }

    /// The same shuffle as a permutation of indices into `tracks`.
    public static func orderedPositions(
        _ tracks: [Track],
        settings: SmartShuffleSettings,
        now: Date = Date(),
        using generator: inout some RandomNumberGenerator
    ) -> [Int] {
        guard tracks.count > 1 else { return Array(tracks.indices) }

        let weights = weighting(for: settings)
        // Positions are sorted rather than songs. A `Track` is a wide struct,
        // and sorting sixty thousand of them moves megabytes about for no
        // reason; sorting integers alongside their keys does not.
        var keyed = [(position: Int, key: Double)]()
        keyed.reserveCapacity(tracks.count)
        for (position, track) in tracks.enumerated() {
            let score = score(track, weights: weights, now: now)
            // Efraimidis–Spirakis: with a key of U^(1/w), sorting by key is a weighted draw without
            // replacement — one pass rather than picking one song at a time, which matters at sixty
            // thousand.
            let u = Double.random(in: 0.000001..<1, using: &generator)
            keyed.append((position, pow(u, 1 / max(score, floor))))
        }
        keyed.sort { $0.key > $1.key }

        return space(positions: keyed.map(\.position), in: tracks, settings: settings)
    }

    /// Halving weights: each signal counts half as much as the one above.
    static func weighting(for settings: SmartShuffleSettings) -> [ShuffleSignal: Double] {
        var weights: [ShuffleSignal: Double] = [:]
        var share = 1.0
        for signal in settings.completeRanking where settings.enabled.contains(signal) {
            weights[signal] = share
            share /= 2
        }
        return weights
    }

    /// A song's chance, from 0 to 1, before the dice are thrown.
    static func score(_ track: Track, weights: [ShuffleSignal: Double], now: Date) -> Double {
        guard !weights.isEmpty else { return 1 }
        var total = 0.0
        var divisor = 0.0

        for (signal, weight) in weights {
            let value: Double
            switch signal {
            case .rating:
                value = (track.rating?.value ?? unratedStars) / 5

            case .lastPlayed:
                guard let played = track.playedAt else {
                    // Never heard. Nothing has waited longer than that.
                    value = 1
                    break
                }
                let days = now.timeIntervalSince(played) / 86_400
                value = min(max(days, 0), staleAfterDays) / staleAfterDays

            case .playCount:
                let plays = Double(max(track.playCount ?? 0, 0))
                // Falls away quickly at first — the gap between never and
                // once matters more than between forty and forty-one.
                value = 1 / (1 + plays)
            }
            total += weight * value
            divisor += weight
        }

        return divisor > 0 ? total / divisor : 1
    }

    /// Pushes songs by the same artist, and from the same record, apart.
    public static func space(_ tracks: [Track], settings: SmartShuffleSettings) -> [Track] {
        space(positions: Array(tracks.indices), in: tracks, settings: settings)
            .map { tracks[$0] }
    }

    /// A weighted draw of `count` things, without replacement, different every time it is asked.
    public static func drawing<Item>(
        _ items: [Item],
        count: Int,
        using generator: inout some RandomNumberGenerator,
        weight: (Item) -> Double
    ) -> [Item] {
        guard count > 0, !items.isEmpty else { return [] }
        guard count < items.count else {
            // Everything is being taken, so there is nothing to choose — but
            // the order still gets the draw, since that is what decides
            // which of them a caller hears first.
            return items
                .map { ($0, key(for: $0, weight: weight, using: &generator)) }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        return items
            .map { ($0, key(for: $0, weight: weight, using: &generator)) }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map(\.0)
    }

    private static func key<Item>(
        for item: Item,
        weight: (Item) -> Double,
        using generator: inout some RandomNumberGenerator
    ) -> Double {
        // Floored at both ends: a zero or negative weight would divide by
        // nothing, and a zero draw would raise to an infinite key and win
        // every time.
        let w = max(weight(item), floor)
        let u = max(Double.random(in: 0..<1, using: &generator), .leastNormalMagnitude)
        return pow(u, 1 / w)
    }

    /// Pushes songs by the same artist, and from the same record, apart.
    static func space(
        positions: [Int],
        in tracks: [Track],
        settings: SmartShuffleSettings
    ) -> [Int] {
        let artistGap = max(0, settings.artistSpacing)
        let albumGap = max(0, settings.albumSpacing)
        guard artistGap > 0 || albumGap > 0 else { return positions }

        // Names are folded to a comparison key exactly once.
        var credits: [String: String?] = [:]
        let artistKeys = tracks.map { track -> String? in
            guard let name = track.artistName else {
                return key(track.artistID?.rawValue)
            }
            if let known = credits[name] {
                return known ?? key(track.artistID?.rawValue)
            }
            let credit = primaryCredit(name)
            credits[name] = credit
            return credit ?? key(track.artistID?.rawValue)
        }
        let albumKeys = tracks.map { key($0.albumName ?? $0.albumID?.rawValue) }

        var result: [Int] = []
        result.reserveCapacity(positions.count)
        var lastArtist: [String: Int] = [:]
        var lastAlbum: [String: Int] = [:]
        var waiting: [Int] = []

        func fits(_ position: Int) -> Bool {
            let slot = result.count
            if artistGap > 0, let artist = artistKeys[position],
               let previous = lastArtist[artist], slot - previous <= artistGap {
                return false
            }
            if albumGap > 0, let album = albumKeys[position],
               let previous = lastAlbum[album], slot - previous <= albumGap {
                return false
            }
            return true
        }

        func place(_ position: Int) {
            if let artist = artistKeys[position] { lastArtist[artist] = result.count }
            if let album = albumKeys[position] { lastAlbum[album] = result.count }
            result.append(position)
        }

        /// How long since this song's artist or record was last heard, in
        /// slots. Larger is better company for the next one.
        func distanceSinceLastHeard(_ position: Int) -> Int {
            var nearest = Int.max
            if let artist = artistKeys[position], let previous = lastArtist[artist] {
                nearest = min(nearest, result.count - previous)
            }
            if let album = albumKeys[position], let previous = lastAlbum[album] {
                nearest = min(nearest, result.count - previous)
            }
            return nearest
        }

        /// The first held-back song that fits, looking no further than `scanLimit`.
        func placeFromWaiting() -> Bool {
            let reach = min(waiting.count, scanLimit)
            for index in 0..<reach where fits(waiting[index]) {
                place(waiting.remove(at: index))
                return true
            }
            return false
        }

        for position in positions {
            while placeFromWaiting() {}
            fits(position) ? place(position) : waiting.append(position)
        }

        // The tail is the part no forward pass can win.
        while !waiting.isEmpty {
            if placeFromWaiting() { continue }
            // Looked for in the first few hundred, as the forward pass looks in the first
            // `scanLimit`.
            let reach = min(waiting.count, tailScanLimit)
            let index = (0..<reach).max { left, right in
                distanceSinceLastHeard(waiting[left]) < distanceSinceLastHeard(waiting[right])
            } ?? 0
            place(waiting.remove(at: index))
        }
        return result
    }

    /// What counts as one artist, for the purpose of keeping them apart.
    static func artistKey(id: MediaID?, name: String?) -> String? {
        primaryCredit(name) ?? key(id?.rawValue)
    }

    /// A credit as far as the first guest, folded down to letters and digits.
    static func primaryCredit(_ name: String?) -> String? {
        guard let name else { return nil }
        var words: [String] = []
        var word = ""
        for character in name.foldingLatin().lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if character == "'" || character == "\u{2019}" {
                continue
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        // The word only introduces a guest when there is a name on both sides of it.
        if let cut = words.firstIndex(where: DuplicateSongs.creditIntroducers.contains),
           cut > 0, cut < words.count - 1 {
            words = Array(words[..<cut])
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func key(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
