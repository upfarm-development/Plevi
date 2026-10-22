import Foundation
import PleviDomain
import PleviLibraryIndex

/// Warms everything an artist page needs — biography, similar artists, top
/// tracks, and artwork — before the page is opened, and persists it so a
/// later visit paints complete rather than revealing sections one by one.
@MainActor
final class ArtistPrefetcher {
    private weak var app: AppModel?
    /// Artists whose page is known to be warm this session, so scrolling a
    /// list does not re-request the same artist repeatedly. Only filled once
    /// the page really is warm: a failure is not "handled".
    private var handled: Set<MediaID> = []
    /// When a fetch for an artist last failed, so scrolling back over the row
    /// does not ask again straight away on a link that has just refused.
    private var failedAt: [MediaID: Date] = [:]
    /// Row-driven warms in flight. A fling down a long list must not become
    /// a flood; a row that finds the lane full simply does not prefetch.
    private var running = 0

    private static let retryAfter: TimeInterval = 60
    /// How long a row must stay on screen before it is worth a request.
    private static let dwell = Duration.milliseconds(350)
    private static let concurrentLimit = 2

    init(app: AppModel) {
        self.app = app
    }

    /// For a row in a list: runs from the row's `.task`, so scrolling away cancels it before it
    /// asks for anything (or drops what it is waiting on).
    func prefetchWhenVisible(_ artist: Artist) async {
        guard worthAsking(about: artist) else { return }
        try? await Task.sleep(for: Self.dwell)
        guard !Task.isCancelled, worthAsking(about: artist),
              running < Self.concurrentLimit
        else { return }
        running += 1
        defer { running -= 1 }
        await warm(artist)
    }

    /// A hint that an artist is about to be wanted (an album was opened).
    func prefetch(_ artist: Artist) {
        guard worthAsking(about: artist) else { return }
        Task { [weak self] in
            await self?.warm(artist)
        }
    }

    private func worthAsking(about artist: Artist) -> Bool {
        guard let app, !app.isOffline, !handled.contains(artist.id) else { return false }
        if let failed = failedAt[artist.id], Date().timeIntervalSince(failed) < Self.retryAfter {
            return false
        }
        return true
    }

    /// Fetches and caches, unless a fresh copy is already stored. What may be
    /// written when a request fails is `ArtistPageWarmer`'s business.
    func warm(_ artist: Artist) async {
        guard let app,
              let provider = app.provider,
              let index = app.libraryIndex
        else { return }

        let id = artist.id
        var fetchInfo: (@Sendable () async throws -> ArtistInfo)?
        if provider.capabilities.contains(.artistInfo) {
            fetchInfo = { try await provider.artistInfo(id: id) }
        }
        var fetchTopTracks: (@Sendable () async throws -> [Track])?
        if provider.capabilities.contains(.topTracks) {
            fetchTopTracks = { try await provider.topTracks(forArtist: id, limit: 30) }
        }
        let outcome = await ArtistPageWarmer.warm(
            id, in: index, isOffline: app.isOffline,
            fetchInfo: fetchInfo, fetchTopTracks: fetchTopTracks
        )
        switch outcome {
        case .stored, .alreadyFresh:
            handled.insert(id)
            failedAt[id] = nil
            await prefetchArtwork(for: artist)
        case .storedPartly:
            failedAt[id] = Date()
            await prefetchArtwork(for: artist)
        case .failed:
            failedAt[id] = Date()
        case .offline, .cancelled:
            break
        }
    }

    /// Pulls artist artwork into the image cache at the sizes the page uses,
    /// so the header does not fade in after the text.
    private func prefetchArtwork(for artist: Artist) async {
        guard let loader = app?.artwork, let artwork = artist.artwork else { return }
        _ = await loader.image(for: artwork, bucket: 300)
        if app != nil, !Task.isCancelled {
            _ = await loader.image(for: artwork, bucket: 1200)
        }
    }
}
