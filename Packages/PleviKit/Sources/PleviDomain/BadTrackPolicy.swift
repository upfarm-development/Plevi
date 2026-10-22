import Foundation

/// What to do when a song in the queue cannot be played.
public enum BadTrackPolicy {
    /// The most songs skipped in a row. A queue of files that are all bad
    /// stops after this many rather than racing to its end.
    public static let skipLimit = 3

    /// - Parameters: - arrivedAutomatically: the song became current by the previous one ending (or
    /// by an earlier skip), not because the listener chose it.
    public static func shouldSkip(
        arrivedAutomatically: Bool,
        isNetworkClass: Bool,
        isOffline: Bool,
        hasNextInQueue: Bool,
        consecutiveSkips: Int,
        repeatingOne: Bool
    ) -> Bool {
        guard arrivedAutomatically, hasNextInQueue, !repeatingOne else { return false }
        guard consecutiveSkips < skipLimit else { return false }
        return isOffline || !isNetworkClass
    }
}
