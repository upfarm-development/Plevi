import Foundation
import Testing
@testable import PleviTransport

@Suite("The watchdog measures silence, not duration")
struct InactivityWatchdogTests {
    @Test("A transfer that never produces anything expires at the idle limit")
    func silenceExpires() async throws {
        let clock = ActivityClock()
        let started = ContinuousClock.now
        let expiry = try await InactivityWatchdog.expiry(of: clock, idleLimit: .milliseconds(150))
        #expect(expiry == .idle)
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(140))
        // Woken for the expiry itself, not on some coarser poll.
        #expect(waited < .milliseconds(1500))
    }

    @Test("A transfer that keeps trickling bytes never expires, however long it runs")
    func trickleNeverExpires() async throws {
        let clock = ActivityClock()
        let idleLimit = Duration.milliseconds(200)
        let watching = Task { try await InactivityWatchdog.expiry(of: clock, idleLimit: idleLimit) }

        // Three times the idle limit in total, with a byte every 50 ms.
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .milliseconds(600) {
            clock.touch()
            try await Task.sleep(for: .milliseconds(50))
        }
        watching.cancel()
        await #expect(throws: CancellationError.self) { try await watching.value }
    }

    @Test("Once the bytes stop, the watchdog expires an idle limit after the last one")
    func expiresAfterTheLastByte() async throws {
        let clock = ActivityClock()
        let watching = Task { try await InactivityWatchdog.expiry(of: clock, idleLimit: .milliseconds(200)) }
        for _ in 0..<6 {
            clock.touch()
            try await Task.sleep(for: .milliseconds(50))
        }
        let lastByte = ContinuousClock.now
        #expect(try await watching.value == .idle)
        #expect(ContinuousClock.now - lastByte >= .milliseconds(120))
    }

    @Test("The overall cap ends a transfer that is lively but never finishes")
    func overallCap() async throws {
        let clock = ActivityClock()
        let watching = Task {
            try await InactivityWatchdog.expiry(
                of: clock, idleLimit: .milliseconds(200), totalLimit: .milliseconds(400)
            )
        }
        let started = ContinuousClock.now
        // Lively for well past the cap; the cap has to be what ends it.
        while ContinuousClock.now - started < .milliseconds(1500) {
            clock.touch()
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(try await watching.value == .overall)
    }

    @Test("Cancelling the caller stops it")
    func cancellation() async {
        let clock = ActivityClock()
        let watching = Task { try await InactivityWatchdog.expiry(of: clock, idleLimit: .seconds(60)) }
        watching.cancel()
        await #expect(throws: CancellationError.self) { try await watching.value }
    }
}
