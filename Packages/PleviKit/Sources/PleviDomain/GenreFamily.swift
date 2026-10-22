import Foundation

/// Gathers the several names one genre goes by into a single family.
public enum GenreFamily {
    /// One genre, with every name the library files it under.
    public struct Family: Hashable, Sendable, Codable {
        /// What it is called on screen, and how a mix records it.
        public var name: String
        /// The library's own spellings — what a query has to match on. The
        /// family name is for reading, not for asking the database with.
        public var members: [String]
        public var songs: Int

        public init(name: String, members: [String], songs: Int) {
            self.name = name
            self.members = members
            self.songs = songs
        }
    }

    /// The name a genre is filed under once its variants are gathered, or the name it already had.
    public static func canonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return aliases[normalised(trimmed)] ?? trimmed
    }

    /// Groups a library's genres, given how many songs each has.
    public static func families(of counts: [String: Int]) -> [Family] {
        var grouped: [String: [(name: String, songs: Int)]] = [:]
        for (raw, songs) in counts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            grouped[key(trimmed), default: []].append((trimmed, songs))
        }

        return grouped.map { key, members in
            // An alias key is already the family's name. Anything else is a
            // normalised form, which is no name at all — so the library's
            // own most-used spelling is used instead.
            let name = aliasNames.contains(key)
                ? key
                : members.max { $0.songs < $1.songs }?.name ?? key
            return Family(
                name: name,
                members: members.map(\.name).sorted(),
                songs: members.reduce(0) { $0 + $1.songs }
            )
        }
        .sorted { $0.songs > $1.songs }
    }

    /// What two names have to share to be the same genre: either the table
    /// says so, or they are the same words under different punctuation.
    public static func key(_ raw: String) -> String {
        let normal = normalised(raw)
        return aliases[normal] ?? normal
    }

    /// The family names the table produces, so a key can be told from a
    /// normalised form.
    private static let aliasNames: Set<String> = Set(aliases.values)

    /// Case, punctuation and spacing off, so the same words in any dress
    /// arrive at the same key.
    static func normalised(_ raw: String) -> String {
        let separators = CharacterSet(charactersIn: "&/,-–—_.+()[]")
        let words = raw
            .lowercased()
            .components(separatedBy: separators)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    /// Normalised name to the family it belongs to.
    private static let aliases: [String: String] = {
        var table: [String: String] = [:]
        func family(_ name: String, _ variants: [String]) {
            for variant in variants + [name] {
                table[normalised(variant)] = name
            }
        }

        family("Rap & Hip-Hop", ["rap", "hip hop", "rap hip hop", "hiphop", "trap"])
        family("R&B", ["r and b", "rnb", "soul", "rhythm and blues", "r&b soul"])
        family("Classical", [
            "classique", "klassiek", "klassik", "klassisk", "clasica", "clássica",
            "orchestral", "opera", "chamber music", "baroque",
        ])
        family("Jazz", ["swing", "big band", "bebop", "jazz vocal", "vocal jazz"])
        family("Electronic", [
            "electronica", "electro", "edm", "dance", "house", "deep house",
            "tech house", "tropical house", "tropical pool house", "soul house",
            "progressive house", "techno", "trance", "drum and bass", "dubstep",
            "indie dance nu disco", "nu disco", "elektronisk",
        ])
        family("Stage & Screen", [
            "soundtrack", "soundtracks", "film soundtracks", "films games",
            "films jeux video", "films jeux vidéo", "musical", "musicals",
            "score", "original score", "ost", "game", "games", "video game",
            "video games", "filmmusikk",
        ])
        family("Children's", [
            "kids", "childrens", "children", "jeunesse", "barnesanger",
            "barnemusikk", "kindermusik", "nursery",
        ])
        family("New Age", ["meditative", "meditation", "relaxation", "ambient new age"])
        family("Country", ["country folk", "americana", "folk americana", "bluegrass"])
        family("Reggae", ["ska", "dancehall", "dub", "roots reggae"])
        family("Blues", ["rhythm blues", "delta blues", "electric blues"])
        family("Brazilian", [
            "brazilian music", "musique bresilienne", "musique brésilienne",
            "braziliaanse muziek", "musica brasileira", "bossa nova", "samba",
            "mpb",
        ])
        family("African", ["africa", "musique africaine", "afrobeat", "afro pop", "afropop"])
        family("Latin", ["latino", "musica latina", "salsa", "tango"])
        family("Rock", [
            "alternative", "alternative rock", "alternative indie", "alternativo",
            "art rock", "post rock", "indie rock", "hard rock", "metal",
            "heavy metal", "punk", "punk rock", "psychedelic rock",
        ])
        family("Folk", ["folk music", "singer songwriter", "vise", "viser", "folkemusikk"])
        family("Holiday", ["christmas", "xmas", "jul", "weihnachten"])
        family("Spoken Word", ["comedy spoken", "spoken", "audiobook", "comedy"])
        return table
    }()
}
