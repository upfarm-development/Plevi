import Foundation
import Observation
import PleviDomain
import PleviLibraryIndex

/// This week's artist, and the five albums they are being shown for.
@MainActor
@Observable
final class SpotlightStore {
    private(set) var artist: Artist?
    /// The five albums this week's artist is being shown for, best rated
    /// first — the same set the pick was actually judged on.
    private(set) var albums: [Album] = []
    private(set) var bio: String?
    /// How many albums this artist has in the library — asked of the index
    /// directly rather than read off `Artist.albumCount`, which Plex leaves
    /// null on every artist its bulk library listing hands back.
    private(set) var libraryAlbumCount: Int?

    private let defaults: UserDefaults
    /// The week and library the thing on screen belongs to.
    private var showing: String?

    /// A candidate with nothing written about them is skipped for one that has something to say,
    /// rather than a card with a blank where the bio hook belongs — bounded, so a library that
    /// genuinely has no biographies anywhere does not spend forever…
    private static let bioAttemptLimit = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func refresh(
        index: LibraryIndex?,
        provider: (any MusicServerProvider)?,
        capabilities: ServerCapabilities,
        now: Date = .now
    ) async {
        guard let index else { clear(); return }
        let week = Spotlight.weekNumber(for: now)
        let library = index.server.rawValue.uuidString
        let key = "\(week)|\(library)"
        guard key != showing else { return }

        if let stored = weeklyPick(for: key), apply(stored, index: index) {
            showing = key
            return
        }

        // Plex's critic score where the server keeps one; a listener's own
        // stars where it does not — `Spotlight.pick` needs to know which,
        // since the two floors live on different scales.
        let usingCriticRating = capabilities.contains(.criticRatings)
        let grouped = (try? index.topRatedAlbumsByArtist(usingCriticRating: usingCriticRating)) ?? [:]
        var pool = grouped.map { Spotlight.Candidate(artistName: $0.key, topAlbums: $0.value) }
        guard !pool.isEmpty else {
            clear()
            showing = nil
            return
        }

        let allHistory = history(for: library)
        // All of it, not only the rest window: the draw leans away from
        // anyone who has been featured often, however long ago.
        let recentlyShown = allHistory
            .map { Spotlight.Appearance(artistName: $0.artistName, week: $0.week) }

        var winner: (candidate: Spotlight.Candidate, artist: Artist, bio: String)?
        // Whether a better-ranked candidate was passed over only because
        // the server could not be asked — no provider yet on a cold launch,
        // a request that failed — rather than because it has no biography.
        var passedOverForUncertainty = false
        for _ in 0..<Self.bioAttemptLimit {
            guard let candidate = Spotlight.pick(
                for: week, from: pool, usingCriticRating: usingCriticRating, recentlyShown: recentlyShown
            ) else { break }
            let resolvedArtist = try? index.artist(named: candidate.artistName)
            var found: String?
            if let resolvedArtist {
                switch await usableBiography(
                    for: resolvedArtist, index: index, provider: provider, hold: library
                ) {
                case .bio(let text): found = text
                case .none: break
                case .unknown: passedOverForUncertainty = true
                case .cancelled: return
                }
            }
            guard let resolvedArtist, let bioText = found else {
                // Removed from the pool being picked from, not added to `recentlyShown` — an
                // appearance stamped with this same week would read as this week's own settled
                // pick, which `Spotlight.pick` deliberately never treats as resting.
                pool.removeAll { $0.artistName == candidate.artistName }
                continue
            }
            winner = (candidate, resolvedArtist, bioText)
            break
        }

        guard let winner else {
            clear()
            // Deliberately not stamped as shown: a library that gains a
            // biography or a well-rated album this afternoon should get a
            // card this afternoon rather than next week.
            showing = nil
            return
        }

        artist = winner.artist
        albums = winner.candidate.topAlbums
        bio = winner.bio
        libraryAlbumCount = (try? index.albums(forArtist: winner.artist.id).count)
        // A winner chosen while a better candidate could not be checked is a stand-in: shown, but
        // neither stored nor entered in the history, and the key left open so the pick is made
        // again when the server can be asked.
        guard !passedOverForUncertainty else {
            showing = nil
            return
        }
        showing = key
        remember(winner.artist, week: week, for: library)
        persist(winner.artist, albums: winner.candidate.topAlbums, for: key)
    }

    private func clear() {
        artist = nil
        albums = []
        bio = nil
        libraryAlbumCount = nil
    }

    /// The library's own cached copy where there is a usable one; a live fetch otherwise, cached
    /// for next time.
    private enum Biography {
        case bio(String)
        case none
        case unknown
        case cancelled
    }

    /// When asking for a biography last failed, per library, so a shelf that
    /// re-runs on every connection flip does not repeat failing requests.
    private var failures = FailureMemo(lifetime: 120)

