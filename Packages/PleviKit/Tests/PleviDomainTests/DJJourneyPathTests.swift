import Foundation
import Testing
@testable import PleviDomain

@Suite("Journey's per-step blend from anchor to destination")
struct DJJourneyPathTests {
    @Test("Step 0 of N is entirely the anchor")
    func firstStepIsAllAnchor() {
        #expect(DJJourneyPath.destinationWeight(step: 0, of: 10) == 0)
        #expect(DJJourneyPath.anchorWeight(step: 0, of: 10) == 1)
    }

    @Test("The final step is entirely the destination")
    func lastStepIsAllDestination() {
        #expect(DJJourneyPath.destinationWeight(step: 10, of: 10) == 1)
        #expect(DJJourneyPath.anchorWeight(step: 10, of: 10) == 0)
    }

    @Test("The midpoint splits evenly")
    func midpointIsHalf() {
        #expect(DJJourneyPath.destinationWeight(step: 5, of: 10) == 0.5)
    }

    @Test("Destination weight increases monotonically across the whole journey")
    func destinationWeightIsMonotonic() {
        let weights = (0...10).map { DJJourneyPath.destinationWeight(step: $0, of: 10) }
        #expect(weights == weights.sorted(), "each step must weigh the destination at least as much as the one before it")
        #expect(Set(weights).count == weights.count, "and strictly more at every step, not just non-decreasing")
    }

    @Test(
        "A candidate that is a perfect destination match and no anchor match scores higher at every later step",
        arguments: [(0, 5), (5, 9), (2, 8)]
    )
    func blendedScoreFavoursDestinationAsStepsAdvance(_ pair: (Int, Int)) {
        let (earlier, later) = pair
        let n = 10
        let earlierScore = DJJourneyPath.blendedScore(anchorMatch: 0, destinationMatch: 1, step: earlier, of: n)
        let laterScore = DJJourneyPath.blendedScore(anchorMatch: 0, destinationMatch: 1, step: later, of: n)
        #expect(laterScore > earlierScore)
    }

    @Test("A candidate that matches neither anchor nor destination scores zero at every step")
    func nothingMatchesScoresZero() {
        for step in 0...10 {
            #expect(DJJourneyPath.blendedScore(anchorMatch: 0, destinationMatch: 0, step: step, of: 10) == 0)
        }
    }

    @Test("A journey of zero steps is already at the destination")
    func zeroLengthJourney() {
        #expect(DJJourneyPath.destinationWeight(step: 0, of: 0) == 1)
    }

    @Test("Out-of-range steps clamp rather than producing a weight outside 0...1")
    func stepsClampToRange() {
        #expect(DJJourneyPath.destinationWeight(step: -3, of: 10) == 0)
        #expect(DJJourneyPath.destinationWeight(step: 999, of: 10) == 1)
    }

    @Test("A genre destination matches by family, the same rule DJSimilarityScore uses")
    func genreDestinationMatch() {
        let match = DJJourneyPath.localDestinationMatch(
            .genre("Big band"), candidateGenre: "Swing", candidateYear: nil
        )
        #expect(match == 1)
    }

    @Test("A decade destination matches exactly, and fades rather than cutting off at the boundary")
    func decadeDestinationMatch() {
        let exact = DJJourneyPath.localDestinationMatch(.decade(1970), candidateGenre: nil, candidateYear: 1975)
        let near = DJJourneyPath.localDestinationMatch(.decade(1970), candidateGenre: nil, candidateYear: 1981)
        let far = DJJourneyPath.localDestinationMatch(.decade(1970), candidateGenre: nil, candidateYear: 1930)
        #expect(exact == 1)
        #expect(near! > 0 && near! < 1)
        #expect(far == 0)
    }

    @Test("A track destination has no local match — the caller scores it via live similarity")
    func trackDestinationHasNoLocalMatch() {
        let match = DJJourneyPath.localDestinationMatch(
            .track(MediaID(server: ServerID(), rawValue: "t1"), title: "Song", artist: "Artist"),
            candidateGenre: "Rock", candidateYear: 1975
        )
        #expect(match == nil)
    }
}
