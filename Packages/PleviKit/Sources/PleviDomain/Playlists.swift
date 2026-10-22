import Foundation

public struct Playlist: Hashable, Sendable, Codable, Identifiable {
    public let id: MediaID
    public var name: String
    public var comment: String?
    public var trackCount: Int?
    public var duration: TimeInterval?
    public var isPublic: Bool?
    public var changedAt: Date?
    public var artwork: ArtworkID?
    /// A rule rather than a list of songs — Plex's smart playlists. Subsonic
    /// has no equivalent, so there it is always false.
    public var isSmart: Bool

    public init(
        id: MediaID,
        name: String,
        comment: String? = nil,
        trackCount: Int? = nil,
        duration: TimeInterval? = nil,
        isPublic: Bool? = nil,
        changedAt: Date? = nil,
        artwork: ArtworkID? = nil,
        isSmart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.comment = comment
        self.trackCount = trackCount
        self.duration = duration
        self.isPublic = isPublic
        self.changedAt = changedAt
        self.artwork = artwork
        self.isSmart = isSmart
    }
}

/// One row of a playlist. The entry ID — not the track ID — is what removal
/// and reordering operate on, so the same track appearing twice is handled
/// correctly on every backend.
public struct PlaylistEntry: Hashable, Sendable, Codable, Identifiable {
    public let entryID: PlaylistEntryID
    public var track: Track

    public var id: PlaylistEntryID { entryID }

    public init(entryID: PlaylistEntryID, track: Track) {
        self.entryID = entryID
        self.track = track
    }
}

/// Somewhere a playlist's songs can be asked for a page at a time.
public protocol PlaylistPageSource: Sendable {
    func playlistPage(id: MediaID, offset: Int, limit: Int) async throws -> PlaylistPage
}

/// One slice of a playlist's songs, and how long the whole playlist is.
public struct PlaylistPage: Hashable, Sendable, Codable {
    public var playlist: Playlist
    public var entries: [PlaylistEntry]
    /// The playlist's true length, when the server reports it. Nil means it
    /// did not say, and the caller should not invent a number.
    public var total: Int?
    /// How many rows the server sent, which is not always how many entries
    /// came back: a row this app cannot make a song out of is dropped. Paging
    /// counts rows, or a dropped one would shift every page after it.
    public var returnedRows: Int

    public init(
        playlist: Playlist,
        entries: [PlaylistEntry],
        total: Int? = nil,
        returnedRows: Int? = nil
    ) {
        self.playlist = playlist
        self.entries = entries
        self.total = total
        self.returnedRows = returnedRows ?? entries.count
    }
}

public struct PlaylistDetail: Hashable, Sendable, Codable {
    public var playlist: Playlist
    public var entries: [PlaylistEntry]

    public init(playlist: Playlist, entries: [PlaylistEntry]) {
        self.playlist = playlist
        self.entries = entries
    }
}

/// How a list of playlists is ordered.
public enum PlaylistSorting: String, CaseIterable, Identifiable, Sendable {
    case smartFirst
    case together

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .smartFirst: "Smart first"
        case .together: "All together"
        }
    }

    /// Names are compared the way a person reads them, so "Now 9" comes before "Now 10" rather than
    /// after it.
    public func sorted(
        _ playlists: [Playlist],
        pinnedToTop: Set<String> = []
    ) -> [Playlist] {
        playlists.sorted { first, second in
            if !pinnedToTop.isEmpty {
                let firstPinned = pinnedToTop.contains(first.id.rawValue)
                let secondPinned = pinnedToTop.contains(second.id.rawValue)
                if firstPinned != secondPinned { return firstPinned }
            }
            if self == .smartFirst, first.isSmart != second.isSmart {
                return first.isSmart
            }
            let order = first.name.localizedStandardCompare(second.name)
            if order == .orderedSame { return first.id.rawValue < second.id.rawValue }
            return order == .orderedAscending
        }
    }
}
