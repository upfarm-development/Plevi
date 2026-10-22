import Foundation

/// Identifies a configured server. Generated locally at setup time and stable
/// across launches; all media identifiers carry the owning server's ID so
/// objects from different servers can never be confused.
public struct ServerID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

/// A server-native identifier for a media object, opaque to the app.
public struct MediaID: Hashable, Sendable, Codable {
    public let server: ServerID
    public let rawValue: String

    public init(server: ServerID, rawValue: String) {
        self.server = server
        self.rawValue = rawValue
    }
}

/// Identifies a piece of cover art. Kept distinct from `MediaID` because
/// OpenSubsonic treats cover-art IDs as their own namespace, separate from the
/// song/album/artist that references them.
public struct ArtworkID: Hashable, Sendable, Codable {
    public let server: ServerID
    public let rawValue: String

    public init(server: ServerID, rawValue: String) {
        self.server = server
        self.rawValue = rawValue
    }
}

/// Identifies one entry (row) of a playlist independently of the track it contains, so duplicate
/// tracks and reorders are unambiguous.
public struct PlaylistEntryID: Hashable, Sendable, Codable {
    public let server: ServerID
    public let rawValue: String

    public init(server: ServerID, rawValue: String) {
        self.server = server
        self.rawValue = rawValue
    }
}

/// The kind of object a state change (favorite, rating) applies to.
public enum MediaKind: String, Hashable, Sendable, Codable, CaseIterable {
    case artist
    case album
    case track
    case playlist
    case genre
}
