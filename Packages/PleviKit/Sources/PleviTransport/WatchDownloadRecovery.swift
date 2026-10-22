import Foundation

/// What the watch's download queue does about a failure, once `TransferFailureClassifier` has said
/// what kind it was.
public enum WatchDownloadRecovery {
    public enum Decision: Sendable, Equatable {
        /// The song is failed and says why.
        case fail
        /// The song goes back in the queue and the queue waits `seconds`
        /// before trying anything. `chargesAttempt` is whether this counts
        /// against the song's retries.
        case retry(after: TimeInterval, chargesAttempt: Bool)
        /// Every other song would fail the same way. The queue is held, once,
        /// with one message, and the song keeps its place.
        case holdQueue(FailureDisposition)
    }

    /// How many times a song is put back for a failure that was the server's
    /// or the link's moment before it is called a failure.
    public static let attemptLimit = 3

    /// How long to wait when there is simply no usable network. Not charged:
    /// nothing is wrong with the song, and the endpoint refresh or a path
    /// change nudges the queue sooner when the link returns.
    public static let networkWait: TimeInterval = 30

    public static func decide(_ disposition: FailureDisposition, attemptsUsed: Int) -> Decision {
        switch disposition {
        case .terminal:
            return .fail
        case .retryable:
            guard attemptsUsed < attemptLimit else { return .fail }
            return .retry(after: backoff(afterAttempts: attemptsUsed), chargesAttempt: true)
        case .waitForNetwork:
            return .retry(after: networkWait, chargesAttempt: false)
        case .storageFull, .proxyWall:
            return .holdQueue(disposition)
        }
    }

    /// Five seconds, then twenty, then a minute: quick for a hiccup, slow
    /// enough that a server which is properly down is not hammered.
    public static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        switch attempts {
        case ..<1: 5
        case 1: 20
        default: 60
        }
    }

    /// Whether the watchdog's last look was so long ago that the app must have been suspended in
    /// between.
    public static func sweepWasStarved(
        since previous: Date?,
        now: Date,
        interval: TimeInterval = 30
    ) -> Bool {
        guard let previous else { return false }
        return now.timeIntervalSince(previous) > interval * 2
    }

    /// What the queue says when it holds itself.
    public static func message(for disposition: FailureDisposition) -> String {
        switch disposition {
        case .storageFull:
            "This watch is full. Free some space, then start the queue again."
        case .proxyWall:
            "Your server wants a sign-in. Sign in on your iPhone, then start the queue again."
        default:
            "The queue was held."
        }
    }
}

/// Whether a run of songs fits on the watch.
public enum WatchDownloadRoom {
    /// Left free after a batch, for the system and for what is playing.
    public static let margin: Int64 = 200_000_000

    /// How many of the songs, taken in order, fit in `free` bytes with the
    /// margin kept back. A size of nil is taken as `fallback`: a song whose
    /// size nobody knows is not free.
    public static func countThatFit(
        sizes: [Int64?],
        free: Int64,
        margin: Int64 = margin,
        fallback: Int64 = 12_000_000
    ) -> Int {
        var room = free - margin
        var count = 0
        for size in sizes {
            let needed = size ?? fallback
            guard needed <= room else { break }
            room -= needed
            count += 1
        }
        return count
    }
}
