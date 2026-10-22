import Foundation
import GRDB
import PleviDomain

/// Opening a library's index file, and what to do when it will not open.
public enum LibraryIndexOpening {
    public enum Outcome {
        case opened(LibraryIndex)
        /// The file was damaged and has been moved to `quarantined`; the index
        /// is a new, empty one. Its downloads and queued changes were in the
        /// old file and are not in this one.
        case rebuilt(LibraryIndex, quarantined: URL)

        public var index: LibraryIndex {
            switch self {
            case .opened(let index), .rebuilt(let index, _): index
            }
        }
    }

    /// Opens `databaseURL`. Throws for anything that is not damage, so the
    /// caller can leave the file alone and try again later.
    public static func open(
        databaseURL: URL,
        serverID: ServerID,
        now: Date = Date()
    ) throws -> Outcome {
        do {
            return .opened(try LibraryIndex(databaseURL: databaseURL, serverID: serverID))
        } catch {
            guard isDamage(error) else { throw error }
            let quarantined = try setAside(databaseURL, now: now)
            let index = try LibraryIndex(databaseURL: databaseURL, serverID: serverID)
            return .rebuilt(index, quarantined: quarantined)
        }
    }

    /// Whether `error` says the file itself is bad, as opposed to the moment
    /// being bad.
    static func isDamage(_ error: any Error) -> Bool {
        if let failure = error as? LibraryIndex.MigrationFailure {
            // A migration that fails on a healthy file fails the same way
            // every launch, which is the "never repaired" state. One that
            // fails for want of room or a lock does not.
            guard failure.underlying is DatabaseError else { return false }
            return !isTransient(failure.underlying)
        }
        guard let database = error as? DatabaseError else { return false }
        return database.resultCode.primaryResultCode == .SQLITE_NOTADB
            || database.resultCode.primaryResultCode == .SQLITE_CORRUPT
    }

    private static func isTransient(_ error: any Error) -> Bool {
        guard let database = error as? DatabaseError else { return false }
        let transient: [ResultCode] = [
            .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_FULL, .SQLITE_IOERR, .SQLITE_NOMEM,
            .SQLITE_READONLY, .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_INTERRUPT,
            .SQLITE_PROTOCOL, .SQLITE_AUTH,
        ]
        return transient.contains { $0 == database.resultCode.primaryResultCode }
    }

    /// Moves the file and its `-wal` and `-shm` beside it to
    /// `<name>.corrupt-<date>`, so nothing is destroyed and the sidecars of
    /// the bad file are never read as belonging to the new one.
    private static func setAside(_ url: URL, now: Date) throws -> URL {
        let stamp = Int(now.timeIntervalSince1970)
        var target = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)")
        var attempt = 1
        while FileManager.default.fileExists(atPath: target.path) {
            attempt += 1
            target = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)-\(attempt)")
        }
        try FileManager.default.moveItem(at: url, to: target)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            try? FileManager.default.moveItem(
                at: sidecar,
                to: URL(fileURLWithPath: target.path + suffix)
            )
        }
        return target
    }
}

extension LibraryIndex {
    /// A migration that threw while opening a file that had otherwise opened.
    /// Kept apart from the open itself so `LibraryIndexOpening` can tell a
    /// schema this build cannot bring forward from a disk that was full.
    public struct MigrationFailure: Error {
        public let underlying: any Error
    }
}
