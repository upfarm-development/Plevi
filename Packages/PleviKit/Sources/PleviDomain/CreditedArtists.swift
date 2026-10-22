import Foundation

/// The people named in a track's artist credit, taken apart.
public enum CreditedArtists {
    /// What separates one name from the next.
    private static let separators = [
        " & ", " / ", ", ", " feat. ", " feat ", " ft. ", " ft ",
        " featuring ", " with ", " x ", " vs. ", " vs ",
    ]

    /// The names in a credit, in the order they are written, without repeats.
    public static func names(in credit: String) -> [String] {
        let whole = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }

        var parts: [String] = [whole]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }

        var out: [String] = []
        var seen = Set<String>()
        for name in [whole] + parts {
            let tidied = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tidied.isEmpty else { continue }
            let key = tidied.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(tidied)
        }
        return out
    }

    /// The artists a credit names that the library actually holds.
    public static func named(
        in credit: String,
        resolve: (String) -> Artist?
    ) -> [Artist] {
        var out: [Artist] = []
        var seen = Set<MediaID>()
        for name in names(in: credit) {
            guard let artist = resolve(name), !seen.contains(artist.id) else { continue }
            seen.insert(artist.id)
            out.append(artist)
            // The credit resolved whole: it is one act with a separator in
            // its name, and its parts are not other people.
            if out.count == 1, artist.name.count == credit.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).count {
                return out
            }
        }
        return out
    }
}
