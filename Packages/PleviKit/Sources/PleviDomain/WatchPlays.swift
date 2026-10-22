import Foundation

/// Plays the watch counted while it could not tell the server.
public struct PendingPlays: Codable, Equatable, Sendable {
    public struct Play: Codable, Hashable, Sendable {
        /// The song's raw id on its server (the library is the list's own).
        public var trackID: String
        public var playedAt: Date

        public init(trackID: String, playedAt: Date) {
            self.trackID = trackID
            self.playedAt = playedAt
        }
    }

    /// A wrist does not hold a diary. Past this the oldest go first: the
    /// recent plays are the ones still worth counting.
    public static let capacity = 200

    public private(set) var plays: [Play] = []

    public init() {}

    public var isEmpty: Bool { plays.isEmpty }

    /// Notes a play. The same song at the same moment is one play, so a
    /// scrobble that is queued twice by a retry is not counted twice.
    public mutating func enqueue(trackID: String, at date: Date) {
        let play = Play(trackID: trackID, playedAt: date)
        guard !plays.contains(play) else { return }
        plays.append(play)
        if plays.count > Self.capacity { plays.removeFirst(plays.count - Self.capacity) }
    }

    /// The next to send, oldest first.
    public var next: Play? { plays.first }

    /// Takes the oldest off, once the server has accepted it — or once it is
    /// certain the server never will.
    public mutating func removeNext() {
        guard !plays.isEmpty else { return }
        plays.removeFirst()
    }

    /// What to do with the play that just failed to send.
    public enum Outcome: Equatable, Sendable {
        /// Leave it and stop: the server or the link is not there right now.
        case keepAndStop
        /// Drop it and go on: the server answered, and said no. Asking again
        /// would be the same answer for ever, at the front of a queue.
        case drop
    }

    public static func outcome(afterFailure error: any Error) -> Outcome {
        if error is CancellationError { return .keepAndStop }
        if (error as? URLError)?.code == .cancelled { return .keepAndStop }
        if case .network(let underlying)? = error as? ProviderError, underlying.code == .cancelled {
            return .keepAndStop
        }
        return ConnectionFailureKind.classify(error).isWorthRetrying ? .keepAndStop : .drop
    }
}

/// Filters a list of songs to the ones a watch can play without a server.
public enum PlayableSongs {
    /// - Parameter downloaded: the raw ids of the songs that have a file on
    ///   the watch.
    public static func filter(_ tracks: [Track], downloaded: Set<String>) -> [Track] {
        tracks.filter { downloaded.contains($0.id.rawValue) }
    }
}

extension PlayHistory {
    /// The history with a play that may have happened earlier than the ones already there, placed
    /// by when it happened.
    public static func replaying(
        _ source: PlayedSource,
        at date: Date,
        in remembered: [PlayedEntry]
    ) -> [PlayedEntry] {
        seeded(remembered + [PlayedEntry(source: source, playedAt: date)])
    }
}
