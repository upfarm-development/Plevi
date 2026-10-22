import Foundation

/// The per-library half of the settings backup, as plain functions so it can be tested without a
/// phone or an iCloud account.
public enum LibraryBackup {
    /// One library's values: the unscoped key (`home.sectionOrder`, ...) and
    /// its plist value.
    public typealias Values = [String: Any]

    /// The libraries of a stored document with the open one's values put over it.
    public static func merged(
        stored: [String: Values],
        active fingerprint: String?,
        values: Values
    ) -> [String: Values] {
        var libraries = stored
        if let fingerprint, !values.isEmpty { libraries[fingerprint] = values }
        return libraries
    }

    /// Whether a document of `size` bytes is small enough to keep every
    /// library in. iCloud's key-value store allows a megabyte in all, and
    /// the settings and the play logs share it.
    public static let documentBudget = 600_000

    /// Whether the other libraries should be dropped from a document of
    /// `size` bytes: the open library's own are worth more than the rest.
    public static func shouldDropOtherLibraries(documentSize size: Int) -> Bool {
        size > documentBudget
    }

    /// A value an earlier build filed under `<base>.<library uuid>` for a
    /// setting that belongs to the whole app. Which library's, if several
    /// have one, is the first in key order; they were all the same setting.
    public static func firstScopedValue(of base: String, in defaults: UserDefaults) -> Any? {
        let prefix = base + "."
        let scoped = defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(prefix) && UUID(uuidString: String($0.key.dropFirst(prefix.count))) != nil }
        return scoped.keys.sorted().first.flatMap { scoped[$0] }
    }

    // MARK: Adopting

    /// The pending entry for `fingerprint`, keyed by the scoped names the app reads
    /// (`home.sectionOrder.<uuid>`), for writing into the defaults.
    public static func scopedValues(
        of values: Values,
        scope: String,
        rebasingPlayLogTo library: ServerID?,
        playLogKey: String
    ) -> Values {
        var scoped: Values = [:]
        for (base, value) in values {
            if base == playLogKey, let library, let data = value as? Data {
                scoped["\(base).\(scope)"] = PlayHistory.rebased(data, to: library) ?? data
            } else {
                scoped["\(base).\(scope)"] = value
            }
        }
        return scoped
    }
}

public extension PlayHistory {
    /// `entries` with every id rewritten to belong to `server`.
    static func rebased(_ entries: [PlayedEntry], to server: ServerID) -> [PlayedEntry] {
        entries.map { entry in
            var entry = entry
            entry.source.mediaID = MediaID(server: server, rawValue: entry.source.mediaID.rawValue)
            if let artwork = entry.source.artwork {
                entry.source.artwork = ArtworkID(server: server, rawValue: artwork.rawValue)
            }
            return entry
        }
    }

    /// The same for an encoded log, as it sits in the defaults. `nil` for
    /// data that is not a play log.
    static func rebased(_ data: Data, to server: ServerID) -> Data? {
        guard let entries = try? JSONDecoder().decode([PlayedEntry].self, from: data) else { return nil }
        return try? JSONEncoder().encode(rebased(entries, to: server))
    }
}

/// Whether the install may write its settings over what iCloud holds.
public enum BackupWriteDecision: Equatable, Sendable {
    case write
    /// Nothing was there and this install has settings of its own to keep,
    /// so a snapshot arriving later must not be restored over them.
    case writeAndSettle
    case skip

    public static func decide(settled: Bool, stored: Data?, lastWritten: Data?) -> BackupWriteDecision {
        if settled { return .write }
        guard let stored else { return .writeAndSettle }
        return stored == lastWritten ? .write : .skip
    }
}
