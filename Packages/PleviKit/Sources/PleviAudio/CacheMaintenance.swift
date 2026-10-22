import Foundation

/// What the play cache may delete, decided from file names alone.
public enum CacheMaintenance {
    public static let scratchSuffix = ".partial"

    public static func isScratch(_ name: String) -> Bool {
        name.hasSuffix(scratchSuffix)
    }

    public static func isProtected(_ name: String, prefixes: Set<String>) -> Bool {
        prefixes.contains { name.hasPrefix($0) }
    }

    /// What Clear cache may delete.
    public static func clearable(
        _ names: [String],
        inFlightKeys: Set<String>,
        protectedPrefixes: Set<String>
    ) -> [String] {
        let writing = Set(inFlightKeys.map { $0 + scratchSuffix })
        return names.filter { name in
            !writing.contains(name) && !isProtected(name, prefixes: protectedPrefixes)
        }
    }

    public struct ConversionSweep: Equatable, Sendable {
        /// Files to delete now.
        public var drop: [String]
        /// Prefixes whose conversions were spared because the track is in
        /// use, to be dropped once it no longer is.
        public var deferred: Set<String>
    }

    /// What turning off "Keep transcoded files" may delete now.
    public static func conversionSweep(
        _ names: [String],
        protectedPrefixes: Set<String>
    ) -> ConversionSweep {
        var drop: [String] = []
        var deferred: Set<String> = []
        for name in names {
            guard !name.contains("-orig."), !isScratch(name) else { continue }
            if let prefix = protectedPrefixes.first(where: { name.hasPrefix($0) }) {
                deferred.insert(prefix)
            } else {
                drop.append(name)
            }
        }
        return ConversionSweep(drop: drop, deferred: deferred)
    }

    /// Which deferred conversions are now due, after the protected set
    /// changed.
    public static func dueAfterProtection(
        deferred: Set<String>,
        nowProtected: Set<String>
    ) -> Set<String> {
        deferred.subtracting(nowProtected)
    }

    /// One file in the cache, as eviction sees it.
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var size: Int64
        /// When the file was written, or last stamped by a play.
        public var modified: Date
        /// When it was last played in this session, if it was.
        public var lastPlayed: Date?

        public init(name: String, size: Int64, modified: Date, lastPlayed: Date? = nil) {
            self.name = name
            self.size = size
            self.modified = modified
            self.lastPlayed = lastPlayed
        }

        /// What "least recently used" sorts by: a play counts as a use, and
        /// a file never played counts from when it arrived.
        public var lastUsed: Date {
            max(modified, lastPlayed ?? .distantPast)
        }
    }

    public struct Eviction: Equatable, Sendable {
        public var evict: [String]
        public var staleScratch: [String]
    }

    /// What to delete to bring the cache under `limit`.
    public static func eviction(
        _ entries: [Entry],
        limit: Int64,
        inFlightKeys: Set<String>,
        protectedPrefixes: Set<String>,
        now: Date = Date(),
        scratchTimeout: TimeInterval = 600
    ) -> Eviction {
        let writing = Set(inFlightKeys.map { $0 + scratchSuffix })
        var stale: [String] = []
        var candidates: [Entry] = []
        var total: Int64 = 0
        for entry in entries {
            if isScratch(entry.name) {
                let idle = now.timeIntervalSince(entry.modified)
                if !writing.contains(entry.name),
                   !isProtected(entry.name, prefixes: protectedPrefixes),
                   idle > scratchTimeout {
                    stale.append(entry.name)
                }
                continue
            }
            total += entry.size
            if !isProtected(entry.name, prefixes: protectedPrefixes) {
                candidates.append(entry)
            }
        }
        guard total > limit else { return Eviction(evict: [], staleScratch: stale) }
        var evict: [String] = []
        for entry in candidates.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard total > limit else { break }
            evict.append(entry.name)
            total -= entry.size
        }
        return Eviction(evict: evict, staleScratch: stale)
    }
}
