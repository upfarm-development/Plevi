import Foundation
import Observation
import PleviDomain
import PleviLibraryIndex

/// The shelf of mixes, and what they hold today.
@MainActor
@Observable
final class MadeForYouStore {
    private(set) var mixes: [MadeForYou.Mix] = []

    private let defaults: UserDefaults
    /// The rotation the shelf on screen belongs to, and the library it was
    /// built from — switching libraries has to rebuild it, or a jazz library
    /// shows mixes made from a pop one.
    private var showing: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Moves the shelf on when a rotation has passed, and not otherwise.
    func refresh(
        index: LibraryIndex?,
        provider: (any MusicServerProvider)? = nil,
        offline: Bool = false,
        now: Date = .now
    ) async {
        guard let index else { return }
        let period = MadeForYou.rotationPeriod(for: now)
        let library = index.server.rawValue.uuidString
        let key = "\(period)|\(library)"
        guard key != showing else { return }
        // Not latched yet.

        let stored = defaults.data(forKey: Self.storeKey(library)).flatMap {
            try? JSONDecoder().decode(MadeForYou.Shelf.self, from: $0)
        }

        // Asked before anything is read out of the library, because on all
        // but the first look of a rotation the answer is yes.
        if MadeForYou.isUpToDate(stored, at: period), let stored {
            mixes = stored.mixes
            guard !stored.awaitingSonic.isEmpty else {
                showing = key
                forgetDead(library)
                return
            }
            // Stored, but not finished: finish it when the server can be
            // asked, and quietly wait otherwise.
            var dressed = stored.mixes
            let outcome = await nameArtists(
                in: &dressed, targets: Set(stored.awaitingSonic),
                index: index, provider: provider, offline: offline
            )
            guard !outcome.cancelled else { return }
            store(MadeForYou.Shelf(mixes: dressed, period: stored.period, awaitingSonic: outcome.deferred),
                  library: library)
            if outcome.deferred.isEmpty { showing = key }
            return
        }

        // Enough listening to see a month of it without reading the whole
        // history: the weighting has all but forgotten anything further back.
        let history = (try? index.recentlyPlayedForMixes(limit: 400)) ?? []
        // What the library is made of, so a genre mix can be told from a
        // shuffle of a third of everything before it is offered.
        let shape = (try? index.libraryShape()) ?? LibraryShape()

        let assembly = MadeForYou.assemble(
            stored: stored,
            candidates: MadeForYou.candidates(from: history, shape: shape),
            at: period
        )
        // Only what has just arrived is looked up; the rest brought its sleeves and names with it.
        var freshlyDressed = assembly.mixes.map { mix in
            assembly.newlyArrived.contains(mix.id) ? index.dressed(mix) : mix
        }
        mixes = freshlyDressed

        let outcome = await nameArtists(
            in: &freshlyDressed,
            targets: MadeForYou.sonicTargets(assembly: assembly, stored: stored),
            index: index, provider: provider, offline: offline
        )
        // Called off part way: nothing is stored and nothing is latched, so
        // the run that replaces this one does the whole job.
        guard !outcome.cancelled else { return }

        // The decorated set, not what is on screen — those are the same
        // unless the shelf rotated underneath this, and if it did, the fresh
        // one is what belongs in the store.
        store(MadeForYou.Shelf(mixes: freshlyDressed, period: period, awaitingSonic: outcome.deferred),
              library: library)
        if outcome.deferred.isEmpty { showing = key }
    }

    /// What `nameArtists` could not finish.
    private struct NamingOutcome {
        /// Artist mixes left wearing the local guess because the server
        /// could not be asked, or did not answer.
        var deferred: [String] = []
        var cancelled = false
    }

    /// When asking for similar tracks last failed, per library, so a shelf
    /// that re-runs on every connection flip does not repeat a failing
    /// request each time.
    private var namingFailures = FailureMemo(lifetime: 120)

