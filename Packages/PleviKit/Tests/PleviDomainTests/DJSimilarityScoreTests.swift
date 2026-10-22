import Foundation
import Testing
@testable import PleviDomain

@Suite("The genre-and-era fallback used when there is no sonic similarity")
struct DJSimilarityScoreTests {
    @Test("Same genre family, same year scores highest")
    func perfectMatch() {
        let score = DJSimilarityScore.score(
            candidateGenre: "Rock", candidateYear: 1975,
            anchorGenre: "Rock", anchorYear: 1975
        )
        #expect(score == 1)
    }

    @Test("A genre variant in the same family still counts as a match")
    func genreFamilyVariant() {
        // "Swing" and "Big band" are both filed under Jazz — see GenreFamily.
        let score = DJSimilarityScore.score(
            candidateGenre: "Swing", candidateYear: nil,
            anchorGenre: "Big band", anchorYear: nil
        )
        #expect(score == 0.75, "genre matches (1) and missing years score neutral (0.5): (1 + 0.5) / 2")
    }

    @Test("A different genre and a distant year scores lowest")
    func worstMatch() {
        let score = DJSimilarityScore.score(
            candidateGenre: "Jazz", candidateYear: 1960,
            anchorGenre: "Electronic", anchorYear: 2020
        )
        #expect(score == 0)
    }

    @Test("Missing genre or year on either side scores that half as neutral, not as a mismatch")
    func missingDataIsNeutral() {
        let score = DJSimilarityScore.score(
            candidateGenre: nil, candidateYear: 1975,
            anchorGenre: "Rock", anchorYear: 1975
        )
        #expect(score == 0.75, "genre unknown (0.5) plus a perfect year match (1): (0.5 + 1) / 2")
    }

    @Test("Era distance fades smoothly rather than cutting off at the tolerance line")
    func eraDistanceFades() {
        let near = DJSimilarityScore.score(
            candidateGenre: nil, candidateYear: 1970, anchorGenre: nil, anchorYear: 1975
        )
        let far = DJSimilarityScore.score(
            candidateGenre: nil, candidateYear: 1930, anchorGenre: nil, anchorYear: 1975
        )
        #expect(near > far)
        #expect(far == 0.25, "beyond the tolerance window, the era half scores 0, genre unknown scores 0.5: (0 + 0.5) / 2")
    }

    @Test("rank(_:against:) sorts highest score first and keeps the anchor's own values out of the comparison")
    func rankOrdersDescending() {
        struct Item { let name: String; let genre: String?; let year: Int? }
        let anchor = Item(name: "anchor", genre: "Rock", year: 1975)
        let close = Item(name: "close", genre: "Rock", year: 1976)
        let far = Item(name: "far", genre: "Jazz", year: 1930)
        let ranked = DJSimilarityScore.rank(
            [far, close], against: anchor, genre: { $0.genre }, year: { $0.year }
        )
        #expect(ranked.map(\.name) == ["close", "far"])
    }
}
