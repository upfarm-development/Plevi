import Foundation
import Synchronization
import PleviDomain

/// The last few album pages that were read, kept so opening one again is free — the album twin of
/// `SongListCache`.
public final class AlbumListCache: Sendable {
    /// Which page this is, independent of how it happens to be sorted right now.
    public struct Page: Equatable, Sendable {
        public var filter: AlbumFilter
        public var limit: Int

        public init(filter: AlbumFilter, limit: Int) {
            self.filter = filter
            self.limit = limit
        }
    }

    /// What an entry is an answer to. See `SongListCache.Key` for why each
    /// of `library`, `version` and `offline` earns its place; the same
    /// reasoning applies here unchanged.
    public struct Key: Equatable, Sendable {
        public var library: ServerID
        public var version: Int
        public var offline: Bool
        public var page: Page
        /// How this reading of the page was sorted.
        public var query: AlbumFilter
        /// Which way that sort ran.
        public var direction: LibraryIndex.SortDirection
        public var filter: LibraryFilter

        public init(
            library: ServerID,
            version: Int,
            offline: Bool,
            page: Page,
            query: AlbumFilter,
            direction: LibraryIndex.SortDirection = .forward,
            filter: LibraryFilter
        ) {
            self.library = library
            self.version = version
            self.offline = offline
            self.page = page
            self.query = query
            self.direction = direction
            self.filter = filter
        }
    }

    public struct Entry: Sendable {
        public var key: Key
        public var albums: [Album]
        /// `nil` when this page has no jump bar — sorted by date, given
        /// outright by the caller, or too short to be worth one.
        public var runs: AlphabetIndex.SectionRuns?

        public init(key: Key, albums: [Album], runs: AlphabetIndex.SectionRuns?) {
            self.key = key
            self.albums = albums
            self.runs = runs
        }
    }

    /// Below this a read is cheap enough that keeping it buys nothing, and — more to the point — a
    /// cheap page must never be allowed to push out an expensive one.
    public static let minimumRows = 1_000
    /// A small number on purpose. This is not a general-purpose page cache —
    /// it exists to make going into a record and back instant, for whichever
    /// one or two pages are actually being visited that way.
    public static let capacity = 2

    /// Newest first. Small enough that a linear scan costs nothing next to
    /// what it is standing in for.
    private let entries = Mutex<[Entry]>([])

    public init() {}

    public func entry(for key: Key) -> Entry? {
        entries.withLock { $0.first { $0.key == key } }
    }

    /// The most recently held entry for this page in this world, whatever
    /// sort it happened to be read under.
    public func entry(forPage page: Page, library: ServerID, version: Int, offline: Bool) -> Entry? {
        entries.withLock {
            $0.first {
                $0.key.page == page && $0.key.library == library
                    && $0.key.version == version && $0.key.offline == offline
            }
        }
    }

    /// Keeps an entry, unless it is not worth keeping.
    public func store(_ entry: Entry) {
        guard entry.key.query.isCacheable, entry.key.filter.isCacheable, entry.albums.count >= Self.minimumRows else { return }
        entries.withLock { held in
            held.removeAll { $0.key == entry.key }
            held.insert(entry, at: 0)
            if held.count > Self.capacity { held.removeLast(held.count - Self.capacity) }
        }
    }

    /// Drops everything.
    public func clear() {
        entries.withLock { $0.removeAll() }
    }

    public var isEmpty: Bool {
        entries.withLock { $0.isEmpty }
    }
}

extension AlbumFilter {
    /// Whether an order's answer is a pure function of everything else in
    /// the cache key — see `AlbumListCache.store(_:)`.
    var isCacheable: Bool {
        switch self {
        case .random, .rediscover, .mostPlayed, .recentlyPlayed: false
        case .recentlyAdded, .recentlyReleased, .highestRated, .favorites,
             .alphabeticalByName, .alphabeticalByArtist, .genre, .yearRange: true
        }
    }
}

extension LibraryIndex.SongOrder {
    /// Whether the order survives a play unchanged. See
    /// `LibraryFilter.isCacheable`.
    var isCacheable: Bool {
        switch self {
        case .lastPlayed, .mostPlayed: false
        default: true
        }
    }
}

extension LibraryIndex.ArtistOrder {
    var isCacheable: Bool {
        switch self {
        case .lastPlayed, .mostPlayed: false
        default: true
        }
    }
}
