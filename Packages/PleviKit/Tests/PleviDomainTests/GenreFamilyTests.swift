import Foundation
import Testing
@testable import PleviDomain

@Suite struct GenreFamilyTests {
    /// Every genre a real library of sixty thousand songs had in it, with the number of songs under
    /// each.
    private static let realLibrary: [(String, Int)] = [
        ("Pop/Rock", 19445), ("Jazz", 11290), ("R&B", 3431), ("Vocal", 2443),
        ("Rap", 2133), ("Pop", 1983), ("Classical", 1562), ("Electronic", 1221),
        ("Stage & Screen", 1049), ("Soundtrack", 864), ("Rock", 757),
        ("Reggae", 751), ("Latin", 730), ("Country", 707), ("Folk", 535),
        ("International", 384), ("New Age", 343), ("Alternative", 323),
        ("Rap/Hip Hop", 298), ("Blues", 212), ("Tropical House", 207),
        ("Easy Listening", 179), ("Children's", 178), ("Classique", 129),
        ("Films/Games", 126), ("Dance", 110), ("Electro", 103), ("Kids", 102),
        ("Religious", 73), ("Singer & Songwriter", 70), ("Klassiek", 54),
        ("Hawaiian", 49), ("Jeunesse", 38), ("Bossa Nova", 33), ("Africa", 29),
        ("Brazilian Music", 26), ("Vise", 23), ("Films/Jeux vidéo", 21),
        ("House", 20), ("Play-along", 16), ("Rap & Hip-Hop", 15),
        ("Post-rock", 15), ("Instrumental", 14), ("Game", 14),
        ("Musique brésilienne", 13), ("Musique africaine", 13),
        ("Barnesanger", 13), ("Swing", 12), ("Braziliaanse Muziek", 12),
        ("Art Rock", 12), ("Holiday", 10), ("Film Soundtracks", 10),
        ("Top 40", 9), ("Relaxation", 9), ("Pop Rock", 9), ("Meditative", 9),
        ("Comedy/Spoken", 9), ("Orchestral", 8), ("Folk/Americana", 8),
        ("Soul", 6), ("New age", 5), ("Alternativo", 5), ("Pop/Rock/Disco", 3),
        ("Pop/General", 3), ("Metal", 2), ("Deep house", 2), ("Big band", 2),
        ("Alternative & Indie", 2), ("Tropical Pool House", 1), ("Soul House", 1),
        ("Russ", 1), ("Oldies", 1), ("Indie Dance / Nu Disco", 1),
        ("Hip-Hop", 1), ("Avant-Garde", 1), ("Alternative Rock", 1),
    ]

    /// Case, punctuation and spacing are not differences.
    @Test func spellingVariantsLandTogether() {
        #expect(GenreFamily.canonical("New age") == GenreFamily.canonical("New Age"))
        #expect(GenreFamily.canonical("Rap/Hip Hop") == GenreFamily.canonical("Rap & Hip-Hop"))
        #expect(GenreFamily.canonical("Hip-Hop") == GenreFamily.canonical("Rap"))
    }

    /// The same genre in another language is the same genre. This library is
    /// Norwegian, French and Dutch in places, and its Classical music was in
    /// three piles because of it.
    @Test func otherLanguagesLandTogether() {
        let classical = GenreFamily.canonical("Classical")
        #expect(GenreFamily.canonical("Classique") == classical)
        #expect(GenreFamily.canonical("Klassiek") == classical)

        let children = GenreFamily.canonical("Children's")
        #expect(GenreFamily.canonical("Jeunesse") == children)
        #expect(GenreFamily.canonical("Barnesanger") == children)
        #expect(GenreFamily.canonical("Kids") == children)
    }

    @Test func subgenresFoldIntoTheirParent() {
        #expect(GenreFamily.canonical("Swing") == "Jazz")
        #expect(GenreFamily.canonical("Big band") == "Jazz")
        #expect(GenreFamily.canonical("Tropical House") == "Electronic")
        #expect(GenreFamily.canonical("Deep house") == "Electronic")
        #expect(GenreFamily.canonical("Bossa Nova") == GenreFamily.canonical("Brazilian Music"))
    }

    /// Nothing unrecognised is merged into anything. A genre this does not
    /// know keeps its own name and its own music, because putting songs in a
    /// mix they do not belong in is worse than a mix being small.
    @Test func unknownGenresKeepTheirOwnName() {
        #expect(GenreFamily.canonical("Vise") == "Folk")        // known
        #expect(GenreFamily.canonical("Hawaiian") == "Hawaiian") // not known: left alone
        #expect(GenreFamily.canonical("Russ") == "Russ")
        #expect(GenreFamily.canonical("Zeuhl") == "Zeuhl")
    }

    /// Two genres that are genuinely different must not be gathered. Rock and
    /// Pop/Rock are separate piles on this library and have to stay so —
    /// folding them would make an already-too-broad genre broader.
    @Test func distinctGenresStayApart() {
        #expect(GenreFamily.canonical("Rock") != GenreFamily.canonical("Pop/Rock"))
        #expect(GenreFamily.canonical("Jazz") != GenreFamily.canonical("Blues"))
        #expect(GenreFamily.canonical("Classical") != GenreFamily.canonical("New Age"))
        #expect(GenreFamily.canonical("Latin") != GenreFamily.canonical("Brazilian Music"))
    }

    /// What the grouping is worth on the real thing: the seventy-six names come down, and the
    /// families that gain the most are the ones that were most obviously split.
    @Test func sameWordsDifferentPunctuationGatherUp() {
        let families = GenreFamily.families(of: ["Pop/Rock": 19445, "Pop Rock": 9])
        #expect(families.count == 1)
        #expect(families.first?.name == "Pop/Rock")
        #expect(families.first?.songs == 19454)
    }

    @Test func theRealLibraryGathersUp() {
        let counted = Dictionary(uniqueKeysWithValues: Self.realLibrary)
        let families = GenreFamily.families(of: counted)
        var counts: [String: Int] = [:]
        for family in families { counts[family.name] = family.songs }

        #expect(families.count < Self.realLibrary.count)

        // Rap was in four piles; it should be one, and bigger than any of them.
        let rap = GenreFamily.canonical("Rap")
        #expect(counts[rap] == 2133 + 298 + 15 + 1)

        // Classical was in four.
        #expect(counts["Classical"] == 1562 + 129 + 54 + 8)

        // Screen music was in six.
        let screen = GenreFamily.canonical("Soundtrack")
        #expect(counts[screen] == 1049 + 864 + 126 + 21 + 14 + 10)

        // Children's songs were in four, in three languages.
        #expect(counts[GenreFamily.canonical("Kids")] == 178 + 102 + 38 + 13)

        // And nothing was lost on the way.
        #expect(counts.values.reduce(0, +) == Self.realLibrary.map(\.1).reduce(0, +))
    }
}
