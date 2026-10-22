import Foundation
import Testing
@testable import PleviDomain

@Suite("How often a server is told what is playing")
struct PlaybackReportScheduleTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func report(
        _ raw: String,
        _ state: PlaybackReport.State,
        at position: TimeInterval = 0
    ) -> PlaybackReport {
        PlaybackReport(id: id(raw), state: state, position: position, duration: 200)
    }

    @Test("The first thing that happens is always worth saying")
    func firstReportGoes() {
        var schedule = PlaybackReportSchedule()
        let first = schedule.shouldSend(report("a", .playing), now: start)
        #expect(first)
    }

    /// A progress callback fires many times a second. A dashboard is not
    /// worth that many requests, and a wrist's battery certainly is not.
    @Test("A song simply playing is not reported on every tick")
    func playingIsThrottled() {
        var schedule = PlaybackReportSchedule()
        let first = schedule.shouldSend(report("a", .playing, at: 0), now: start)
        let soon = schedule.shouldSend(report("a", .playing, at: 0.5), now: start.addingTimeInterval(0.5))
        let stillSoon = schedule.shouldSend(report("a", .playing, at: 3), now: start.addingTimeInterval(3))
        let due = schedule.shouldSend(report("a", .playing, at: 9), now: start.addingTimeInterval(9))
        #expect(first)
        #expect(!soon)
        #expect(!stillSoon)
        #expect(due)
    }

    @Test("Pausing is said at once, however recently anything else was")
    func stateChangeBeatsTheInterval() {
        var schedule = PlaybackReportSchedule()
        _ = schedule.shouldSend(report("a", .playing), now: start)
        let paused = schedule.shouldSend(report("a", .paused), now: start.addingTimeInterval(0.2))
        #expect(paused)
    }

    @Test("A different song is said at once")
    func newSongBeatsTheInterval() {
        var schedule = PlaybackReportSchedule()
        _ = schedule.shouldSend(report("a", .playing), now: start)
        let next = schedule.shouldSend(report("b", .playing), now: start.addingTimeInterval(0.2))
        #expect(next)
    }

    /// Otherwise a stopped song goes on being reported stopped for as long as
    /// anything keeps asking, which is a request every eight seconds saying
    /// nothing at all.
    @Test("A stopped song is reported once and then left alone")
    func stoppedIsSaidOnce() {
        var schedule = PlaybackReportSchedule()
        _ = schedule.shouldSend(report("a", .playing), now: start)
        let stopped = schedule.shouldSend(report("a", .stopped, at: 60), now: start.addingTimeInterval(1))
        let again = schedule.shouldSend(report("a", .stopped, at: 60), now: start.addingTimeInterval(30))
        #expect(stopped)
        #expect(!again)
    }

    @Test("Resetting makes the next report new again")
    func resetForgets() {
        var schedule = PlaybackReportSchedule()
        _ = schedule.shouldSend(report("a", .playing), now: start)
        let throttled = schedule.shouldSend(report("a", .playing), now: start.addingTimeInterval(1))
        schedule.reset()
        let afterReset = schedule.shouldSend(report("a", .playing), now: start.addingTimeInterval(1))
        #expect(!throttled)
        #expect(afterReset)
    }
}
