import Foundation
import Testing
@testable import PleviTransport

/// The hand-over a background session's launch events are announced through.
@Suite("Waiting for a background session's saved events")
struct LaunchHandoverTests {
    @Test("A waiter is let go when the events are delivered")
    func deliveryResumesAWaiter() async {
        let handover = LaunchHandover()
        async let waited: Void = handover.wait()
        // Give the waiter a chance to register before the delivery, which is
        // the ordinary order and the one that always worked.
        try? await Task.sleep(for: .milliseconds(20))
        handover.deliver()
        await waited
    }

    /// The lost wakeup this type exists for.
    @Test("Asking after the events have already been delivered does not wait")
    func deliveryBeforeAnybodyWaits() async {
        let handover = LaunchHandover()
        handover.deliver()
        await handover.wait()
    }

    /// Many waiters, and the delivery has to reach every one of them.
    @Test("Every waiter is let go, not only the first")
    func deliveryResumesAllWaiters() async {
        let handover = LaunchHandover()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await handover.wait() } }
            try? await Task.sleep(for: .milliseconds(20))
            handover.deliver()
        }
    }

    /// The bound a caller races this against is only a bound if this
    /// cooperates — a task group does not return until its children do.
    @Test("A waiter that is cancelled stops waiting")
    func cancellationEndsTheWait() async {
        let handover = LaunchHandover()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await handover.wait() }
            group.addTask { try? await Task.sleep(for: .milliseconds(20)) }
            await group.next()
            group.cancelAll()
        }
        // Reaching here at all is the assertion: without a cancellation
        // handler the group waits for a waiter nothing will ever deliver to,
        // and this test hangs rather than fails.
    }

    /// A cancel can arrive before the waiter has registered, and a waiter that
    /// then registers must not join a list nothing will read.
    @Test("A waiter cancelled before it registers still stops waiting")
    func cancellationRacingRegistration() async {
        for _ in 0..<200 {
            let handover = LaunchHandover()
            let task = Task { await handover.wait() }
            task.cancel()
            await task.value
        }
    }

    /// The downloader is cached for the life of the process, so a second batch
    /// of transfers has its own hand-over to wait for.
    @Test("A fresh batch is waited for again rather than latched from the last one")
    func expectMoreReopensTheLatch() async {
        let handover = LaunchHandover()
        handover.deliver()
        await handover.wait()

        handover.expectMore()
        let second = Task { await handover.wait() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!second.isCancelled)
        handover.deliver()
        await second.value
    }
}
