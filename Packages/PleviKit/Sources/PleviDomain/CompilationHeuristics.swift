import Foundation

/// Whether a record is a collection of other records rather than one of its own — asked in one
/// place, because every backend answers it differently and none of them answers it well.
public enum CompilationHeuristics {
    /// What "Various Artists" is called, in the languages a server is likely to have filed it
    /// under.
    public static let variousArtistsCredits: Set<String> = [
        "various artists",
        "various",
        "va",
        "varios artistas",
        "artistes divers",
        "verschiedene interpreten",
        "diverse interpreten",
        "vari",
        "artisti vari",
        "vários artistas",
        "olika artister",
        "diverse kunstnere",
        "diverse artiesten",
        "разные исполнители",
        "オムニバス",
    ]

    /// Titles that describe a collection rather than name a record.
    public static let collectionTitleFragments: [String] = [
        "greatest hits",
        "best of",
        "the best of",
        "very best of",
        "essential",
        "essentials",
        "anthology",
        "collection",
        "the collection",
        "compilation",
        "singles collection",
        "hits collection",
        "number ones",
        "no. 1s",
        "retrospective",
        "definitive",
        "ultimate collection",
        "now that's what i call",
        "now thats what i call",
    ]

    /// Titles that name a decade, which a record about one decade of music is nearly always a
    /// collection of.
    private static let decadeExpression = try? NSRegularExpression(
        pattern: #"(?<![0-9])(?:19|20)?[2-9]0['’]?s(?![a-z0-9])"#,
        options: [.caseInsensitive]
    )

    /// Whether the credit is the one servers use for "no single artist".
    public static func isVariousArtists(_ credit: String?) -> Bool {
        guard let credit else { return false }
        let trimmed = credit
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return variousArtistsCredits.contains(trimmed)
    }

    /// Whether the title says the record is a collection.
    public static func titleSuggestsCollection(_ title: String?) -> Bool {
        guard let title else { return false }
        let lowered = title.lowercased()
        if collectionTitleFragments.contains(where: lowered.contains) { return true }
        guard let decadeExpression else { return false }
        let range = NSRange(lowered.startIndex..., in: lowered)
        return decadeExpression.firstMatch(in: lowered, range: range) != nil
    }

    /// The server's own answer, strengthened by what the record says about itself.
    public static func isCompilation(
        serverFlag: Bool,
        releaseTypes: [ReleaseType] = [],
        albumTitle: String? = nil,
        albumArtist: String? = nil
    ) -> Bool {
        if serverFlag { return true }
        if releaseTypes.contains(.compilation) { return true }
        if isVariousArtists(albumArtist) { return true }
        return titleSuggestsCollection(albumTitle)
    }
}
