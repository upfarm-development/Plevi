import Foundation

/// The last position the audio system vouched for.
public struct PlayheadMemory: Sendable, Equatable {
    public private(set) var lastGood: TimeInterval?

    public init(lastGood: TimeInterval? = nil) {
        self.lastGood = lastGood
    }

    /// - Parameters: - rendered: the position computed from the render clock, or `nil` when the
    /// clock is not available.
    public mutating func read(rendered: TimeInterval?, fallback: TimeInterval) -> TimeInterval {
        if let rendered, rendered.isFinite {
            lastGood = rendered
            return rendered
        }
        return lastGood ?? fallback
    }

    /// The position moved somewhere the clock did not take it.
    public mutating func reset(to position: TimeInterval?) {
        lastGood = position
    }
}
