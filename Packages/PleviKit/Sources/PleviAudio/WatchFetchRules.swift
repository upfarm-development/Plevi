import Foundation

/// The rules behind the watch's whole-song fetches, kept free of AVFoundation and of the watch
/// target so they can be tested in the package.

/// Which files in the fetched-songs directory belong to which song.
public enum FetchedFileName {
    /// Whether `fileName` is the finished file of the song called `safeName`.
    /// A `.partial` is not finished.
    public static func isFinishedFile(_ fileName: String, forSafeName safeName: String) -> Bool {
        guard fileName.hasPrefix(safeName + ".") else { return false }
        return !fileName.hasSuffix(".partial")
    }

    /// Whether `fileName` belongs to any of `safeNames`, finished or not —
    /// the test the eviction sweep keeps a file by, so a `.partial` still
    /// being written is judged by the song it belongs to.
    public static func belongs(_ fileName: String, toAnyOf safeNames: Set<String>) -> Bool {
        safeNames.contains { fileName.hasPrefix($0 + ".") }
    }
}

/// Songs whose fetch just failed, held back for a while.
public struct WarmCooldown: Sendable, Equatable {
    public var interval: TimeInterval
    private var failedAt: [String: Date] = [:]

    public init(interval: TimeInterval = 90) {
        self.interval = interval
    }

    public mutating func recordFailure(of id: String, at now: Date) {
        failedAt[id] = now
    }

    /// A song that fetched is no longer suspect.
    public mutating func recordSuccess(of id: String) {
        failedAt[id] = nil
    }

    public func isCoolingDown(_ id: String, at now: Date) -> Bool {
        guard let failed = failedAt[id] else { return false }
        return now.timeIntervalSince(failed) < interval
    }

    /// Forgets songs that have long since cooled, so the table cannot grow
    /// for the life of the process.
    public mutating func prune(at now: Date) {
        failedAt = failedAt.filter { now.timeIntervalSince($0.value) < interval }
    }
}

/// Which whole-song fetches may go on running when the listener moves.
public enum FetchReaping {
    /// The fetches to cancel: everything running that is not the song now current or one of the few
    /// just ahead.
    public static func stale(
        running: [String],
        current: String?,
        ahead: [String]
    ) -> [String] {
        var keep = Set(ahead)
        if let current { keep.insert(current) }
        return running.filter { !keep.contains($0) }
    }
}
