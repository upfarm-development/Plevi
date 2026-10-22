import Foundation
import Testing
@testable import PleviAudio

/// playback-10, playback-39, P-20 and settings-filters-16: what Clear cache,
/// "Keep transcoded files" and eviction may delete, decided on names and keyed
/// on track ids (prefixes), not on URLs.
@Suite("Cache maintenance rules")
struct CacheMaintenanceTests {
    private let playing = "aaaaaaaaaaaaaaaa-"
    private let armed = "bbbbbbbbbbbbbbbb-"
    private let other = "cccccccccccccccc-"
    private let old = "dddddddddddddddd-"
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: playback-10 — Clear cache

    @Test("Clear cache leaves a scratch file an in-flight transfer is writing")
    func clearKeepsInFlightScratch() {
        let names = [
            "\(other)c-mp3-128.audio",
            "\(other)orig.flac",
            "\(old)orig.flac.partial",
        ]
        let doomed = CacheMaintenance.clearable(
            names,
            inFlightKeys: ["\(old)orig.flac"],
            protectedPrefixes: []
        )
        #expect(doomed == ["\(other)c-mp3-128.audio", "\(other)orig.flac"])
    }

    @Test("Clear cache leaves the playing and the armed track, finished or still arriving")
    func clearKeepsWhatIsInUse() {
        let names = [
            "\(playing)c-opus-128.ogg", "\(playing)c-opus-128.ogg.partial",
            "\(armed)orig.flac",
            "\(other)orig.flac",
        ]
        let doomed = CacheMaintenance.clearable(
            names, inFlightKeys: [], protectedPrefixes: [playing, armed]
        )
        #expect(doomed == ["\(other)orig.flac"])
    }

    @Test("A scratch file nothing is writing or playing is leftover, and Clear cache removes it")
    func clearRemovesOrphanScratch() {
        let doomed = CacheMaintenance.clearable(
            ["\(old)orig.flac.partial"], inFlightKeys: [], protectedPrefixes: [playing]
        )
        #expect(doomed == ["\(old)orig.flac.partial"])
    }

    // MARK: settings-filters-16 — keyed on ids

    @Test("Turning 'Keep transcoded files' off drops every conversion except the playing and armed ones")
    func conversionSweepSkipsProtectedIDs() {
        let names = [
            "\(playing)c-mp3-128.audio",
            "\(armed)c-aac-96.m4a",
            "\(other)c-opus-128.ogg",
            "\(other)orig.flac",
            "\(old)c-mp3-128.audio.partial",
        ]
        let sweep = CacheMaintenance.conversionSweep(names, protectedPrefixes: [playing, armed])
        #expect(sweep.drop == ["\(other)c-opus-128.ogg"])
        #expect(sweep.deferred == [playing, armed])
    }

    @Test("A protected track is dropped by id even though the engine moved from its scratch file to its finished file")
    func sweepIsIndependentOfTheURL() {
        // The engine held `…c-mp3-128.audio.partial`, then `…c-mp3-128.audio`.
        // Either way the prefix is the same, which is what the sweep keys on.
        for name in ["\(playing)c-mp3-128.audio.partial", "\(playing)c-mp3-128.audio"] {
            let sweep = CacheMaintenance.conversionSweep([name], protectedPrefixes: [playing])
            #expect(sweep.drop.isEmpty)
        }
    }

    @Test("A spared conversion goes once its track is no longer in use")
    func deferredDropsComeDue() {
        let deferred: Set<String> = [playing, armed]
        #expect(CacheMaintenance.dueAfterProtection(deferred: deferred, nowProtected: [playing, armed]).isEmpty)
        #expect(CacheMaintenance.dueAfterProtection(deferred: deferred, nowProtected: [armed, other]) == [playing])
        #expect(CacheMaintenance.dueAfterProtection(deferred: deferred, nowProtected: []) == deferred)
    }

    // MARK: P-20 — recency

    private func entry(_ prefix: String, _ tag: String, size: Int64 = 100, age: TimeInterval, played: TimeInterval? = nil) -> CacheMaintenance.Entry {
        .init(
            name: "\(prefix)\(tag)",
            size: size,
            modified: now.addingTimeInterval(-age),
            lastPlayed: played.map { now.addingTimeInterval(-$0) }
        )
    }

    @Test("Eviction takes the file played longest ago, and a play counts")
    func evictionIsLeastRecentlyUsed() {
        // A arrived first but was played a minute ago; B arrived later and
        // never has been played. Download order would evict A.
        let a = entry("a-", "orig.flac", age: 5_000, played: 60)
        let b = entry("b-", "orig.flac", age: 1_000)
        let c = entry("c-", "orig.flac", age: 3_000)
        let plan = CacheMaintenance.eviction(
            [a, b, c], limit: 200, inFlightKeys: [], protectedPrefixes: [], now: now
        )
        #expect(plan.evict == ["c-orig.flac"])
    }

    @Test("Eviction never takes a protected track, and moves on to the next oldest")
    func evictionSkipsProtected() {
        let oldest = entry(playing, "orig.flac", age: 9_000)
        let next = entry(old, "orig.flac", age: 8_000)
        let fresh = entry(other, "orig.flac", age: 10)
        let plan = CacheMaintenance.eviction(
            [oldest, next, fresh], limit: 200, inFlightKeys: [], protectedPrefixes: [playing], now: now
        )
        #expect(plan.evict == ["\(old)orig.flac"])
    }

    @Test("Nothing is evicted under the limit")
    func underTheLimit() {
        let plan = CacheMaintenance.eviction(
            [entry(old, "orig.flac", age: 9_000)], limit: 1_000, inFlightKeys: [], protectedPrefixes: [], now: now
        )
        #expect(plan.evict.isEmpty)
    }

    // MARK: playback-39 — leaked scratch files

    @Test("A scratch file older than the timeout that nothing owns is swept, whatever the limit")
    func staleScratchIsSwept() {
        let leaked = entry(old, "orig.flac.partial", age: 3_600)
        let plan = CacheMaintenance.eviction(
            [leaked], limit: 10_000, inFlightKeys: [], protectedPrefixes: [], now: now
        )
        #expect(plan.staleScratch == ["\(old)orig.flac.partial"])
    }

    @Test("A scratch file being written, recently written, or belonging to the playing track is not swept")
    func liveScratchIsKept() {
        let writing = entry(old, "orig.flac.partial", age: 3_600)
        let recent = entry(other, "orig.flac.partial", age: 30)
        let inUse = entry(playing, "c-mp3-128.audio.partial", age: 3_600)
        let plan = CacheMaintenance.eviction(
            [writing, recent, inUse],
            limit: 10_000,
            inFlightKeys: ["\(old)orig.flac"],
            protectedPrefixes: [playing],
            now: now
        )
        #expect(plan.staleScratch.isEmpty)
    }

    @Test("Scratch files do not count towards the limit and are never evicted for it")
    func scratchIsNotEvictedForSize() {
        let big = entry(old, "orig.flac.partial", size: 10_000, age: 10)
        let small = entry(other, "orig.flac", size: 100, age: 10)
        let plan = CacheMaintenance.eviction(
            [big, small], limit: 150, inFlightKeys: [], protectedPrefixes: [], now: now
        )
        #expect(plan.evict.isEmpty)
    }
}
