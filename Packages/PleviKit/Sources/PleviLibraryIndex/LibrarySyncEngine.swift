import Foundation
import PleviDomain

/// Pulls the full library from a provider into a `LibraryIndex`.
public actor LibrarySyncEngine {
    public struct Summary: Sendable {
        /// What the walk itself fetched — zero on a sync that was skipped.
        /// The library's own totals are `LibraryIndex.stats()`, and anything
        /// that means "how big is the library" should ask that instead.
        public let artists: Int
        public let albums: Int
        public let tracks: Int
        public let duration: TimeInterval
        public let outcome: Outcome

        public init(
            artists: Int,
            albums: Int,
            tracks: Int,
            duration: TimeInterval,
            outcome: Outcome = .walked
        ) {
            self.artists = artists
            self.albums = albums
            self.tracks = tracks
            self.duration = duration
            self.outcome = outcome
        }

        public enum Outcome: Sendable, Equatable {
            /// The library was walked and rows it did not see were removed.
            case walked
            /// The library was walked, but it came back with far less than
            /// the server says it holds, so nothing was deleted. What did
            /// arrive was kept and the next sync tries again.
            case shortWalk
            /// The server was asked whether anything had changed and said
            /// no, so nothing was fetched at all.
            case unchanged
        }
    }

    public enum Phase: Sendable, Equatable {
        case artists
        case albums(count: Int)
        case tracks(count: Int)
        case finishing
    }

    private let provider: any MusicServerProvider
    private let index: LibraryIndex
    private var running = false
    /// How long each further attempt at one page waits, in order. Two
    /// retries: a page that fails three times running is not blinking.
    private let pageRetryDelays: [Duration]

    private static let pageSize = 500

    /// How many track pages are in the air at once.
    private static let pagesAtOnce = 4

    /// How much of what the server says it holds has to arrive before the walk is trusted to say
    /// what is gone.
    private static let minimumShareToPrune = 0.9

    /// The longest a sync may go on skipping before it walks anyway.
    private static let longestGapBetweenWalks: TimeInterval = 6 * 60 * 60

    public init(
        provider: any MusicServerProvider,
        index: LibraryIndex,
        pageRetryDelays: [Duration] = LibrarySyncEngine.defaultPageRetryDelays
    ) {
        self.provider = provider
        self.index = index
        self.pageRetryDelays = pageRetryDelays
    }

    public static let defaultPageRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    /// Asks for one page, and once or twice more if the network flinched.
    static func page<T: Sendable>(
        retryingAfter delays: [Duration],
        _ request: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await request()
            } catch {
                guard attempt < delays.count, isWorthAskingAgain(error) else { throw error }
                try await Task.sleep(for: delays[attempt])
                attempt += 1
            }
        }
    }

    static func isWorthAskingAgain(_ error: any Error) -> Bool {
        guard let error = error as? ProviderError else { return false }
        if error.isWorthRetrying { return true }
        if case .serverError(let code, _, _) = error, let code {
            return code == 502 || code == 503 || code == 504
        }
        return false
    }

    /// Whether a walk would do anything, asked without starting one.
    public func walkIsDue() async -> Bool? {
        guard let token = try? await provider.libraryChangeToken() else { return nil }
        guard let skips = try? skipsWalk(token: token) else { return nil }
        return !skips
    }

    /// - Parameter force: walk even if the server says nothing has changed.
    @discardableResult
    public func fullSync(
        force: Bool = false,
        onPhase: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> Summary {
        // A second concurrent call would double-fetch; just serialize.
        while running {
            try await Task.sleep(for: .milliseconds(200))
        }
        running = true
        defer { running = false }

        let started = Date()

        // Read before anything else, and stored only at the end: a library that changes while the
        // walk is running leaves the token it was fetched under stale, so the next sync walks again
        // rather than taking a change it never saw as already seen.
        let token = try? await provider.libraryChangeToken()

        if !force, let token, try skipsWalk(token: token) {
            try index.noteLibraryUnchanged()
            return Summary(
                artists: 0,
                albums: 0,
                tracks: 0,
                duration: Date().timeIntervalSince(started),
                outcome: .unchanged
            )
        }

        let generation = try index.beginSyncGeneration()

        onPhase?(.artists)
        let provider = self.provider
        let delays = pageRetryDelays
        let artists = try await Self.page(retryingAfter: delays) { try await provider.artists() }
        try index.upsertArtists(artists, generation: generation)

        // What the server says it holds, for the walk to check itself against at the end.
        let counts = (try? await provider.libraryCounts()) ?? LibraryCounts()

        // Paged by what was *asked for*, not by what came back, and carried on until a page is
        // empty rather than until one is short.
        var albumCount = 0
        var albumOffset = 0
        while true {
            let offset = albumOffset
            let page = try await Self.page(retryingAfter: delays) {
                try await provider.albums(
                    filter: .alphabeticalByName,
                    offset: offset,
                    limit: Self.pageSize
                )
            }
            guard !page.isEmpty else { break }
            try index.upsertAlbums(page, generation: generation)
            albumCount += page.count
            albumOffset += Self.pageSize
            onPhase?(.albums(count: albumCount))
        }

        var trackCount = 0
        var trackOffset = 0
        var hasLookedPastTheCount = false
        walking: while true {
            let width = waveWidth(
                from: trackOffset,
                of: counts.tracks,
                hasLookedPastTheCount: hasLookedPastTheCount
            )
            if let total = counts.tracks, trackOffset >= total { hasLookedPastTheCount = true }
            let wave = try await trackWave(from: trackOffset, width: width)
            for page in wave {
                // Still the only thing that ends the walk.
                guard !page.tracks.isEmpty else { break walking }
                // Written here rather than inside the group: the writer is one thread whichever way
                // it is done, and a page that blocks on it from inside a task group blocks one of
                // the pool's threads with it.
                try index.upsertTracks(page.tracks, generation: generation)
                trackCount += page.tracks.count
                onPhase?(.tracks(count: trackCount))
            }
            trackOffset += Self.pageSize * wave.count
        }

        if trackCount == 0, albumCount > 0 {
            // Server ignores the empty-query sync contract; walk albums.
            var offset = 0
            while true {
                let pageOffset = offset
                let albums = try await Self.page(retryingAfter: delays) {
                    try await provider.albums(
                        filter: .alphabeticalByName,
                        offset: pageOffset,
                        limit: Self.pageSize
                    )
                }
                guard !albums.isEmpty else { break }
                for album in albums {
                    let detail = try await Self.page(retryingAfter: delays) {
                        try await provider.album(id: album.id)
                    }
                    try index.upsertTracks(detail.tracks, generation: generation)
                    trackCount += detail.tracks.count
                }
                onPhase?(.tracks(count: trackCount))
                offset += Self.pageSize
            }
        }

        onPhase?(.finishing)
        // Judged after the album walk above, not before it: on a server that ignores the empty
        // query the track loop legitimately comes back with nothing, and everything the library has
        // arrives in the fallback.
        let judgement = judge(
            counts: counts,
            artists: artists.count,
            albums: albumCount,
            tracks: trackCount
        )
        try index.finishSync(
            generation: generation,
            pruning: judgement.mayPrune,
            // A token is a promise that the next sync may skip the library entirely, and only a
            // walk the server's own numbers corroborate is allowed to make it.
            changeToken: judgement.mayVouch ? token : nil
        )

        return Summary(
            artists: artists.count,
            albums: albumCount,
            tracks: trackCount,
            duration: Date().timeIntervalSince(started),
            outcome: judgement.mayPrune ? .walked : .shortWalk
        )
    }

    /// Whether the server's answer means there is nothing to do.
    private func skipsWalk(token: String) throws -> Bool {
        let checkpoint = try index.checkpoint()
        guard checkpoint.changeToken == token else { return false }
        guard let lastFull = checkpoint.lastFullSyncAt else { return false }
        // Both ends of the window, because the interval is signed and the date came from this
        // device's own clock.
        return (0..<Self.longestGapBetweenWalks)
            .contains(Date().timeIntervalSince(lastFull))
    }

    /// How many pages the next wave should ask for.
    private func waveWidth(from offset: Int, of total: Int?, hasLookedPastTheCount: Bool) -> Int {
        guard let total else { return Self.pagesAtOnce }
        guard offset < total else { return hasLookedPastTheCount ? Self.pagesAtOnce : 1 }
        return min(
            Self.pagesAtOnce,
            max(1, Int((Double(total - offset) / Double(Self.pageSize)).rounded(.up)))
        )
    }

    /// One wave of track pages, fetched together and handed back in order.
    private func trackWave(
        from offset: Int,
        width: Int
    ) async throws -> [(offset: Int, tracks: [Track])] {
        let provider = self.provider
        let pageSize = Self.pageSize
        let delays = pageRetryDelays
        return try await withThrowingTaskGroup(
            of: (offset: Int, tracks: [Track]).self
        ) { group in
            for page in 0..<width {
                let pageOffset = offset + page * pageSize
                group.addTask {
                    let tracks = try await Self.page(retryingAfter: delays) {
                        try await provider.tracks(offset: pageOffset, limit: pageSize)
                    }
                    return (offset: pageOffset, tracks: tracks)
                }
            }
            var pages: [(offset: Int, tracks: [Track])] = []
            for try await page in group { pages.append(page) }
            return pages.sorted { $0.offset < $1.offset }
        }
    }

    /// What the walk is allowed to do with what it collected.
    private struct Judgement {
        let mayPrune: Bool
        let mayVouch: Bool
    }

    /// Anything the server did not count is not judged: a nil is "it did not
    /// say", never "it said none".
    private func judge(
        counts: LibraryCounts,
        artists: Int,
        albums: Int,
        tracks: Int
    ) -> Judgement {
        func enough(_ walked: Int, _ reported: Int?) -> Bool {
            guard let reported, reported > 0 else { return true }
            return Double(walked) >= Double(reported) * Self.minimumShareToPrune
        }
        // A server that says it is scanning is a server whose numbers are
        // moving under the walk, and whose library is too.
        guard !counts.isRescanning else { return Judgement(mayPrune: false, mayVouch: false) }
        let matches = enough(artists, counts.artists)
            && enough(albums, counts.albums)
            && enough(tracks, counts.tracks)
        // Vouching turns on the song count and no other, because the songs are the part of the walk
        // a token would let the next sync skip.
        let songsWereCounted = (counts.tracks ?? 0) > 0
        return Judgement(mayPrune: matches, mayVouch: matches && songsWereCounted)
    }
}
