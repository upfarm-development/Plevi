import Foundation
import Synchronization

/// When something last arrived, for a transfer that is being watched.
public final class ActivityClock: Sendable {
    private let clock = ContinuousClock()
    private let last: Mutex<ContinuousClock.Instant>

    public init() {
        last = Mutex(ContinuousClock().now)
    }

    /// Something arrived.
    public func touch() {
        let now = clock.now
        last.withLock { $0 = now }
    }

    /// How long it has been since something arrived, or since the transfer
    /// began if nothing has.
    public var idleFor: Duration {
        clock.now - last.withLock { $0 }
    }
}

/// A deadline that measures silence rather than duration.
public enum InactivityWatchdog {
    public enum Expiry: Sendable, Equatable {
        /// Nothing arrived for `idleLimit`.
        case idle
        /// The transfer ran for `totalLimit`, however lively it was.
        case overall
    }

    /// Returns once nothing has been `touch`ed for `idleLimit`, or, if given, once `totalLimit` has
    /// passed since the call — whichever comes first.
    public static func expiry(
        of activity: ActivityClock,
        idleLimit: Duration,
        totalLimit: Duration? = nil
    ) async throws -> Expiry {
        let clock = ContinuousClock()
        let started = clock.now
        while true {
            try Task.checkCancellation()
            let idleLeft = idleLimit - activity.idleFor
            let totalLeft = totalLimit.map { $0 - (clock.now - started) }
            if let totalLeft, totalLeft <= .zero { return .overall }
            if idleLeft <= .zero { return .idle }
            try await Task.sleep(for: min(idleLeft, totalLeft ?? idleLeft))
        }
    }
}
