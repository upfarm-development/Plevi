import Foundation

/// A set someone put together on the server: "Christmas", "Desert Island", "Live Albums".
public struct MediaCollection: Hashable, Sendable, Identifiable {
    /// What the collection is made of. A music library can hold both.
    public enum Kind: String, Sendable, Codable {
        case albums
        case artists
    }

    public let id: MediaID
    public var name: String
    public var kind: Kind
    /// How many things are in it, when the server says.
    public var itemCount: Int?
    public var artwork: ArtworkID?

    public init(
        id: MediaID,
        name: String,
        kind: Kind,
        itemCount: Int? = nil,
        artwork: ArtworkID? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.itemCount = itemCount
        self.artwork = artwork
    }
}
