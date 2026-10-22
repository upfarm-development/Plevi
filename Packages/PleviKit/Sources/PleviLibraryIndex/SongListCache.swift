import Foundation
import Synchronization
import PleviDomain

/// The last songs list that was read, kept so opening it again is free.
public final class SongListCache: Sendable {
    /// What an entry is an answer to.
    public struct Key: Equatable, Sendable {
        public var library: ServerID
        public var version: Int
        public var offline: Bool
        public var order: LibraryIndex.SongOrder
        /// Which way that order runs.
        public var direction: LibraryIndex.SortDirection
        public var filter: LibraryFilter

        public init(
            library: ServerID,
            version: Int,
            offline: Bool,
            order: LibraryIndex.SongOrder,
            direction: LibraryIndex.SortDirection = .forward,
            filter: LibraryFilter
        ) {
            self.library = library
            self.version = version
            self.offline = offline
            self.order = order
            self.direction = direction
            self.filter = filter
        }
    }

    /// The rows, and where each letter's run sits in them.
    public struct Entry: Sendable {
        public var key: Key
        public var tracks: [Track]
        public var runs: AlphabetIndex.SectionRuns

        public init(key: Key, tracks: [Track], runs: AlphabetIndex.SectionRuns) {
            self.key = key
            self.tracks = tracks
            self.runs = runs
        }
    }

    private let held = Mutex<Entry?>(nil)

    public init() {}

    /// The entry, if it answers exactly this question.
    ///
    /// Reading it is a retain of the existing array, not a copy of it.
    public func entry(for key: Key) -> Entry? {
        held.withLock { $0?.key == key ? $0 : nil }
    }

    /// Keeps an entry, unless its answer goes stale without the version noticing: a play-derived
    /// order or filter (see `LibraryFilter.isCacheable`) is read again on every visit, as it was
    /// before there was a cache.
    public func store(_ entry: Entry) {
        guard entry.key.order.isCacheable, entry.key.filter.isCacheable else { return }
        held.withLock { $0 = entry }
    }

    /// What is held, whatever it answers — for a screen that wants to show
    /// *something* while it checks.
    public func anything() -> Entry? {
        held.withLock { $0 }
    }

    /// Lets go of it.
    public func clear() {
        held.withLock { $0 = nil }
    }

    public var isEmpty: Bool {
        held.withLock { $0 == nil }
    }
}
