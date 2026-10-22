import Foundation

/// What a connected server can do.
public struct ServerCapabilities: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Every flag at once.
    public static let everything = ServerCapabilities(rawValue: ~0)

    /// Star/heart flag on artists, albums, and tracks.
    public static let favorites = ServerCapabilities(rawValue: 1 << 0)
    /// Whole-star ratings 1–5.
    public static let ratings = ServerCapabilities(rawValue: 1 << 1)
    /// Half-star rating steps (Plex). Only meaningful alongside `.ratings`.
    public static let halfStarRatings = ServerCapabilities(rawValue: 1 << 2)
    /// Playlist read and write.
    public static let playlists = ServerCapabilities(rawValue: 1 << 3)
    /// Reordering playlist entries.
    public static let playlistReorder = ServerCapabilities(rawValue: 1 << 4)
    /// Time-synced lyrics.
    public static let syncedLyrics = ServerCapabilities(rawValue: 1 << 5)
    /// Similar-track radio.
    public static let similarItems = ServerCapabilities(rawValue: 1 << 6)
    /// Top tracks for an artist.
    public static let topTracks = ServerCapabilities(rawValue: 1 << 7)
    /// Artist biography and similar artists.
    public static let artistInfo = ServerCapabilities(rawValue: 1 << 8)
    /// Album review/description text.
    public static let albumInfo = ServerCapabilities(rawValue: 1 << 16)
    /// Client-selectable transcode format/bitrate.
    public static let transcodeSelection = ServerCapabilities(rawValue: 1 << 9)
    /// Seeking into a transcoded stream via a start offset.
    public static let transcodeOffset = ServerCapabilities(rawValue: 1 << 10)
    /// Random track/album browsing.
    public static let randomBrowse = ServerCapabilities(rawValue: 1 << 11)
    /// Play reporting (scrobble / timeline).
    public static let scrobbling = ServerCapabilities(rawValue: 1 << 12)
    /// Server-side jukebox control.
    public static let jukebox = ServerCapabilities(rawValue: 1 << 13)
    /// Folder-based (non-tag) library browsing.
    public static let folderBrowsing = ServerCapabilities(rawValue: 1 << 14)
    /// Genre listing and genre-filtered browsing.
    public static let genreBrowsing = ServerCapabilities(rawValue: 1 << 15)
    /// Records the server judges to sound like a given album — Plex's sonic
    /// analysis. Separate from `.similarItems`, which is track radio: a
    /// server can have one without the other.
    public static let similarAlbums = ServerCapabilities(rawValue: 1 << 17)
    /// The server keeps saved searches of its own — a playlist it refreshes as the library changes,
    /// rather than a list of songs fixed when it was made.
    public static let smartPlaylists = ServerCapabilities(rawValue: 1 << 18)
    /// Sets of records or artists gathered under a name on the server.
    public static let collections = ServerCapabilities(rawValue: 1 << 19)
    /// Making collections and adding to them, as opposed to only reading
    /// them.
    public static let collectionEditing = ServerCapabilities(rawValue: 1 << 20)
    /// A reviewer's verdict on a record, as opposed to the listener's own stars.
    public static let criticRatings = ServerCapabilities(rawValue: 1 << 21)
    /// A log of individual plays, each with its own timestamp — not the
    /// single "last played" date every provider already offers. Plex keeps
    /// one; the Subsonic contract has nothing like it.
    public static let playHistory = ServerCapabilities(rawValue: 1 << 22)
}

extension ServerCapabilities: CustomStringConvertible {
    private static let names: [(Self, String)] = [
        (.favorites, "favorites"),
        (.ratings, "ratings"),
        (.halfStarRatings, "halfStarRatings"),
        (.playlists, "playlists"),
        (.playlistReorder, "playlistReorder"),
        (.syncedLyrics, "syncedLyrics"),
        (.similarItems, "similarItems"),
        (.topTracks, "topTracks"),
        (.artistInfo, "artistInfo"),
        (.albumInfo, "albumInfo"),
        (.transcodeSelection, "transcodeSelection"),
        (.transcodeOffset, "transcodeOffset"),
        (.randomBrowse, "randomBrowse"),
        (.scrobbling, "scrobbling"),
        (.jukebox, "jukebox"),
        (.folderBrowsing, "folderBrowsing"),
        (.genreBrowsing, "genreBrowsing"),
        (.similarAlbums, "similarAlbums"),
        (.smartPlaylists, "smartPlaylists"),
        (.collections, "collections"),
        (.collectionEditing, "collectionEditing"),
        (.criticRatings, "criticRatings"),
        (.playHistory, "playHistory"),
    ]

    public var description: String {
        let present = Self.names.filter { contains($0.0) }.map(\.1)
        return "[\(present.joined(separator: ", "))]"
    }
}
