import Foundation

/// Something that was deliberately put on: a record, or a playlist.
public struct PlayedSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case album
        case playlist
    }

    public var kind: Kind
    public var mediaID: MediaID
    public var title: String
    public var subtitle: String?
    public var artwork: ArtworkID?

    public init(
        kind: Kind,
        mediaID: MediaID,
        title: String,
        subtitle: String? = nil,
        artwork: ArtworkID? = nil
    ) {
        self.kind = kind
        self.mediaID = mediaID
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
    }

    public init(album: Album) {
        self.init(
            kind: .album,
            mediaID: album.id,
            title: album.name,
            subtitle: album.artistName,
            artwork: album.artwork
        )
    }

    /// The subtitle is the song count spelled out by the caller, because
    /// pluralisation lives in the app rather than here.
    public init(playlist: Playlist, subtitle: String? = nil) {
        self.init(
            kind: .playlist,
            mediaID: playlist.id,
            title: playlist.name,
            subtitle: subtitle,
            artwork: playlist.artwork
        )
    }

    /// A playlist to open, rebuilt from what was recorded. The detail screen
    /// fetches the songs itself, so a name and an id are enough to get there
    /// — the same trick `PinnedItem.asPlaylist` uses.
    public var asPlaylist: Playlist {
        Playlist(id: mediaID, name: title, artwork: artwork)
    }
}

/// One thing put on, and when.
public struct PlayedEntry: Codable, Hashable, Identifiable, Sendable {
    public var source: PlayedSource
    public var playedAt: Date

    public init(source: PlayedSource, playedAt: Date) {
        self.source = source
        self.playedAt = playedAt
    }

    /// Kind and id together: a record and a playlist could hold the same raw
    /// value on the same server without being the same thing.
    public var id: String { "\(source.kind.rawValue):\(source.mediaID.rawValue)" }
}

/// What has been put on lately, newest first.
public enum PlayHistory {
    /// How many are kept. A shelf is a glance at the last while, not a diary:
    /// beyond about this many nobody scrolls, and every entry is a name and a
    /// picture held in preferences.
    public static let kept = 30

    /// The history with `source` at the front.
    public static func recording(
        _ source: PlayedSource,
        at date: Date,
        in remembered: [PlayedEntry]
    ) -> [PlayedEntry] {
        let entry = PlayedEntry(source: source, playedAt: date)
        var out = remembered.filter { $0.id != entry.id }
        out.insert(entry, at: 0)
        return Array(out.prefix(kept))
    }

    /// A history built from entries that may be in any order — what the
    /// first-run seed hands over, since it comes from the library index
    /// rather than from anything this recorded.
    public static func seeded(_ entries: [PlayedEntry]) -> [PlayedEntry] {
        var seen: Set<String> = []
        let ordered = entries
            .sorted { $0.playedAt > $1.playedAt }
            .filter { seen.insert($0.id).inserted }
        return Array(ordered.prefix(kept))
    }
}
