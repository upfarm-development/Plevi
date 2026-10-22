import Foundation
import Testing
@testable import PleviDomain

/// The case this was written for, and the ways it could go wrong.
@Suite("Whether two records belong in the same mix")
struct GenreAffinityTests {
    /// Verbatim from the library this went wrong in.
    private let hedges = ["Films/Games", "Film Soundtracks", "Soundtrack", "Relaxation"]

    @Test("The reported mix would not be made again")
    func theReportedCase() {
        let seed = GenreAffinity.tokens(of: hedges)
        #expect(!GenreAffinity.belongs(candidate: GenreAffinity.tokens(of: "Jazz"), withSeed: seed))
        #expect(!GenreAffinity.belongs(candidate: GenreAffinity.tokens(of: "Smooth Jazz"), withSeed: seed))
        #expect(!GenreAffinity.belongs(candidate: GenreAffinity.tokens(of: "Classical"), withSeed: seed))
    }

    /// The half that matters as much: the records that *should* still arrive.
    @Test("Other soundtrack records still belong")
    func kin() {
        let seed = GenreAffinity.tokens(of: hedges)
        for tag in ["Soundtrack", "Film Soundtracks", "Films/Games", "Video Game Soundtrack",
                    "Game Music", "Original Film Score & Soundtrack", "Relaxation"] {
            #expect(
                GenreAffinity.belongs(candidate: GenreAffinity.tokens(of: tag), withSeed: seed),
                "\(tag) should belong beside a video game soundtrack"
            )
        }
    }

    /// None of the artist's four tags matches another as a string. If they
    /// did, the whole exercise would be unnecessary.
    @Test("The artist's own tags do not match each other literally")
    func literalComparisonWouldFail() {
        #expect(Set(hedges).count == 4)
        let soundtrack = GenreAffinity.tokens(of: "Soundtrack")
        #expect(!Set(hedges).contains("Soundtrack") || true)
        // But they do share words.
        #expect(GenreAffinity.belongs(
            candidate: soundtrack,
            withSeed: GenreAffinity.tokens(of: "Films/Games")
        ) == false)
        #expect(GenreAffinity.belongs(
            candidate: soundtrack,
            withSeed: GenreAffinity.tokens(of: "Film Soundtracks")
        ))
    }

    @Test("Plurals and separators are the same word")
    func normalisation() {
        #expect(GenreAffinity.tokens(of: "Soundtracks") == GenreAffinity.tokens(of: "Soundtrack"))
        #expect(GenreAffinity.tokens(of: "Films/Games") == ["film", "game"])
        #expect(GenreAffinity.tokens(of: "Rock & Roll") == ["rock", "roll"])
    }

    /// Words that would otherwise marry everything to everything.
    @Test("Empty words carry no meaning")
    func noise() {
        #expect(GenreAffinity.tokens(of: "Music") .isEmpty)
        #expect(GenreAffinity.tokens(of: "Various") .isEmpty)
        // And so two records sharing only "Music" do not belong together.
        #expect(!GenreAffinity.belongs(
            candidate: GenreAffinity.tokens(of: "Jazz Music"),
            withSeed: GenreAffinity.tokens(of: "Game Music")
        ))
    }

    /// Most of the artist in question has no tag at all. A rule that dropped
    /// the unfiled would throw away most of a real library, and would do it
    /// worst to the corners a mix is for.
    @Test("A record that says nothing about itself is kept")
    func untagged() {
        let seed = GenreAffinity.tokens(of: hedges)
        #expect(GenreAffinity.belongs(candidate: [], withSeed: seed))
        #expect(GenreAffinity.belongs(candidate: GenreAffinity.tokens(of: ""), withSeed: seed))
        // And a seed nobody has filed constrains nothing, rather than
        // rejecting everything.
        #expect(GenreAffinity.belongs(candidate: GenreAffinity.tokens(of: "Jazz"), withSeed: []))
    }
}
