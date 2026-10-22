import Foundation
import Observation
import PleviDomain
import PleviLibraryIndex

/// The records that came out on today's date and have something written about them.
@MainActor
@Observable
final class OnThisDayStore {
    private(set) var entries: [OnThisDayEntry] = []

    /// Whether more cards may still arrive.
    private(set) var isFilling = false

    /// How many records the carousel holds.
    private static let cardCount = 10

    /// How many records are considered to find those ten.
    private static let candidateCount = 60

    /// The most reviews asked for in one refresh.
    private static let maximumRequests = 25

    /// Today's records, in the order the shelf would draw them — including
    /// the ones with nothing written about them, which is why it is not the
    /// same list as `entries`.
    private var candidates: [Album] = []

    /// Reviews already fetched this session, so scrolling back to Home does not ask again.
    private static var reviews = ReviewLedger()

    /// When asking for reviews last failed, so a shelf that re-runs on every
    /// sync or connection flip does not put the same failing requests out
    /// each time.
    private static var failures = FailureMemo(lifetime: 60)

    /// Failed requests in one pass before it gives up: a dead link would
    /// otherwise spend the whole budget on timeouts.
    private static let failureLimit = 3

    /// The day *and library* on show, so a phone left open past midnight refreshes — and so does a
    /// switch to another library.
    private var showing: String?

    /// Bumped on every call, so a call that SwiftUI has since cancelled and replaced can tell it is
    /// no longer the current one.
    private var generation = 0

    func refresh(index: LibraryIndex?, provider: (any MusicServerProvider)?, offline: Bool) async {
        guard let index else { return }
        let today = Calendar.current.dateComponents([.month, .day], from: Date())
        guard let month = today.month, let day = today.day else { return }
        let key = "\(month)-\(day)|\(index.server.rawValue.uuidString)"

        generation += 1
        let mine = generation
        isFilling = true
        defer { if generation == mine { isFilling = false } }

        if key != showing || entries.isEmpty {
            showing = key
            // A date the server invents to stand in for "only the year is known" collects records
            // that were not released on it — see `LibraryIndex.ReleaseDay`.
            let shape = try? index.releaseDay(month: month, day: day)
            if shape?.isPlaceholder == true {
                entries = []
                return
            }
            candidates = (try? index.albumsReleased(
                month: month, day: day, limit: Self.candidateCount
            )) ?? []
            // The review the shelf needs is very often already here.
            //
            // On Plex `album.review` and `albumInfo(id:).notes` are the same
            // field — the sync writes `summary` into the column, and the
            // request reads `summary` back one record at a time. So this
            // shelf was going to the server for a string the index had
            // already stored, which is why it arrived half a second after
            // everything around it and shoved the page down as it landed.
            // Editors' Choice has always read the column.
            //
            // Only what is really there: a nil column is "nobody has said",
            // not "there is no review". Writing an empty string for one would
            // mark the record unreviewed for the rest of the session, and on
            // a Subsonic server — where the sync never fills this column and
            // the notes come from somewhere else entirely — it would empty
            // the shelf permanently.
            for album in candidates {
                Self.reviews.noteStored(album.review, for: album.id)
            }
            // Whatever is already known to have a review can be drawn at
            // once; the rest are asked about below and appear as they answer.
            entries = candidates.compactMap(Self.knownEntry).prefix(Self.cardCount).map { $0 }
        }

        // Offline there is nobody to ask; the cards stand on their sleeves.
        guard !offline, let provider,
              provider.capabilities.contains(.albumInfo)
        else { return }

        var asked = 0
        var failed = 0
        let holdKey = index.server.rawValue.uuidString
        for album in candidates {
            guard !Task.isCancelled, generation == mine else { return }
            guard entries.count < Self.cardCount else { break }
            let albumKey = album.id.rawValue

            // Already answered for. A review means it belongs on the shelf if
            // it is not there already; no review means it never will be.
            if let known = Self.reviews.review(for: album.id) {
                if !known.isEmpty, !entries.contains(where: { $0.id == albumKey }) {
                    entries.append(OnThisDayEntry(album: album, summary: known))
                }
                continue
            }

            // A link that has just refused is left alone for a minute.
            guard !Self.failures.isRemembered(holdKey) else { break }
            guard asked < Self.maximumRequests else { break }
            asked += 1
            let step = await ReviewLedger.ask { try await provider.albumInfo(id: album.id).notes }
            switch step {
            case .cancelled:
                return
            case .failed:
                // Nothing recorded: a timeout says nothing about the album.
                failed += 1
                if failed >= Self.failureLimit {
                    Self.failures.note(holdKey)
                    return
                }
                continue
            case .review, .unreviewed:
                // A definite answer belongs to the ledger even if this pass
                // has since been replaced — it is about the album, not the day.
                Self.reviews.record(step, for: album.id)
            }
            guard case .review(let tidied) = step else { continue }

            // The shelf can be rebuilt while this is in flight — at midnight,
            // or on a library switch — and then this answer belongs to a day
            // that is no longer on screen.
            guard !Task.isCancelled, generation == mine,
                  showing == key, entries.count < Self.cardCount
            else { return }
            entries.append(OnThisDayEntry(album: album, summary: tidied))
        }
    }

    /// An entry for a record already known to have a review, or nothing.
    private static func knownEntry(for album: Album) -> OnThisDayEntry? {
        guard let review = reviews.review(for: album.id), !review.isEmpty else { return nil }
        return OnThisDayEntry(album: album, summary: review)
    }
}
