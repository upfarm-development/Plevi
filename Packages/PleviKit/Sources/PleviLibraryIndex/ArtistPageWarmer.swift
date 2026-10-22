import Foundation
import PleviDomain

/// Fetches an artist's biography, similar artists and top tracks and files them in the index —
/// deciding what may be written when a request fails.
public enum ArtistPageWarmer {
    public enum Outcome: Sendable, Equatable {
        /// Not attempted: the app is offline.
        case offline
        /// A fresh page is already stored.
        case alreadyFresh
        /// Every request that was made was answered; the page is stored fresh.
        case stored
        /// Some request failed. What did arrive is stored, merged with what
        /// was there, and the page is not marked fresh, so it is asked for again.
        case storedPartly
        /// Every request failed. Nothing was written.
        case failed
        /// The caller went away part-way. Nothing was written.
        case cancelled
    }

    /// `fetchInfo` / `fetchTopTracks` are `nil` where the server cannot supply
    /// them; that is a complete, empty answer rather than a failure.
    public static func warm(
        _ artist: MediaID,
        in index: LibraryIndex,
        isOffline: Bool,
        fetchInfo: (@Sendable () async throws -> ArtistInfo)?,
        fetchTopTracks: (@Sendable () async throws -> [Track])?
    ) async -> Outcome {
        if isOffline { return .offline }
        let cached = try? index.cachedArtistPage(for: artist)
        if let cached, !cached.isStale() { return .alreadyFresh }

        var biography: String?
        var similarIDs: [MediaID] = []
        var infoAnswered = true
        if let fetchInfo {
            do {
                let info = try await fetchInfo()
                biography = info.biography
                similarIDs = info.similarArtists.map(\.id)
            } catch {
                infoAnswered = isAnAnswer(error)
            }
        }

        var topTrackIDs: [MediaID] = []
        var topAnswered = true
        if let fetchTopTracks, !Task.isCancelled {
            do {
                topTrackIDs = try await fetchTopTracks().map(\.id)
            } catch {
                topAnswered = isAnAnswer(error)
            }
        }
        if Task.isCancelled { return .cancelled }

        let attempted = (fetchInfo != nil ? 1 : 0) + (fetchTopTracks != nil ? 1 : 0)
        let answered = (fetchInfo != nil && infoAnswered ? 1 : 0)
            + (fetchTopTracks != nil && topAnswered ? 1 : 0)
        if attempted > 0, answered == 0 { return .failed }

        if infoAnswered, topAnswered {
            // Only the identifiers are stored; the names and artwork come from
            // the library tables, which the sync keeps current.
            do {
                try index.storeArtistPage(
                    for: artist, biography: biography,
                    similarArtistIDs: similarIDs, topTrackIDs: topTrackIDs
                )
            } catch { return .failed }
            return .stored
        }

        do {
            try index.storeArtistPage(
                for: artist,
                biography: infoAnswered ? biography : cached?.biography,
                similarArtistIDs: infoAnswered ? similarIDs : cached?.similarArtists.map(\.id) ?? [],
                topTrackIDs: topAnswered ? topTrackIDs : cached?.topTracks.map(\.id) ?? [],
                // Keeps the old age, or none: either way it stays stale.
                fetchedAt: cached?.fetchedAt ?? .distantPast
            )
        } catch { return .failed }
        return .storedPartly
    }

    /// Whether an error is the server saying there is nothing (or that it
    /// cannot say), as opposed to the request not getting through.
    static func isAnAnswer(_ error: any Error) -> Bool {
        switch error as? ProviderError {
        case .notFound, .unsupportedOperation, .malformedResponse,
             .incompatibleServer, .missingParameter:
            true
        default:
            false
        }
    }
}
