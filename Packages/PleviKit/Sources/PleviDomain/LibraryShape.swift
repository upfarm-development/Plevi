import Foundation

/// What a library is made of: its genres, gathered into families, and how much of each belongs to
/// each decade.
public struct LibraryShape: Hashable, Sendable, Codable {
    public var totalTracks: Int
    public var families: [GenreFamily.Family]
    /// Songs per family per decade, keyed by `key(genre:decade:)`.
    public var decadeCounts: [String: Int]

    public init(
        totalTracks: Int = 0,
        families: [GenreFamily.Family] = [],
        decadeCounts: [String: Int] = [:]
    ) {
        self.totalTracks = totalTracks
        self.families = families
        self.decadeCounts = decadeCounts
    }

    public static func key(genre: String, decade: Int) -> String {
        "\(genre)|\(decade)"
    }

    public func family(named name: String) -> GenreFamily.Family? {
        families.first { $0.name == name }
    }

    /// The family a library's own spelling belongs to.
    public func family(matching raw: String) -> GenreFamily.Family? {
        let key = GenreFamily.key(raw)
        return families.first { family in
            family.members.contains { GenreFamily.key($0) == key }
        }
    }

    /// How many songs a mix of this shape would have to draw on.
    public func depth(genre: String, decade: Int?) -> Int {
        guard let decade else { return family(named: genre)?.songs ?? 0 }
        return decadeCounts[Self.key(genre: genre, decade: decade)] ?? 0
    }

    /// How much of the library it would be, from nothing to all of it.
    public func share(genre: String, decade: Int?) -> Double {
        guard totalTracks > 0 else { return 0 }
        return Double(depth(genre: genre, decade: decade)) / Double(totalTracks)
    }
}
