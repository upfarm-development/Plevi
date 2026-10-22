import Foundation
import Testing
@testable import PleviDomain

/// When the server is told what is playing, under the situations a stressed player actually
/// produces: twenty skips in a second, a pause button hit repeatedly, a clock that moves.
@Suite("Reporting playback under stress")
struct StressPlaybackReportScheduleTests {
    private static let server = ServerID()
    private static func id(_ n: Int) -> MediaID { MediaID(server: server, rawValue: "\(n)") }
    private static func report(_ n: Int, _ state: PlaybackReport.State = .playing, at position: TimeInterval = 0) -> PlaybackReport {
        PlaybackReport(id: id(n), state: state, position: position, duration: 200)
    }
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A song that is simply playing is reported every eight seconds, not every tick")
    func steadyPlayback() {
        var schedule = PlaybackReportSchedule()
        var sent = 0
        // Two progress ticks a second for five minutes.
        for tick in 0..<600 {
            let now = Self.t0.addingTimeInterval(Double(tick) * 0.5)
            if schedule.shouldSend(Self.report(1, at: Double(tick) * 0.5), now: now) { sent += 1 }
        }
        // 300 s / 8 s = 37.5 -> 38 reports including the first.
        #expect(sent == 38, "sent \(sent)")
    }

    @Test("Exactly the interval sends; a hair under does not")
    func boundary() {
        var schedule = PlaybackReportSchedule()
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0); #expect(sent) }
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0.addingTimeInterval(7.999)); #expect(!sent) }
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0.addingTimeInterval(8)); #expect(sent) }
    }

    @Test("Twenty skips in one second are twenty reports: a change of song is never rate-limited")
    func skipStormCostsOneRequestPerSong() {
        var schedule = PlaybackReportSchedule()
        var sent = 0
        for n in 1...20 {
            let now = Self.t0.addingTimeInterval(Double(n) * 0.05)
            if schedule.shouldSend(Self.report(n, .paused), now: now) { sent += 1 }
            if schedule.shouldSend(Self.report(n, .playing), now: now) { sent += 1 }
        }
        // Characterisation: one "paused" and one "playing" per song.
        #expect(sent == 40, "sent \(sent)")
    }

    @Test("Hitting pause and play twenty times sends every toggle")
    func pauseMash() {
        var schedule = PlaybackReportSchedule()
        var sent = 0
        for toggle in 0..<20 {
            let state: PlaybackReport.State = toggle.isMultiple(of: 2) ? .paused : .playing
            if schedule.shouldSend(Self.report(1, state), now: Self.t0.addingTimeInterval(Double(toggle) * 0.1)) { sent += 1 }
        }
        #expect(sent == 20)
    }

    @Test("A song that stopped is not reported stopped again, but is heard again when replayed")
    func stoppedThenReplayed() {
        var schedule = PlaybackReportSchedule()
        do { let sent = schedule.shouldSend(Self.report(1, .stopped), now: Self.t0); #expect(sent) }
        do { let sent = schedule.shouldSend(Self.report(1, .stopped), now: Self.t0.addingTimeInterval(60)); #expect(!sent) }
        do { let sent = schedule.shouldSend(Self.report(1, .playing), now: Self.t0.addingTimeInterval(61)); #expect(sent) }
    }

    @Test("reset() makes the next report go whatever it is")
    func resetForgets() {
        var schedule = PlaybackReportSchedule()
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0); #expect(sent) }
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0.addingTimeInterval(1)); #expect(!sent) }
        schedule.reset()
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0.addingTimeInterval(2)); #expect(sent) }
    }

    @Test("A wall clock that steps backwards must not silence the dashboard for the size of the step")
    func clockStepsBack() {
        // P-25: the player passes `Date()` — the wall clock — and the rule compares
        // `now.timeIntervalSince(lastSent) >= 8`.
        var schedule = PlaybackReportSchedule()
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0); #expect(sent) }
        let tenRealSecondsLaterButTheClockWentBackAnHour = Self.t0.addingTimeInterval(10 - 3600)
        do { let sent = schedule.shouldSend(Self.report(1), now: tenRealSecondsLaterButTheClockWentBackAnHour); #expect(sent) }
    }

    @Test("A wall clock that jumps forwards just sends once")
    func clockStepsForward() {
        var schedule = PlaybackReportSchedule()
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0); #expect(sent) }
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0.addingTimeInterval(86_400)); #expect(sent) }
        do { let sent = schedule.shouldSend(Self.report(1), now: Self.t0.addingTimeInterval(86_401)); #expect(!sent) }
    }

    @Test("Playback reports survive hostile positions and durations as values")
    func hostileValues() {
        var schedule = PlaybackReportSchedule()
        let hostile: [TimeInterval] = [-1, 0, .nan, .infinity, -.infinity, .greatestFiniteMagnitude]
        for (n, position) in hostile.enumerated() {
            let report = PlaybackReport(id: Self.id(n), state: .playing, position: position, duration: position)
            // The schedule never looks at position or duration.
            do { let sent = schedule.shouldSend(report, now: Self.t0.addingTimeInterval(Double(n))); #expect(sent) }
        }
    }
}
