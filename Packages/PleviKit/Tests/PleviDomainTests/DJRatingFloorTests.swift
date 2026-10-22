import Foundation
import Testing
@testable import PleviDomain

/// `StarRating` is already on the app's own half-star 0.5–5.0 scale by the time either backend's
/// mapping layer has finished with it — Plex's 0–10 halved, Navidrome's whole 1–5 taken as-is — so
/// there is nothing backend-specific to test here…
@Suite("The rating floor a DJ applies to an in-memory track list")
struct DJRatingFloorTests {
    @Test("Unrated always passes, whatever the threshold")
    func unratedPasses() {
        #expect(DJRatingFloor.passes(nil, atLeast: 2.5))
        #expect(DJRatingFloor.passes(nil, atLeast: 4.0))
    }

    @Test("Exactly at the threshold passes")
    func exactlyAtThresholdPasses() {
        #expect(DJRatingFloor.passes(StarRating(2.5), atLeast: 2.5))
        #expect(DJRatingFloor.passes(StarRating(4.0), atLeast: 4.0))
    }

    @Test("Below the threshold fails")
    func belowThresholdFails() {
        #expect(!DJRatingFloor.passes(StarRating(2), atLeast: 2.5))
        #expect(!DJRatingFloor.passes(StarRating(3.5), atLeast: 4.0))
    }

    @Test("Above the threshold passes")
    func aboveThresholdPasses() {
        #expect(DJRatingFloor.passes(StarRating(5), atLeast: 2.5))
        #expect(DJRatingFloor.passes(StarRating(4.5), atLeast: 4.0))
    }

    @Test("Gold's stricter floor rejects what the general floor would allow")
    func goldIsStricterThanGeneral() {
        let threeStars = StarRating(3)
        #expect(DJRatingFloor.passes(threeStars, atLeast: 2.5), "clears the general floor")
        #expect(!DJRatingFloor.passes(threeStars, atLeast: 4.0), "but not Gold's own, higher one")
    }

    @Test("requiresRating rejects unrated, unlike passes — Gold's line, not the general floor's")
    func requiresRatingExcludesUnrated() {
        #expect(DJRatingFloor.passes(nil, atLeast: 2.5), "the general floor lets silence through")
        #expect(!DJRatingFloor.requiresRating(nil, atLeast: 2.5), "Gold's own line does not")
    }

    @Test("requiresRating still honours an explicit rating the normal way")
    func requiresRatingStillComparesRealRatings() {
        #expect(DJRatingFloor.requiresRating(StarRating(4.5), atLeast: 4.0))
        #expect(!DJRatingFloor.requiresRating(StarRating(3.5), atLeast: 4.0))
    }
}
