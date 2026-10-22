import Foundation

/// Settles what the table says about downloads against what is really on disk, at launch.
public enum DownloadReconciler {
    /// What an older build wrote when it could not ask the server how to fetch a song — including
    /// for every song that was waiting when the app was relaunched without a connection.
    public static let legacyPreparationFailure = "Could not ask the server for this song."

    public enum Action: Equatable, Sendable {
        /// The file is here and has something in it.
        case present
        /// Ask for it again: it was owed, or it is marked done and is gone,
        /// or it is there and empty.
        case redownload
        /// Failed, and says why. Left alone.
        case failed(String)
        /// The replacement never arrived and the copy it was to replace is
        /// still on disk: that copy is the song.
        case restorePrevious
    }

    public struct Entry: Sendable, Equatable {
        public let record: DownloadRecord
        public let action: Action
    }

    public struct Plan: Sendable, Equatable {
        public let entries: [Entry]
        /// The file names the sweep must not touch.
        public let keep: Set<String>
    }

    /// - Parameter fileSize: the size of a named file in the downloads
    ///   directory, or nil when it is not there.
    public static func plan(
        records: [DownloadRecord],
        fileSize: (String) -> Int64?
    ) -> Plan {
        var entries: [Entry] = []
        var keep: Set<String> = []
        entries.reserveCapacity(records.count)

        for record in records {
            let size = record.fileName.flatMap(fileSize)
            let hasFile = (size ?? 0) > 0
            let previousPresent = record.previousFileName
                .flatMap(fileSize)
                .map { $0 > 0 } ?? false

            let action: Action
            if hasFile {
                action = .present
            } else if record.state == .failed {
                if record.failure == legacyPreparationFailure {
                    action = .redownload
                } else if previousPresent {
                    action = .restorePrevious
                } else {
                    action = .failed(record.failure ?? "Download failed.")
                }
            } else {
                action = .redownload
            }
            entries.append(Entry(record: record, action: action))

            // A name is kept when its row is not a failure, whether or not the file exists yet: a
            // transfer that lands between this check and the sweep is the song, not a leftover.
            if let name = record.fileName, size != 0, record.state != .failed || hasFile {
                keep.insert(name)
            }
            // The copy being replaced stays until the replacement is in
            // place; once it is, it is a leftover like any other.
            if let previous = record.previousFileName, !hasFile {
                if record.state != .failed || previousPresent { keep.insert(previous) }
            }
        }
        return Plan(entries: entries, keep: keep)
    }
}