    /// Looks up the server's own idea of who an artist mix sounds like, for the mixes in `targets`,
    /// writing the answers into `dressed` and onto the shelf on screen.
    private func nameArtists(
        in dressed: inout [MadeForYou.Mix],
        targets: Set<String>,
        index: LibraryIndex,
        provider: (any MusicServerProvider)?,
        offline: Bool
    ) async -> NamingOutcome {
        var outcome = NamingOutcome()
        let library = index.server.rawValue.uuidString
        for offset in dressed.indices {
            let mix = dressed[offset]
            guard targets.contains(mix.id),
                  case .artist(let name, _, let seeds) = mix.kind,
                  let seed = seeds.first
            else { continue }
            guard let provider, !offline, !namingFailures.isRemembered(library) else {
                outcome.deferred.append(mix.id)
                continue
            }
            switch await Self.sonicCompany(for: name, seed: seed, index: index, provider: provider) {
            case .cancelled:
                outcome.cancelled = true
                return outcome
            case .failed:
                namingFailures.note(library)
                outcome.deferred.append(mix.id)
            case .names(let sonic):
                namingFailures.forget(library)
                guard !sonic.isEmpty else { continue }
                dressed[offset].artists = sonic
                // Only while it is still this shelf on screen: the mixes rotate
                // at midnight and on a library switch, and an answer that arrives
                // after that belongs to a shelf nobody is looking at.
                guard mixes.count == dressed.count, mixes[offset].id == mix.id else { continue }
                mixes[offset].artists = sonic
            }
        }
        return outcome
    }

    private func store(_ shelf: MadeForYou.Shelf, library: String) {
        if let encoded = try? JSONEncoder().encode(shelf) {
            defaults.set(encoded, forKey: Self.storeKey(library))
        }
        forgetDead(library)
    }

    /// The same job as `company`, for an artist it has nothing to go on — asks the server what
    /// sounds like one of the mix's own seed tracks instead of comparing tags, and reads off
    /// whoever else turns up.
    private enum Sonic {
        /// The server answered; empty means it had nobody to name.
        case names([String])
        case failed
        case cancelled
    }

    private static func sonicCompany(
        for artist: String,
        seed: MediaID,
        index: LibraryIndex,
        provider: any MusicServerProvider,
        most: Int = 3
    ) async -> Sonic {
        let similar: [Track]
        switch await FetchOutcome.attempt({
            try await provider.similarTracks(to: seed, limit: SmartContinue.neighboursPerSeed)
        }) {
        case .answered(let tracks): similar = tracks
        case .cancelled: return .cancelled
        case .failed: return .failed
        }
        guard !similar.isEmpty else { return .names([]) }
        let eras = (try? index.activeEraByArtist()) ?? [:]
        let seedEra = eras[artist.lowercased()]
        var out: [String] = []
        var seen = Set<String>()
        for track in similar {
            guard let name = track.artistName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let key = name.lowercased()
            guard key != artist.lowercased(), !seen.contains(key) else { continue }
            guard EraAffinity.belongs(candidate: eras[key], withSeed: seedEra) else { continue }
            seen.insert(key)
            out.append(name)
            if out.count == most { break }
        }
        return .names(out)
    }

    /// The songs that start one of today's mixes.
    func seeds(for mix: MadeForYou.Mix, now: Date = .now) -> [MediaID] {
        MadeForYou.seeds(for: mix, dayOfYear: MadeForYou.dayOfYear(for: now))
    }

    /// Versioned, because what is stored here is a shelf of mixes and their shape has changed once
    /// already.
    // v3: mixes gained the artists they are made of and the several sleeves a genre is drawn with.
    private static let prefix = "home.madeForYou.v9."

    /// Every key this has ever used, so a format change leaves nothing
    /// behind in the preferences.
    private static let allPrefixes = [
        "home.madeForYou.v7.",
        "home.madeForYou.v8.",
        "home.madeForYou.",
        "home.madeForYou.v2.",
        "home.madeForYou.v3.",
        "home.madeForYou.v4.",
        "home.madeForYou.v5.",
        "home.madeForYou.v6.",
    ]

    private static func storeKey(_ library: String) -> String { "\(prefix)\(library)" }

    /// Drops every older format, and of the current one the libraries beyond the few most recently
    /// used — so a year of weekly keys written by an earlier version does not sit in the
    /// preferences, while switching to another library no longer…
    private func forgetDead(_ library: String) {
        for stored in defaults.dictionaryRepresentation().keys
        where Self.allPrefixes.contains(where: stored.hasPrefix) && !stored.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: stored)
        }
        ShelfCachePruning.prune(
            defaults, prefix: Self.prefix, recentKey: Self.recentKey,
            currentLibrary: library, currentPeriod: ""
        ) { (library: $0, period: "") }
    }

    /// Outside `prefix`, so it is never mistaken for a stored shelf.
    private static let recentKey = "home.shelfLibraries.madeForYou"
}
