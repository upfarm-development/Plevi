import Foundation
import Testing
@testable import PleviAudio

@Suite("The watch's whole-song fetches (watch-06, playback-33, playback-41)")
struct WatchFetchRulesTests {
    // MARK: File names (playback-41)

    @Test("A song does not claim the file of a song whose name merely begins the same")
    func prefixIsNotOwnership() {
        #expect(FetchedFileName.isFinishedFile("abcd.mp3", forSafeName: "abcd"))
        #expect(!FetchedFileName.isFinishedFile("abcd.mp3", forSafeName: "abc"))
        #expect(!FetchedFileName.isFinishedFile("abc", forSafeName: "abc"))
        #expect(FetchedFileName.isFinishedFile("abc.m4a", forSafeName: "abc"))
    }

    @Test("A partial file is not finished")
    func partialIsNotFinished() {
        #expect(!FetchedFileName.isFinishedFile("abc.mp3.partial", forSafeName: "abc"))
    }

    @Test("Eviction keeps a partial of a kept song, and only that song's")
    func evictionKeepsByExactSong() {
        let keep: Set<String> = ["abc", "x1"]
        #expect(FetchedFileName.belongs("abc.mp3", toAnyOf: keep))
        #expect(FetchedFileName.belongs("abc.mp3.partial", toAnyOf: keep))
        // The bug: "abcd" starts with "abc" and used to be kept.
        #expect(!FetchedFileName.belongs("abcd.mp3", toAnyOf: keep))
        #expect(!FetchedFileName.belongs("ab.mp3", toAnyOf: keep))
    }

    // MARK: Reaping (watch-06)

    @Test("Skipping through eight songs leaves only the current one and the lookahead running")
    func skippingLeavesOnlyTheWindow() {
        let running = (1...8).map { "song\($0)" }
        // Landed on song 8; songs 9-11 are the warm window.
        let stale = FetchReaping.stale(
            running: running, current: "song8", ahead: ["song9", "song10", "song11"]
        )
        #expect(Set(stale) == Set((1...7).map { "song\($0)" }))
    }

    @Test("A fetch that is about to become the current song is kept")
    func warmedNextIsKept() {
        let stale = FetchReaping.stale(
            running: ["next", "old"], current: "next", ahead: ["after"]
        )
        #expect(stale == ["old"])
    }

    @Test("Nothing current means only the window is kept")
    func noCurrent() {
        let stale = FetchReaping.stale(running: ["a", "b"], current: nil, ahead: ["b"])
        #expect(stale == ["a"])
    }

    // MARK: Cool-down (playback-33)

    @Test("A song that failed to warm is left alone until the cool-down passes")
    func coolDown() {
        var cooldown = WarmCooldown(interval: 90)
        let t0 = Date(timeIntervalSince1970: 5_000)
        cooldown.recordFailure(of: "a", at: t0)
        #expect(cooldown.isCoolingDown("a", at: t0.addingTimeInterval(30)))
        #expect(!cooldown.isCoolingDown("a", at: t0.addingTimeInterval(91)))
        #expect(!cooldown.isCoolingDown("b", at: t0))
    }

    @Test("A success clears the cool-down, and pruning drops cooled entries")
    func successAndPrune() {
        var cooldown = WarmCooldown(interval: 90)
        let t0 = Date(timeIntervalSince1970: 5_000)
        cooldown.recordFailure(of: "a", at: t0)
        cooldown.recordFailure(of: "b", at: t0)
        cooldown.recordSuccess(of: "a")
        #expect(!cooldown.isCoolingDown("a", at: t0))
        cooldown.prune(at: t0.addingTimeInterval(200))
        #expect(cooldown == WarmCooldown(interval: 90))
    }
}
