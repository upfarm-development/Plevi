import Foundation

/// One well-reviewed record a day, chosen from the library rather than from anybody's listening.
public enum EditorsChoice {
    /// How highly a reviewer has to have thought of a record, out of ten.
    public static let minimumScore = 7.0

    /// How long a record waits before it can come round again.
    public static let restDays = 60

    /// How long the same kind of music waits before it comes round again.
    public static let genreRestDays = 3
    public static let decadeRestDays = 2

    /// A record shown on a day, kept so neither it nor its kind comes round again too soon.
    public struct Appearance: Hashable, Sendable, Codable {
        public let albumID: MediaID
        public let day: Int
        /// The genre family, already canonical — see `GenreFamily.canonical`.
        public var genre: String?
        public var decade: Int?

        public init(albumID: MediaID, day: Int, genre: String? = nil, decade: Int? = nil) {
            self.albumID = albumID
            self.day = day
            self.genre = genre
            self.decade = decade
        }

        /// What an album's appearance looks like, canonicalised.
        public init(album: Album, day: Int) {
            self.albumID = album.id
            self.day = day
            self.genre = album.genre.map(GenreFamily.canonical)
            self.decade = album.year.map { ($0 / 10) * 10 }
        }
    }

    /// Today's record, or nothing.
    public static let shortestUsableReview = 40

    /// Whether there is something to read on the card.
    public static func hasUsableReview(_ album: Album) -> Bool {
        guard let review = album.review else { return false }
        return review.trimmingCharacters(in: .whitespacesAndNewlines).count
            >= shortestUsableReview
    }

    /// Whether the record has a single artist to have written about.
    public static func hasSingleArtist(_ album: Album) -> Bool {
        !CompilationHeuristics.isVariousArtists(album.artistName)
    }

    public static func pick(
        for day: Int,
        from candidates: [Album],
        recentlyShown: [Appearance] = []
    ) -> Album? {
        // The review is the point of the card, not a decoration on it, so a record without one is
        // not a candidate however well it was reviewed.
        let candidates = candidates.filter(hasUsableReview).filter(hasSingleArtist)
        guard !candidates.isEmpty else { return nil }

        // Strictly *before* today.
        let recent = recentlyShown.filter { $0.day < day }
        func within(_ days: Int) -> [Appearance] {
            recent.filter { day - $0.day < days }
        }

        let resting = Set(within(restDays).map(\.albumID))
        let tiredGenres = Set(within(genreRestDays).compactMap(\.genre))
        let tiredDecades = Set(within(decadeRestDays).compactMap(\.decade))

        func genre(of album: Album) -> String? {
            album.genre.map(GenreFamily.canonical)
        }
        func decade(of album: Album) -> Int? {
            album.year.map { ($0 / 10) * 10 }
        }

        // Every rule at once, then the same list with the weakest rule dropped, and so on down.
        let tiers: [(Album) -> Bool] = [
            { !resting.contains($0.id)
                && !tiredGenres.contains(genre(of: $0) ?? "")
                && !tiredDecades.contains(decade(of: $0) ?? .min) },
            { !resting.contains($0.id)
                && !tiredGenres.contains(genre(of: $0) ?? "") },
            { !resting.contains($0.id) },
            { _ in true },
        ]

        for allows in tiers {
            let pool = candidates.filter(allows)
            guard !pool.isEmpty else { continue }
            return pool[index(for: day, count: pool.count)]
        }
        return nil
    }

    /// Which of them, for a given day.
    static func index(for day: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        // FNV-1a over the day's digits. Spelled out rather than using
        // `hashValue`, which Swift seeds differently per process and would
        // give a different record every launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in String(day).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(count))
    }

    /// The excerpt the card shows.
    public static func excerpt(from review: String, limit: Int = 220) -> String {
        let clean = review
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }

        var out = ""
        var sentence = ""
        for character in clean {
            sentence.append(character)
            guard character == "." || character == "!" || character == "?" else { continue }
            if out.count + sentence.count > limit, !out.isEmpty { break }
            out += sentence
            sentence = ""
        }
        guard !out.isEmpty else {
            // No sentence ended before the limit. Take it to the last word
            // that fits rather than cutting a word in half.
            let head = clean.prefix(limit)
            guard let lastSpace = head.lastIndex(of: " ") else { return String(head) + "…" }
            return String(head[head.startIndex..<lastSpace]) + "…"
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

}
