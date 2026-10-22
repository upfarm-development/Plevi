import Foundation
import Testing
@testable import PleviDomain

/// The shortcut that skips Unicode folding for a plain ASCII first letter.
@Suite("Filing a title under a letter")
struct AlphabetIndexFastPathTests {
    @Test("Plain letters file under themselves", arguments: [
        ("Sultans of Swing", "S"), ("abbey road", "A"), ("Zoo Station", "Z"),
    ])
    func ascii(title: String, expected: String) {
        #expect(AlphabetIndex.section(for: title) == expected)
    }

    /// The reason the careful path exists. Å must not fold to A, Æ must not
    /// become AE, and the Swedish and Finnish spellings file with them.
    @Test("The Nordic letters keep their own places", arguments: [
        ("Ærlig talt", "Æ"), ("Ähnlich", "Æ"),
        ("Øde øy", "Ø"), ("Öppna landskap", "Ø"), ("Œuvre", "Ø"),
        ("Ånd i glasset", "Å"),
    ])
    func nordic(title: String, expected: String) {
        #expect(AlphabetIndex.section(for: title) == expected)
    }

    /// Accented Latin still folds to its plain letter — the shortcut must not
    /// swallow these, since they are not ASCII.
    @Test("Accents still fold", arguments: [
        ("Étude", "E"), ("Ça ira", "C"), ("Über", "U"), ("Ñandú", "N"),
    ])
    func accents(title: String, expected: String) {
        #expect(AlphabetIndex.section(for: title) == expected)
    }

    @Test("Anything that is not a letter goes to the end bucket", arguments: [
        "99 Luftballons", "!!!", "  ", "", "上を向いて歩こう", "#SELFIE",
    ])
    func other(title: String) {
        #expect(AlphabetIndex.section(for: title) == AlphabetIndex.other)
    }

    /// Leading whitespace was trimmed before; the shortcut skips it instead,
    /// which has to come to the same thing.
    @Test("Leading space is ignored, not filed under nothing")
    func leadingSpace() {
        #expect(AlphabetIndex.section(for: "   Waterloo") == "W")
        #expect(AlphabetIndex.section(for: "\n\tØde") == "Ø")
    }
}
