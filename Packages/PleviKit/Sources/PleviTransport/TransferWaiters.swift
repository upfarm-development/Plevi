import Foundation
import Synchronization

/// Who is waiting on a transfer that several callers may share, so the last one to lose interest
/// can call it off.
public final class TransferWaiters: Sendable {
    private struct State {
        var count = 0
        var abandoned = false
    }
    private let state = Mutex(State())

    public init() {}

    /// One caller's place among the waiters, so leaving twice counts once.
    public final class Ticket: Sendable {
        private let left = Mutex(false)
        init() {}
        fileprivate func markLeft() -> Bool {
            left.withLock { done in
                defer { done = true }
                return !done
            }
        }
    }

    /// Adds a waiter. `nil` when the transfer has already been abandoned and
    /// must not be joined: what it was doing is being torn down.
    public func join() -> Ticket? {
        state.withLock { state in
            guard !state.abandoned else { return nil }
            state.count += 1
            return Ticket()
        }
    }

    /// Removes a waiter. Returns whether nobody is left.
    @discardableResult
    public func leave(_ ticket: Ticket) -> Bool {
        guard ticket.markLeft() else { return false }
        return state.withLock { state in
            state.count -= 1
            return state.count <= 0
        }
    }

    /// Whether the transfer still has nobody waiting, marking it abandoned if
    /// so. Atomic with `join`: a caller that joins first keeps it alive, one
    /// that comes after is told it is gone.
    public func abandonIfUnwatched() -> Bool {
        state.withLock { state in
            guard state.count <= 0, !state.abandoned else { return false }
            state.abandoned = true
            return true
        }
    }

    /// Marks the transfer abandoned whoever is still waiting, for an owner
    /// that is calling it off itself: nobody new may join it, and the
    /// cleanup that follows an abandonment by the waiters is not repeated.
    public func forceAbandon() {
        state.withLock { $0.abandoned = true }
    }

    public var isAbandoned: Bool { state.withLock { $0.abandoned } }
    public var count: Int { state.withLock { $0.count } }
}

public enum TransferWaiting {
    /// How long a transfer with nobody waiting is left to see whether somebody comes back.
    public static let defaultGrace: Duration = .seconds(5)

    /// Waits for a shared transfer, and gives up on the transfer itself once nobody is waiting for
    /// it any more.
    public static func wait<T: Sendable>(
        on task: Task<T, any Error>,
        waiters: TransferWaiters,
        grace: Duration = defaultGrace,
        onAbandoned: @escaping @Sendable () -> Void = {}
    ) async throws -> T {
        // Already cancelled: do not join. But a transfer nobody is waiting on
        // must not be left to run unwatched — the caller that just started it
        // may be the very one that was cancelled — so the clock starts.
        if Task.isCancelled {
            if waiters.count == 0 { scheduleAbandonment(of: task, waiters: waiters, grace: grace, onAbandoned: onAbandoned) }
            throw CancellationError()
        }
        guard let ticket = waiters.join() else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            defer { waiters.leave(ticket) }
            return try await task.value
        } onCancel: {
            guard waiters.leave(ticket) else { return }
            scheduleAbandonment(of: task, waiters: waiters, grace: grace, onAbandoned: onAbandoned)
        }
    }

    private static func scheduleAbandonment<T: Sendable>(
        of task: Task<T, any Error>,
        waiters: TransferWaiters,
        grace: Duration,
        onAbandoned: @escaping @Sendable () -> Void
    ) {
        Task.detached {
            try? await Task.sleep(for: grace)
            guard waiters.abandonIfUnwatched() else { return }
            task.cancel()
            onAbandoned()
        }
    }
}
