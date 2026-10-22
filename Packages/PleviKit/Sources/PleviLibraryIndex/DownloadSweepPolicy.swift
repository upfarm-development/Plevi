import Foundation

/// When the watch may delete the files nothing refers to.
public enum DownloadSweepPolicy {
    /// - Parameters: - readSucceeded: whether the table was actually read.
    public static func maySweep(readSucceeded: Bool, skipOnce: Bool) -> Bool {
        readSucceeded && !skipOnce
    }
}

/// What reading the rows to carry across a snapshot install found.
public enum CarriedRowsOutcome<Rows> {
    /// No previous index, or no downloads or playlists in it.
    case nothing
    case rows(Rows)
    /// The previous index was there and could not be read.
    case unreadable
}
