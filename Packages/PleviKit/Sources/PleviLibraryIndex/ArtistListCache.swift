import Foundation
import Synchronization
import PleviDomain

/// The last artist list that was read, kept so opening it again is free — the artist twin of
/// `SongListCache`.
public final class ArtistListCache: Sendable {
    /// What an entry is an answer to — the same reasoning as
    /// `SongListCache.Key` for each field, unchanged.
    public struct Key: Equatable, Sendable {
        public var library: ServerID
        public var version: Int
        public var offline: Bool
        public var filter: LibraryFilter
        /// How the list was sorted when it was cached, and which way round —
        /// the same rows in a different sequence are not interchangeable.
        public var order: LibraryIndex.ArtistOrder
        public var direction: LibraryIndex.SortDirection

        public init(
            library: ServerID,
            version: Int,
            offline: Bool,
            filter: LibraryFilter,
            order: LibraryIndex.ArtistOrder = .alphabetical,
            direction: LibraryIndex.SortDirection = .forward
        ) {
            self.library = library
            self.version = version
            self.offline = offline
            self.filter = filter
            self.order = order
            self.direction = direction
        }
    }

    public struct Entry: Sendable {
        public var key: Key
        public var artists: [Artist]
        public var runs: AlphabetIndex.SectionRuns?

        public init(key: Key, artists: [Artist], runs: AlphabetIndex.SectionRuns?) {
            self.key = key
            self.artists = artists
            self.runs = runs
        }
    }

    private let held = Mutex<Entry?>(nil)

    public init() {}

    public func entry(for key: Key) -> Entry? {
        held.withLock { $0?.key == key ? $0 : nil }
    }

    public func anything() -> Entry? {
        held.withLock { $0 }
    }

    /// Refuses an order or filter that plays make stale without the version
    /// noticing — see `SongListCache.store(_:)`.
    public func store(_ entry: Entry) {
        guard entry.key.order.isCacheable, entry.key.filter.isCacheable else { return }
        held.withLock { $0 = entry }
    }

    public func clear() {
        held.withLock { $0 = nil }
    }

    public var isEmpty: Bool {
        held.withLock { $0 == nil }
    }
}
