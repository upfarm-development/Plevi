import Foundation

/// A playlist that was made but did not get all of its songs.
public struct PartialPlaylistError: Error, LocalizedError, Sendable {
    public let playlist: Playlist
    public let added: Int
    public let total: Int
    public let underlying: any Error

    public var errorDescription: String? {
        let reason = (underlying as? LocalizedError)?.errorDescription
            ?? underlying.localizedDescription
        return "“\(playlist.name)” was made on the server with \(added) of \(total) songs. \(reason)"
    }
}

/// Writes a long playlist in batches.
public enum PlaylistBatching {
    /// Small enough for a proxy's request-line limit (an 8 KB one holds about
    /// 300 Plex keys), large enough that 10,000 songs is under seventy calls.
    public static let defaultBatchSize = 150

    public static func chunks(of ids: [MediaID], size: Int) -> [[MediaID]] {
        let size = max(1, size)
        guard !ids.isEmpty else { return [[]] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }

    public static func create(
        name: String,
        trackIDs: [MediaID],
        batchSize: Int = defaultBatchSize,
        make: (String, [MediaID]) async throws -> Playlist,
        add: (MediaID, [MediaID]) async throws -> Void
    ) async throws -> Playlist {
        let batches = chunks(of: trackIDs, size: batchSize)
        let created = try await make(name, batches[0])
        var added = batches[0].count
        for batch in batches.dropFirst() {
            do {
                try await add(created.id, batch)
                added += batch.count
            } catch {
                if error is CancellationError { throw error }
                throw PartialPlaylistError(
                    playlist: created, added: added, total: trackIDs.count, underlying: error
                )
            }
        }
        return created
    }
}

public extension MusicServerProvider {
    /// `createPlaylist`, but in batches so no single request carries every
    /// song. See `PlaylistBatching`.
    func createPlaylistInBatches(
        name: String,
        trackIDs: [MediaID],
        batchSize: Int = PlaylistBatching.defaultBatchSize
    ) async throws -> Playlist {
        try await PlaylistBatching.create(
            name: name, trackIDs: trackIDs, batchSize: batchSize,
            make: { try await createPlaylist(name: $0, trackIDs: $1) },
            add: { try await addToPlaylist(id: $0, trackIDs: $1) }
        )
    }
}
