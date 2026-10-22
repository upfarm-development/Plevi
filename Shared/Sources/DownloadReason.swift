import Foundation
import PleviDomain

/// Why a track is being kept: the album, playlist or artist it was asked for as part of, or the
/// song on its own.
enum DownloadReason: Hashable, Sendable {
    case album(MediaID)
    case playlist(MediaID)
    case artist(MediaID)
    case track(MediaID)

    var key: String {
        switch self {
        case .album(let id): "album:\(id.rawValue)"
        case .playlist(let id): "playlist:\(id.rawValue)"
        case .artist(let id): "artist:\(id.rawValue)"
        case .track(let id): "track:\(id.rawValue)"
        }
    }

    /// Back from the key, for a queue read off the disk.
    init?(key: String, server: ServerID) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let id = MediaID(server: server, rawValue: parts[1])
        switch parts[0] {
        case "album": self = .album(id)
        case "playlist": self = .playlist(id)
        case "artist": self = .artist(id)
        case "track": self = .track(id)
        default: return nil
        }
    }
}
