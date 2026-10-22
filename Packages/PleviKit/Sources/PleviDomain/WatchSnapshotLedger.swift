import Foundation

/// Which library snapshots are in flight to the watch, and what a transfer ending means.
public struct WatchSnapshotLedger: Sendable, Equatable {
    public struct Transfer: Sendable, Equatable {
        public var file: String
        public var storage: ServerID

        public init(file: String, storage: ServerID) {
            self.file = file
            self.storage = storage
        }
    }

    /// What a transfer ending should do.
    public enum Outcome: Sendable, Equatable {
        /// Delivered.
        case delivered
        /// Replaced by a newer snapshot and cancelled on purpose: its
        /// "failure" is ours and is not a problem to report.
        case superseded
        /// The latest snapshot for its library failed. The send is not done:
        /// the stamp that said so must be taken back, or the hourly limit
        /// would hold off the retry.
        case latestFailed
        /// An older one failed. Worth saying, changes nothing.
        case olderFailed
    }

    private var latest: [ServerID: String] = [:]
    private var superseded: Set<String> = []
    private var storageOfFile: [String: ServerID] = [:]

    public init() {}

    /// Notes a snapshot about to be queued and answers the outstanding ones it replaces: those for
    /// the same library, which the caller cancels.
    public mutating func begin(_ new: Transfer, outstanding: [Transfer]) -> [Transfer] {
        let replaced = outstanding.filter { $0.storage == new.storage && $0.file != new.file }
        for old in replaced { superseded.insert(old.file) }
        latest[new.storage] = new.file
        storageOfFile[new.file] = new.storage
        return replaced
    }

    /// Reads a transfer ending.
    public mutating func finish(file: String, failed: Bool) -> Outcome {
        defer { storageOfFile[file] = nil }
        if superseded.remove(file) != nil { return .superseded }
        guard failed else {
            if let storage = storageOfFile[file], latest[storage] == file { latest[storage] = nil }
            return .delivered
        }
        if let storage = storageOfFile[file], latest[storage] == file {
            latest[storage] = nil
            return .latestFailed
        }
        return .olderFailed
    }

    /// Whether a temporary snapshot file is one to sweep at launch: it is
    /// ours by name and nothing queued refers to it.
    public static func isStale(fileName: String, queued: Set<String>) -> Bool {
        fileName.hasPrefix("library-") && fileName.hasSuffix(".sqlite") && !queued.contains(fileName)
    }

    /// The name of a fresh snapshot file for a library.
    public static func fileName(for storage: ServerID, token: UUID = UUID()) -> String {
        "library-\(storage.rawValue.uuidString)-\(token.uuidString).sqlite"
    }
}
