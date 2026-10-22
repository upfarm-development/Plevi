import Foundation
import Synchronization

/// Whoever is waiting to hear that a background session has delivered everything it saved up while
/// the app was away — and whether it already has.
public final class LaunchHandover: Sendable {
    private struct State {
        var delivered = false
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        /// Waiters cancelled before they had a chance to register, so the
        /// registration knows not to bother.
        var cancelled: Set<Int> = []
        var nextToken = 0
    }

    private let state = Mutex<State>(State())

    public init() {}

    /// Says there is something to be told about again.
    public func expectMore() {
        state.withLock { $0.delivered = false }
    }

    /// Waits for the hand-over, unless it has already happened.
    public func wait() async {
        let token: Int? = state.withLock { state in
            guard !state.delivered else { return nil }
            state.nextToken += 1
            return state.nextToken
        }
        guard let token else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = state.withLock { state in
                    // Cleared either way, rather than only on the branch that reads it:
                    // `!state.delivered` short-circuiting before the removal ran was how a token
                    // cancelled just ahead of a concurrent `deliver()` sat in `cancelled` for the
                    // rest of the process —…
                    let wasCancelled = state.cancelled.remove(token) != nil
                    guard !state.delivered, !wasCancelled else { return true }
                    state.waiters[token] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            // The cancel can arrive before the registration. Remembered, so
            // the registration resumes itself rather than joining a list
            // nothing will read.
            let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
                if let waiting = state.waiters.removeValue(forKey: token) { return waiting }
                state.cancelled.insert(token)
                return nil
            }
            waiter?.resume()
        }
    }

    /// Tells everyone waiting, and everyone who asks later.
    public func deliver() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.delivered = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for continuation in waiting { continuation.resume() }
    }
}
