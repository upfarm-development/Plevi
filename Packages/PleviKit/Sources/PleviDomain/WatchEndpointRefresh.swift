import Foundation

/// When the watch chooses its server address again.
public struct EndpointRefreshGate: Sendable, Equatable {
    public enum Trigger: Sendable, Equatable {
        /// The app came forward, or the watch was just provisioned.
        case foreground
        /// The network path changed shape under a running app.
        case pathChange
        /// A stream, a preparation or a transfer failed in a way an unreachable address explains.
        case failure
    }

    /// The least time between a failure-triggered refresh and the last one of
    /// any kind.
    public var failureInterval: TimeInterval
    private var lastRun: Date?

    public init(failureInterval: TimeInterval = 30) {
        self.failureInterval = failureInterval
    }

    /// Whether a refresh may run now, and if so records that it does.
    public mutating func admit(
        _ trigger: Trigger,
        hasAlternativeAddress: Bool,
        now: Date
    ) -> Bool {
        guard hasAlternativeAddress else { return false }
        switch trigger {
        case .foreground, .pathChange:
            break
        case .failure:
            if let lastRun, now.timeIntervalSince(lastRun) < failureInterval { return false }
        }
        lastRun = now
        return true
    }
}
