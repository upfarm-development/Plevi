import Foundation
import Observation
import PleviDomain
import PleviLibraryIndex

/// The albums behind the "Most Listened" shelf, and the month they were actually played in.
@MainActor
@Observable
final class MostListenedStore {
    private(set) var albums: [Album] = []
    private(set) var monthName: String = ""
    private(set) var totalSeconds: [MediaID: TimeInterval] = [:]
    /// What the last real attempt actually found, once there was one to report on — not for a
    /// provider that was not ready yet, or one that simply does not support this, both of which are
    /// ordinary and silent.
    private(set) var diagnostic: String?
    /// Whether the current `diagnostic` has already been handed to a caller.
    private var diagnosticShown = false

    private let defaults: UserDefaults
    /// The month and library on show, so a phone still open when the month
    /// turns over asks again, and so does a switch to another library.
    private var showing: String?
    /// When asking for a month's plays last failed, per month and library.
    private var failures = FailureMemo(lifetime: 300)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A finished month's ranking, once it has actually been worked out, is asked for again only if
    /// it was never computed at all — the network read is skipped entirely on every visit after the
    /// first, the same way `RediscoverStore` reads its own…
    func refresh(
        index: LibraryIndex?, provider: (any MusicServerProvider)?, offline: Bool,
        userInitiated: Bool = false, now: Date = .now
    ) async {
        guard let index else { albums = []; return }
        let month = MostListened.targetMonth(from: now)
        monthName = MostListened.monthName(for: month)
        let key = "\(Int(month.start.timeIntervalSince1970))|\(index.server.rawValue.uuidString)"
        guard key != showing else { return }
        // Still pausing after a failed attempt at this same month. What that
        // attempt had to say is still in `diagnostic`, already handed on.
        if !userInitiated, failures.isRemembered(key) { return }
        // A fresh month or library is a fresh attempt — whatever the last
        // one had to say does not belong to this one.
        diagnostic = nil
        diagnosticShown = false

        if let kept = storedRanking(for: key, server: index.server) {
            showing = key
            apply(kept, index: index)
            // Looking at a library is what keeps it among the recent ones.
            forgetDead(key)
            return
        }

        // Not marked as shown until a provider has actually answered — one that has not finished
        // connecting yet looks identical here to one that will never support this, and only the
        // second is worth remembering.
        guard let provider else { return }
        // Being offline is the same kind of "not ready yet" as no provider at all — a launch before
        // connectivity settles, Offline Mode toggled on, a server blip — and deserves the same
        // treatment: locking the key here would mean the one call that…
        guard !offline else { albums = []; return }
        guard provider.capabilities.contains(.playHistory) else {
            // Definitive: this server cannot say, and never will.
            showing = key
            albums = []
            return
        }
        // Generous, not exhaustive — a genuinely enormous month is capped
        // rather than left to page indefinitely, the same backstop
        // `playHistory` itself documents.
        let history: [PlayHistoryEntry]
        switch await FetchOutcome.attempt({
            try await provider.playHistory(from: month.start, to: month.end, limit: 20_000)
        }) {
        case .answered(let plays):
            history = plays
            failures.forget(key)
        case .cancelled:
            // A shelf key that moved on, or a view that went away: nothing
            // was learned, nothing is latched, and the restarted call asks
            // again. Not worth a message, and the shelf is left as it was.
            return
        case .failed(let message):
            albums = []
            // Not latched: a blip says nothing about this month, and locking
            // the key would keep the shelf empty until the month turned
            // over. Retried after a pause instead.
            failures.note(key)
            diagnostic = "Couldn't read \(monthName)'s plays: \(message)"
            return
        }
        // Only now is there an answer about this month and library.
        showing = key
        guard !history.isEmpty else {
            albums = []
            diagnostic = "Nothing played in \(monthName)."
            return
        }
        let durations = (try? index.durations(forTrackIDs: Array(Set(history.map(\.trackID))))) ?? [:]
        let ranked = MostListened.rank(history, durations: durations, within: month)
        guard !ranked.isEmpty else {
            albums = []
            // A real gap between what the server reported and what could actually be used — the
            // server named plays this could not tie back to an album or a known duration for every
            // single one of them, not merely a quiet month.
            diagnostic = "Found \(history.count.counted("play")) in \(monthName), "
                + "but couldn't match any to an album or a known song length."
            return
        }
        apply(ranked, index: index)
        persist(ranked, for: key)
    }

    /// `diagnostic`, the first time it is asked for after being set — nil every time after, even
    /// though the property itself keeps its value for the rest of the month.
    func consumeDiagnosticIfNew() -> String? {
        guard let diagnostic, !diagnosticShown else { return nil }
        diagnosticShown = true
        return diagnostic
    }

    private func apply(_ ranked: [(albumID: MediaID, totalSeconds: TimeInterval)], index: LibraryIndex) {
        totalSeconds = Dictionary(uniqueKeysWithValues: ranked.map { ($0.albumID, $0.totalSeconds) })
        // An album can vanish from the library between the month that
        // played it and now — deleted, moved off the server. Left out
        // rather than shown as a gap where a sleeve should be.
        albums = ranked.compactMap { try? index.album(id: $0.albumID) }
    }

    // MARK: Persistence

    private struct StoredEntry: Codable {
        let albumID: String
        let totalSeconds: TimeInterval
    }

    private static let prefix = "home.mostListened."

    private func storedRanking(
        for key: String, server: ServerID
    ) -> [(albumID: MediaID, totalSeconds: TimeInterval)]? {
        guard let data = defaults.data(forKey: Self.prefix + key),
              let entries = try? JSONDecoder().decode([StoredEntry].self, from: data),
              !entries.isEmpty
        else { return nil }
        return entries.map { (MediaID(server: server, rawValue: $0.albumID), $0.totalSeconds) }
    }

    private func persist(_ ranked: [(albumID: MediaID, totalSeconds: TimeInterval)], for key: String) {
        let entries = ranked.map { StoredEntry(albumID: $0.albumID.rawValue, totalSeconds: $0.totalSeconds) }
        guard let encoded = try? JSONEncoder().encode(entries) else { return }
        defaults.set(encoded, forKey: Self.prefix + key)
        forgetDead(key)
    }

    /// Earlier months of the library on show, and libraries beyond the few
    /// most recently used. A month is kept for every other library, so
    /// switching back to one does not ask the server all over again.
    private func forgetDead(_ key: String) {
        guard let current = Self.parts(of: key) else { return }
        ShelfCachePruning.prune(
            defaults, prefix: Self.prefix, recentKey: Self.recentKey,
            currentLibrary: current.library, currentPeriod: current.period,
            parse: Self.parts(of:)
        )
    }

    /// `"<month start>|<library id>"`.
    private static func parts(of key: String) -> (library: String, period: String)? {
        let pieces = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return nil }
        return (library: pieces[1], period: pieces[0])
    }

    /// Outside `prefix`, so it is never mistaken for a stored ranking.
    private static let recentKey = "home.shelfLibraries.mostListened"
}
