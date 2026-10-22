import Foundation

/// One actual play, as opposed to the single "last played" date every provider already offers on a
/// `Track`.
public struct PlayHistoryEntry: Hashable, Sendable {
    public let trackID: MediaID
    /// The album this track belongs to, where the provider can say —
    /// absent for a track the library has since lost track of.
    public let albumID: MediaID?
    public let playedAt: Date

    public init(trackID: MediaID, albumID: MediaID?, playedAt: Date) {
        self.trackID = trackID
        self.albumID = albumID
        self.playedAt = playedAt
    }
}
