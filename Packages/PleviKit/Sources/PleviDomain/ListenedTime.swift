import Foundation

/// How long a song has actually been listened to, as opposed to how far into it the play head
/// happens to be.
public struct ListenedTime: Sendable, Equatable {
    /// The longest gap between two ticks that still counts as listening. The
    /// engine reports twice a second; a few missed ticks (a busy main thread)
    /// are still listening, a jump of a minute is a seek.
    public static let plausibleStep: TimeInterval = 2

    /// The most a listener is asked for, however long the song. Half of a
    /// two-hour DJ mix is an hour; four minutes is a play.
    public static let cap: TimeInterval = 240

    public private(set) var seconds: TimeInterval = 0
    private var lastPosition: TimeInterval?

    public init() {}

    public mutating func tick(position: TimeInterval) {
        defer { lastPosition = position }
        guard position.isFinite, let last = lastPosition else { return }
        let step = position - last
        if step > 0, step <= Self.plausibleStep { seconds += step }
    }

    /// The position moved by other means than playing (a seek): the next tick
    /// is measured from wherever it lands.
    public mutating func noteJump() {
        lastPosition = nil
    }

    public mutating func reset() {
        seconds = 0
        lastPosition = nil
    }

    /// Whether enough of a song of this length has been heard to count as a
    /// play: half of it, or `cap` seconds, whichever is less. A song of
    /// unknown length cannot be judged, so it counts.
    public func countsAsPlayed(duration: TimeInterval?) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return true }
        return seconds >= min(duration / 2, Self.cap)
    }
}
