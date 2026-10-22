import Foundation
import Testing
@testable import PleviDomain

@Suite("Deactivation cleanup and manual-edit precedence")
struct DJQueueBookkeepingTests {
    @Test("Not-yet-played DJ-authored entries are removed on deactivation")
    func removesUnplayedAuthored() {
        let authored: Set<Int> = [1, 2, 3]
        let played: Set<Int> = []
        #expect(DJQueueBookkeeping.idsToRemoveOnDeactivation(authoredIDs: authored, playedIDs: played) == [1, 2, 3])
    }

    @Test("A DJ-authored entry that has already played is left alone — history is never touched")
    func leavesPlayedAuthoredAlone() {
        let authored: Set<Int> = [1, 2, 3]
        let played: Set<Int> = [1]
        #expect(DJQueueBookkeeping.idsToRemoveOnDeactivation(authoredIDs: authored, playedIDs: played) == [2, 3])
    }

    @Test("The user's own entries are never candidates for removal — they were never authored")
    func neverRemovesUserEntries() {
        // A user entry simply never appears in `authoredIDs` at all, so
        // there is nothing here that could remove it; this test documents
        // that guarantee rather than exercising a special case.
        let authored: Set<Int> = [2]
        let played: Set<Int> = []
        let removed = DJQueueBookkeeping.idsToRemoveOnDeactivation(authoredIDs: authored, playedIDs: played)
        #expect(!removed.contains(1), "id 1 was never in authoredIDs, so it can never be removed")
    }

    @Test("Every DJ category reduces to the same rule")
    func sameRuleForEveryCategory() {
        // Weaving (Moody/Fresh), appending (Era/Purist/DeepCuts/Gold) and replacing (Drift/Journey)
        // all describe their authored entries the same way once the DJ is active — a
        // queue-replacing DJ simply has authored EVERY entry after the point it…
        let weaveAuthored: Set<Int> = [10, 11]
        let appendAuthored: Set<Int> = [20, 21, 22]
        let replaceAuthored: Set<Int> = [30, 31, 32, 33]
        for authored in [weaveAuthored, appendAuthored, replaceAuthored] {
            #expect(DJQueueBookkeeping.idsToRemoveOnDeactivation(authoredIDs: authored, playedIDs: []) == authored)
        }
    }

    @Test("Removing a DJ-added track excludes that exact track for the rest of the session")
    func manualRemovalExcludesTrack() {
        var excluded: Set<String> = []
        excluded = DJQueueBookkeeping.manuallyExcluded(removedAuthoredTrackIDs: ["trackA"], into: excluded)
        #expect(excluded.contains("trackA"))
    }

    @Test("Manual exclusions accumulate rather than replacing what was already excluded")
    func manualExclusionsAccumulate() {
        var excluded: Set<String> = ["trackA"]
        excluded = DJQueueBookkeeping.manuallyExcluded(removedAuthoredTrackIDs: ["trackB"], into: excluded)
        #expect(excluded == ["trackA", "trackB"])
    }
}
