import Foundation
import Synchronization
import Testing
@testable import PleviTransport

/// playback-22: cancelling the caller that waits on a shared transfer has to
/// reach the transfer — once nobody else is waiting for it.
@Suite("Waiting on a shared transfer", .serialized)
struct TransferWaitersTests {
    /// A transfer that does nothing until it is cancelled, and says so.
    private final class Probe: Sendable {
        private let state = Mutex((started: false, cancelled: false))
        var cancelled: Bool { state.withLock { $0.cancelled } }
        var started: Bool { state.withLock { $0.started } }

        func makeTask() -> Task<Int, any Error> {
            Task.detached {
                self.state.withLock { $0.started = true }
                do {
                    try await Task.sleep(for: .seconds(30))
                    return 1
                } catch {
                    self.state.withLock { $0.cancelled = true }
                    throw error
                }
            }
        }
    }

    private func settle(_ milliseconds: Int = 150) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    @Test("Cancelling the only waiter cancels the transfer, after the grace")
    func lastWaiterCallsItOff() async {
        let probe = Probe()
        let task = probe.makeTask()
        let waiters = TransferWaiters()
        let abandoned = Mutex(0)
        let waiting = Task {
            try await TransferWaiting.wait(
                on: task, waiters: waiters, grace: .milliseconds(50),
                onAbandoned: { abandoned.withLock { $0 += 1 } }
            )
        }
        await settle()
        waiting.cancel()
        await settle(400)
        #expect(probe.cancelled, "the transport call was cancelled")
        #expect(abandoned.withLock { $0 } == 1)
        #expect(waiters.isAbandoned)
        _ = await waiting.result
    }

    @Test("Cancelling one of two waiters leaves the transfer running")
    func otherWaiterKeepsItAlive() async {
        let probe = Probe()
        let task = probe.makeTask()
        let waiters = TransferWaiters()
        let first = Task {
            try await TransferWaiting.wait(on: task, waiters: waiters, grace: .milliseconds(50))
        }
        let second = Task {
            try await TransferWaiting.wait(on: task, waiters: waiters, grace: .milliseconds(50))
        }
        await settle()
        #expect(waiters.count == 2)
        first.cancel()
        await settle(400)
        #expect(!probe.cancelled)
        #expect(!waiters.isAbandoned)
        second.cancel()
        await settle(400)
        #expect(probe.cancelled)
        _ = await first.result
        _ = await second.result
    }

    @Test("A waiter that comes back within the grace keeps the transfer alive (a queue edit re-running the read-ahead)")
    func returnWithinGrace() async {
        let probe = Probe()
        let task = probe.makeTask()
        let waiters = TransferWaiters()
        let first = Task {
            try await TransferWaiting.wait(on: task, waiters: waiters, grace: .milliseconds(300))
        }
        await settle()
        first.cancel()
        // The replacement pass asks for the same song a moment later.
        await settle(50)
        let second = Task {
            try await TransferWaiting.wait(on: task, waiters: waiters, grace: .milliseconds(300))
        }
        await settle(600)
        #expect(!probe.cancelled, "the transfer was not started over")
        #expect(waiters.count == 1)
        second.cancel()
        task.cancel()
        _ = await first.result
        _ = await second.result
    }

    @Test("A transfer that finishes is not cancelled, and every waiter gets the answer")
    func finishedTransfersAreLeftAlone() async throws {
        let waiters = TransferWaiters()
        let task = Task<Int, any Error>.detached {
            try await Task.sleep(for: .milliseconds(50))
            return 7
        }
        async let a = TransferWaiting.wait(on: task, waiters: waiters)
        async let b = TransferWaiting.wait(on: task, waiters: waiters)
        let (x, y) = try await (a, b)
        #expect(x == 7 && y == 7)
        #expect(waiters.count == 0)
        #expect(!waiters.isAbandoned)
    }

    @Test("A caller that is already cancelled does not join; with nobody else waiting the transfer is not left to run unwatched")
    func alreadyCancelledCaller() async {
        let probe = Probe()
        let task = probe.makeTask()
        let waiters = TransferWaiters()
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TransferWaiting.wait(on: task, waiters: waiters, grace: .milliseconds(20))
        }
        let result = await waiting.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(waiters.count == 0)
        await settle(300)
        #expect(probe.cancelled, "an orphan: nobody joined it, nobody is going to")
    }

    @Test("A caller that is already cancelled leaves a transfer someone else is waiting on alone")
    func alreadyCancelledCallerWithCompany() async {
        let probe = Probe()
        let task = probe.makeTask()
        let waiters = TransferWaiters()
        let other = Task {
            try await TransferWaiting.wait(on: task, waiters: waiters, grace: .milliseconds(20))
        }
        await settle()
        let late = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TransferWaiting.wait(on: task, waiters: waiters, grace: .milliseconds(20))
        }
        _ = await late.result
        await settle(300)
        #expect(!probe.cancelled)
        other.cancel()
        task.cancel()
        _ = await other.result
    }

    @Test("An abandoned transfer cannot be joined")
    func abandonedCannotBeJoined() {
        let waiters = TransferWaiters()
        let ticket = waiters.join()
        #expect(ticket != nil)
        #expect(waiters.leave(ticket!))
        #expect(waiters.abandonIfUnwatched())
        #expect(waiters.join() == nil)
        #expect(!waiters.abandonIfUnwatched(), "only once")
    }

    @Test("An owner that calls the transfer off itself makes it unjoinable, and the waiters leaving does not repeat the cleanup")
    func forcedAbandonment() async {
        let probe = Probe()
        let task = probe.makeTask()
        let waiters = TransferWaiters()
        let abandoned = Mutex(0)
        let waiting = Task {
            try await TransferWaiting.wait(
                on: task, waiters: waiters, grace: .milliseconds(30),
                onAbandoned: { abandoned.withLock { $0 += 1 } }
            )
        }
        await settle()
        waiters.forceAbandon()
        #expect(waiters.join() == nil)
        task.cancel()
        _ = await waiting.result
        await settle(200)
        #expect(abandoned.withLock { $0 } == 0)
    }

    @Test("Leaving twice counts once")
    func leavingIsIdempotent() {
        let waiters = TransferWaiters()
        let a = waiters.join()!
        let b = waiters.join()!
        #expect(!waiters.leave(a))
        #expect(!waiters.leave(a))
        #expect(waiters.count == 1)
        #expect(waiters.leave(b))
    }

    @Test("A waiter that joins before the grace ends wins the race against abandonment")
    func joinBeatsAbandon() {
        let waiters = TransferWaiters()
        let a = waiters.join()!
        _ = waiters.leave(a)
        let b = waiters.join()
        #expect(b != nil)
        #expect(!waiters.abandonIfUnwatched())
    }
}