    private func usableBiography(
        for artist: Artist, index: LibraryIndex, provider: (any MusicServerProvider)?, hold: String
    ) async -> Biography {
        let existing = try? index.cachedArtistPage(for: artist.id)
        if let bio = existing?.biography, !bio.isEmpty { return .bio(bio) }

        guard let provider else { return .unknown }
        guard provider.capabilities.contains(.artistInfo) else { return .none }
        guard !failures.isRemembered(hold) else { return .unknown }
        let info: ArtistInfo
        switch await FetchOutcome.attempt({ try await provider.artistInfo(id: artist.id) }) {
        case .answered(let answered): info = answered
        case .cancelled: return .cancelled
        case .failed:
            failures.note(hold)
            return .unknown
        }
        guard let bio = info.biography, !bio.isEmpty else { return .none }

        // Read again, not the `existing` from before the request above: `ArtistPrefetcher` runs on
        // the same actor and could have written a fuller page — similar artists, top tracks — while
        // this one was waiting on the network.
        let fresh = try? index.cachedArtistPage(for: artist.id)
        try? index.storeArtistPage(
            for: artist.id,
            biography: bio,
            similarArtistIDs: info.similarArtists.isEmpty
                ? (fresh?.similarArtists.map(\.id) ?? [])
                : info.similarArtists.map(\.id),
            topTrackIDs: fresh?.topTracks.map(\.id) ?? []
        )
        return .bio(bio)
    }

    // MARK: This week's pick, cached

    private struct WeeklyPick: Codable {
        let artistID: String
        let albumIDs: [String]
    }

    /// Reapplies a stored pick, re-reading the artist and albums fresh from the library rather than
    /// trusting a week-old snapshot of their names or sleeves.
    @discardableResult
    private func apply(_ stored: WeeklyPick, index: LibraryIndex) -> Bool {
        guard let resolvedArtist = try? index.artist(id: MediaID(server: index.server, rawValue: stored.artistID))
        else { return false }
        let resolvedAlbums = stored.albumIDs.compactMap {
            try? index.album(id: MediaID(server: index.server, rawValue: $0))
        }
        guard resolvedAlbums.count == stored.albumIDs.count,
              let resolvedBio = (try? index.cachedArtistPage(for: resolvedArtist.id))?.biography,
              !resolvedBio.isEmpty
        else { return false }
        artist = resolvedArtist
        albums = resolvedAlbums
        bio = resolvedBio
        libraryAlbumCount = (try? index.albums(forArtist: resolvedArtist.id).count)
        return true
    }

    private func weeklyPick(for key: String) -> WeeklyPick? {
        guard let data = defaults.data(forKey: Self.weeklyPrefix + key) else { return nil }
        return try? JSONDecoder().decode(WeeklyPick.self, from: data)
    }

    private func persist(_ artist: Artist, albums: [Album], for key: String) {
        let pick = WeeklyPick(artistID: artist.id.rawValue, albumIDs: albums.map(\.id.rawValue))
        guard let encoded = try? JSONEncoder().encode(pick) else { return }
        defaults.set(encoded, forKey: Self.weeklyPrefix + key)
        forgetDeadPicks(key)
    }

    private static let weeklyPrefix = "home.spotlight.week.v1."

    /// Earlier weeks of the library on show, and libraries beyond the few
    /// most recently used. Another library's pick is kept, so switching
    /// back to it does not redraw who it was showing this week.
    private func forgetDeadPicks(_ key: String) {
        guard let current = Self.parts(of: key) else { return }
        ShelfCachePruning.prune(
            defaults, prefix: Self.weeklyPrefix, recentKey: Self.recentKey,
            currentLibrary: current.library, currentPeriod: current.period,
            parse: Self.parts(of:)
        )
    }

    /// `"<week>|<library id>"`.
    private static func parts(of key: String) -> (library: String, period: String)? {
        let pieces = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return nil }
        return (library: pieces[1], period: pieces[0])
    }

    /// Outside `weeklyPrefix`, so it is never mistaken for a stored pick.
    private static let recentKey = "home.shelfLibraries.spotlight"

    // MARK: Rotation history — also what powers the Archive screen

    struct HistoryEntry: Codable, Hashable, Identifiable {
        let artistID: String
        let artistName: String
        let week: Int

        var id: String { "\(artistID)|\(week)" }
    }

    /// Every past pick this library has kept, most recent first — used both
    /// to decide who is resting (`refresh`, filtered to the last
    /// `Spotlight.restWeeks`) and to draw the Archive screen (unfiltered).
    func history(for library: String) -> [HistoryEntry] {
        guard let data = defaults.data(forKey: Self.historyKey(library)),
              let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] }
        return saved.sorted { $0.week > $1.week }
    }

    private func remember(_ artist: Artist, week: Int, for library: String) {
        var saved = history(for: library)
        // One entry per week: reopening the app on Tuesday is not a second
        // appearance.
        saved.removeAll { $0.week == week }
        saved.append(HistoryEntry(artistID: artist.id.rawValue, artistName: artist.name, week: week))
        // Kept far longer than the rest needs on its own: the draw counts how often each artist has
        // been featured, and the Archive is a record of what has been shown.
        let tenYearsOfWeeks = 520
        saved.removeAll { Spotlight.weeksElapsed(from: $0.week, to: week) > tenYearsOfWeeks }
        guard let encoded = try? JSONEncoder().encode(saved) else { return }
        defaults.set(encoded, forKey: Self.historyKey(library))
    }

    private static func historyKey(_ library: String) -> String {
        "home.spotlight.history.v1.\(library)"
    }
}
