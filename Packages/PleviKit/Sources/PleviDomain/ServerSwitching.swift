import Foundation

/// The rules for rebuilding the connection stack when the active server or library changes, kept as
/// plain values so they can be checked without an app around them.
public struct ConnectionRuns: Sendable, Equatable {
    /// The token of the newest run.
    public private(set) var generation = 0

    /// The storage identity the published stack — provider, downloads, outbox, DJ — was built for,
    /// or `nil` when there is none.
    public private(set) var published: ServerID?

    public init() {}

    /// Starts a run and answers its token.
    public mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    /// Whether `run` is still the newest. A stale run must not publish.
    public func isCurrent(_ run: Int) -> Bool {
        run == generation
    }

    /// Whether a run for `incoming` is about a different library than the stack it would replace.
    public func storageChanged(incoming: ServerID?) -> Bool {
        published != incoming
    }

    /// Records the stack a run has published. Refused, and `false`, for a run
    /// that has been overtaken: it must not claim the stack for its library.
    @discardableResult
    public mutating func publish(_ storage: ServerID, run: Int) -> Bool {
        guard isCurrent(run) else { return false }
        published = storage
        return true
    }

    /// The published stack was taken down (no server, or none could be built).
    public mutating func tearDown() {
        published = nil
    }
}

public enum ServerSwitching {
    /// Whether playback has to stop for a reconnect to `incoming`.
    public static func playbackMustStop(queueServer: ServerID?, incoming: ServerID?) -> Bool {
        guard let queueServer else { return false }
        return queueServer != incoming
    }

    /// Which server is active after one is stored.
    public static func activeServerAfterStoring(
        _ stored: ServerID,
        wasAlreadyListed: Bool,
        currentlyActive: ServerID?
    ) -> ServerID {
        if wasAlreadyListed, let currentlyActive { return currentlyActive }
        return stored
    }

    /// Whether a download manager may delete files that no row accounts for.
    public static func mayRemoveUnaccountedFiles(
        managerServer: ServerID,
        indexServer: ServerID
    ) -> Bool {
        managerServer == indexServer
    }
}
