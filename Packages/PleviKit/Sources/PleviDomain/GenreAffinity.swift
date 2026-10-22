import Foundation

/// Whether two records belong in the same mix, judged by what they are rather than by what they
/// sound like.
public enum GenreAffinity {
    /// Words that appear in tags without saying anything about the music, and
    /// would otherwise match everything to everything.
    private static let noise: Set<String> = [
        "music", "musical", "songs", "song", "general", "other", "misc",
        "miscellaneous", "various", "unknown", "stuff", "and", "the", "of",
        // "compilation" is a format, not a sound. Nothing that names a
        // kind of music belongs in here — "soundtrack" spent one commit in
        // this list and silently undid the whole point of the exercise.
        "compilation",
    ]

    /// The meaningful words in a tag.
    public static func tokens(of tag: String) -> Set<String> {
        let pieces = tag.lowercased().split { !$0.isLetter && !$0.isNumber }
        var out: Set<String> = []
        for piece in pieces {
            let whole = String(piece)
            var word = whole
            if word.count > 3, word.hasSuffix("s") { word.removeLast() }
            // Both forms, because dropping the "s" can carry a word out of the list it belonged in:
            // "various" becomes "variou", which is in no list at all and would go on to match every
            // other record filed under Various Artists.
            guard word.count >= 3, !noise.contains(word), !noise.contains(whole) else { continue }
            out.insert(word)
        }
        // A short tag is still a tag.
        if out.isEmpty {
            let compacted = tag.lowercased().filter { $0.isLetter || $0.isNumber }
            if !compacted.isEmpty, !noise.contains(compacted) { out.insert(compacted) }
        }
        return out
    }

    /// Everything a set of tags says, as one vocabulary.
    public static func tokens(of tags: some Sequence<String>) -> Set<String> {
        tags.reduce(into: Set<String>()) { $0.formUnion(tokens(of: $1)) }
    }

    /// Whether a candidate belongs beside a seed.
    public static func belongs(candidate: Set<String>, withSeed seed: Set<String>) -> Bool {
        guard !seed.isEmpty else { return true }
        guard !candidate.isEmpty else { return true }
        return !candidate.isDisjoint(with: seed)
    }
}
