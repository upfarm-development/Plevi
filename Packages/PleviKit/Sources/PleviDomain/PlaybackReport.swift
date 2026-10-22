import Foundation

/// What is playing, where it has got to, and whether it is still going.
public struct PlaybackReport: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case playing
        case paused
        /// Nothing is playing any more — this song, at this point, is done
        /// with. Sent when the queue moves on as well as when it is stopped
        /// outright, because a dashboard has no other way to know.
        case stopped
    }

    public let id: MediaID
    public let state: State
    /// How far into the song, in seconds.
    public let position: TimeInterval
    /// Its length, where that is known yet. A stream still opening does not
    /// know it, and a report is worth sending before it does.
    public let duration: TimeInterval?

    public init(
        id: MediaID,
        state: State,
        position: TimeInterval,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.state = state
        self.position = position
        self.duration = duration
    }
}

/// Decides when a server is due to be told again.
public struct PlaybackReportSchedule: Sendable {
    /// How often a song that is simply playing is reported again.
    public static let interval: TimeInterval = 8

    private var lastState: PlaybackReport.State?
    private var lastID: MediaID?
    private var lastSent: Date?

    public init() {}

    /// Whether this report should go now.
    public mutating func shouldSend(_ report: PlaybackReport, now: Date) -> Bool {
        guard send(report, now: now) else { return false }
        lastState = report.state
        lastID = report.id
        lastSent = now
        return true
    }

    /// Remembered only when something is actually sent.
    private func send(_ report: PlaybackReport, now: Date) -> Bool {
        // A different song, or a different thing happening to it, is news
        // whenever it arrives.
        if report.id != lastID || report.state != lastState { return true }
        // Nothing further to say about a song that has already stopped.
        if report.state == .stopped { return false }
        guard let lastSent else { return true }
        // A clock that has been stepped backwards makes the interval negative for as long as the
        // step is wide — an hour, after a bad RTC is corrected — and a song that is simply playing
        // would go unreported that whole time.
        let elapsed = now.timeIntervalSince(lastSent)
        return elapsed >= Self.interval || elapsed < 0
    }

    /// Forgets what was last said, so the next report goes whatever it is.
    public mutating func reset() {
        lastState = nil
        lastID = nil
        lastSent = nil
    }
}
