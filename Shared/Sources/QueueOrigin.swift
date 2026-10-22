import Foundation
import PleviDomain

/// Where a queue came from — and, where it is a thing you chose, which thing.
enum QueueOrigin: Hashable, Sendable {
    case album(of: PlayedSource)
    case playlist(of: PlayedSource)
    case artist
    /// A station or a mix, and what it is called.
    case radio(named: String?)
    case songs
    /// A mirrored queue's origin: the target's own `RemoteOrigin`, carried
    /// across as its `kind` and the specific label it sent — never rebuilt into
    /// `.album(of:)`/`.playlist(of:)`, which need a real `PlayedSource` this…
    case remote(kind: Kind, displayName: String)

    /// What kind of listening this is, without the identity.
    enum Kind: String, CaseIterable, Codable, Sendable, Identifiable {
        case album = "album"
        case playlist = "playlist"
        case artist = "artist"
        case radio = "radio"
        case songs = "songs"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .album: "Albums"
            case .playlist: "Playlists"
            case .artist: "Artists"
            case .radio: "Radio & mixes"
            case .songs: "Single songs"
            }
        }

        /// What carrying on means for this kind of listening, said plainly.
        var caption: String {
            switch self {
            case .album: "Keep going after the last track of a record"
            case .playlist: "Keep going after the end of a playlist"
            case .artist: "Keep going after an artist's songs run out"
            case .radio: "Keep a station going indefinitely"
            case .songs: "Keep going after a song played on its own"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .album: .album
        case .playlist: .playlist
        case .artist: .artist
        case .radio: .radio
        case .songs: .songs
        case .remote(let kind, _): kind
        }
    }

    /// What a mirrored queue should show as its origin — nil for anything but `.remote`, since
    /// every other case already has its own, richer way to be shown (an album's/playlist's
    /// `playedSource`, a station's `radioName`).
    var remoteDisplayName: String? {
        if case .remote(_, let displayName) = self { return displayName }
        return nil
    }

    /// What to write into Recently Played, or nil for listening that leaves no trace.
    var playedSource: PlayedSource? {
        switch self {
        case .album(let source), .playlist(let source): source
        case .artist, .radio, .songs, .remote: nil
        }
    }

    /// A station or mix with nothing to call it.
    static var radio: QueueOrigin { .radio(named: nil) }

    /// What this listening is called, where it has a name of its own.
    var radioName: String? {
        if case .radio(let named) = self { return named }
        return nil
    }

    static func album(_ album: Album) -> QueueOrigin {
        .album(of: PlayedSource(album: album))
    }

    static func playlist(_ playlist: Playlist) -> QueueOrigin {
        .playlist(of: PlayedSource(
            playlist: playlist,
            // Not for a smart one.
            subtitle: playlist.isSmart
                ? nil
                : playlist.trackCount.map { $0.counted("song") }
        ))
    }
}
