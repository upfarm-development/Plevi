import Foundation

/// Which songs on a record stand out enough to mark, by the audience's own numbers rather than this
/// listener's.
public enum HotTracks {
    /// How many to mark.
    static let marked = 3

    /// Fewer measured songs than this and there is nothing to rank: marking
    /// three of three is marking the record, which points at nothing.
    static let minimumMeasured = marked + 1

    /// The ids of the record's standout songs, or empty when it has none.
    public static func ids(in tracks: [Track], releaseType: ReleaseType) -> Set<MediaID> {
        guard releaseType != .single else { return [] }

        let measured = tracks.compactMap { track in
            track.popularity.flatMap { $0 > 0 ? (id: track.id, popularity: $0) : nil }
        }
        guard measured.count >= minimumMeasured else { return [] }

        let ranked = measured.sorted { $0.popularity > $1.popularity }
        return Set(ranked.prefix(marked).map(\.id))
    }
}
