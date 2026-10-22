import Foundation

/// One song, once — however many records it was licensed onto.
public enum DuplicateSongs {
    /// One catalog entry of a song, with the little that choosing between
    /// entries needs to know about the record it sits on.
    public struct Copy: Sendable {
        public var track: Track
        /// Whether the record is a collection of other people's records — a greatest-hits set, a
        /// various-artists compilation, a decade sampler.
        public var isFromCollection: Bool
        /// The year of the record the copy sits on, which for choosing
        /// between pressings beats the song's own year — a compilation
        /// stamps its songs with the year somebody pressed it.
        public var recordYear: Int?
        /// Whether this copy is on the phone.
        public var isDownloaded: Bool

        public init(
            track: Track,
            isFromCollection: Bool = false,
            recordYear: Int? = nil,
            isDownloaded: Bool = false
        ) {
            self.track = track
            self.isFromCollection = isFromCollection
            self.recordYear = recordYear
            self.isDownloaded = isDownloaded
        }
    }

    // MARK: Which songs are the same song

    /// Words that describe a *pressing* rather than a *performance*.
    public static let editionWords: Set<String> = [
        "remaster",
        "remastered",
        "remastering",
        "remasters",
        "master",
        "mastered",
        "mono",
        "stereo",
        "version",
        "edition",
        "mix",
        "original",
        "album",
        "single",
        "deluxe",
        "expanded",
        "anniversary",
        "reissue",
        "bonus",
        "track",
        "digital",
        "the",
        "of",
        "and",
    ]

    /// Words that introduce a credit rather than a version.
    public static let creditIntroducers: Set<String> = [
        "feat",
        "feats",
        "featuring",
        "ft",
    ]

    /// What makes two rows the same song.
    public static func key(for title: String) -> String {
        var text = title
            .foldingLatin()
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let shorter = strippingTrailingQualifier(text) {
            text = shorter
        }
        return condensed(text)
    }

    /// Peels one trailing "(...)", "[...]" or " - ..." off a title, if what it holds is only
    /// edition noise.
    private static func strippingTrailingQualifier(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let closer = trimmed.last, closer == ")" || closer == "]" {
            let opener: Character = closer == ")" ? "(" : "["
            guard let start = trimmed.lastIndex(of: opener), start != trimmed.startIndex else {
                return nil
            }
            let inside = String(trimmed[trimmed.index(after: start)..<trimmed.index(before: trimmed.endIndex)])
            guard isNoise(inside) else { return nil }
            return String(trimmed[trimmed.startIndex..<start])
        }

        // The other spelling, which is what tags imported from streaming
        // services use: "Marquee Moon - 2003 Remaster". Only with spaces
        // around it, so a hyphenated word keeps its hyphen.
        for separator in [" - ", " – ", " — "] {
            if let dash = trimmed.range(of: separator, options: .backwards) {
                let inside = String(trimmed[dash.upperBound...])
                guard isNoise(inside) else { return nil }
                return String(trimmed[trimmed.startIndex..<dash.lowerBound])
            }
        }
        return nil
    }

    /// A year, and only a year, that a qualifier may carry without meaning
    /// anything — "(2011 Remaster)" and "(Remastered 2011)" are the same
    /// thing said twice.
    private static let yearExpression = try? NSRegularExpression(
        pattern: #"(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])"#
    )

    /// Whether a qualifier carries no information about which recording this is.
    private static func isNoise(_ qualifier: String) -> Bool {
        var text = qualifier
        if let yearExpression {
            text = yearExpression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: " "
            )
        }
        // A number that was not a year. It is saying something, and this
        // cannot read it.
        guard !text.contains(where: \.isNumber) else { return false }

        let words = text.split { !$0.isLetter }.map(String.init)
        // Nothing left but the year that was taken out. A year alone is a
        // date, and a date is how a performance is named.
        guard let first = words.first else { return false }
        if creditIntroducers.contains(first) { return true }
        return words.allSatisfy(editionWords.contains)
    }

    /// Letters and digits, single-spaced. Apostrophes close up rather than
    /// split, so the two spellings of "Don't" — the typewriter one and the
    /// typographic one servers love to differ on — land on the same key.
    private static func condensed(_ text: String) -> String {
        var out = ""
        var gap = false
        for character in text {
            if character.isLetter || character.isNumber {
                if gap, !out.isEmpty { out.append(" ") }
                gap = false
                out.append(character)
            } else if character == "'" || character == "\u{2019}" || character == "\u{02BC}" {
                continue
            } else {
                gap = true
            }
        }
        return out
    }

    // MARK: Which copy to keep

    /// How far apart two copies may be in length and still be one recording.
    static func isSameLength(_ one: TimeInterval?, _ other: TimeInterval?) -> Bool {
        guard let one, let other, one > 0, other > 0 else {
            // One of them is untagged. Nothing to object with.
            return true
        }
        return abs(one - other) <= max(3, max(one, other) * 0.05)
    }

    /// Folds every song down to one copy, keeping the order it was given.
    public static func pruned(_ copies: [Copy]) -> [Track] {
        var kept: [Copy] = []
        kept.reserveCapacity(copies.count)
        var slots: [String: [Int]] = [:]

        for copy in copies {
            let songKey = key(for: copy.track.title)
            guard !songKey.isEmpty else {
                // A title that folds away to nothing is one we cannot speak
                // for. Shown rather than silently dropped.
                kept.append(copy)
                continue
            }
            var joined = false
            for index in slots[songKey] ?? [] {
                guard isSameLength(copy.track.duration, kept[index].track.duration) else {
                    continue
                }
                if prefers(copy, over: kept[index]) { kept[index] = copy }
                joined = true
                break
            }
            if !joined {
                slots[songKey, default: []].append(kept.count)
                kept.append(copy)
            }
        }
        return kept.map(\.track)
    }

    /// The same, for callers that only have the songs — the record is judged
    /// by its title alone, which is the narrower half of what
    /// `CompilationHeuristics` can answer with an album in hand.
    public static func pruned(_ tracks: [Track]) -> [Track] {
        pruned(tracks.map {
            Copy(
                track: $0,
                isFromCollection: CompilationHeuristics.titleSuggestsCollection($0.albumName),
                recordYear: $0.year
            )
        })
    }

    /// Which of two copies of one song to show.
    static func prefers(_ candidate: Copy, over incumbent: Copy) -> Bool {
        let new = candidate.track
        let old = incumbent.track

        let newRating = new.rating?.value ?? 0
        let oldRating = old.rating?.value ?? 0
        if newRating != oldRating { return newRating > oldRating }

        if new.isFavorite != old.isFavorite { return new.isFavorite }

        if candidate.isDownloaded != incumbent.isDownloaded {
            return candidate.isDownloaded
        }

        if candidate.isFromCollection != incumbent.isFromCollection {
            return !candidate.isFromCollection
        }

        if candidate.recordYear != incumbent.recordYear {
            // A record with no year never displaces one that has a year;
            // "unknown" is not "early".
            guard let newYear = candidate.recordYear else { return false }
            guard let oldYear = incumbent.recordYear else { return true }
            return newYear < oldYear
        }

        let newPlays = new.playCount ?? 0
        let oldPlays = old.playCount ?? 0
        if newPlays != oldPlays { return newPlays > oldPlays }

        // Everything worth asking has been asked. Settle it on the id so the
        // shelf shows the same copy every time it is drawn rather than
        // whichever row the database happened to read first.
        return new.id.rawValue < old.id.rawValue
    }
}
