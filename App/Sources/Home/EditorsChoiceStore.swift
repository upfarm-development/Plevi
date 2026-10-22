import Foundation
import Observation
import PleviDomain
import PleviLibraryIndex

/// Today's well-reviewed record.
@MainActor
@Observable
final class EditorsChoiceStore {
    /// Today's record, or nothing — which is the signal to draw no section
    /// at all rather than an empty card.
    private(set) var pick: Album?

    private let defaults: UserDefaults
    /// The day and library the thing on screen belongs to.
    private var showing: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Picks again when the day turns, and not otherwise.
    func refresh(index: LibraryIndex?, capabilities: ServerCapabilities, now: Date = .now) {
        // A reviewer's verdict is the whole basis of the section, and a Subsonic server has no such
        // field — only what you thought of a record yourself.
        guard capabilities.contains(.criticRatings), let index else {
            pick = nil
            showing = nil
            return
        }

        let day = MadeForYou.dayNumber(for: now)
        let library = index.server.rawValue.uuidString
        let key = "\(day)|\(library)"
        guard key != showing else { return }

        // Settled earlier today, so it is read back rather than worked out again.
        if let settled = history(for: library).first(where: { $0.day == day }),
           let album = (try? index.albums(ids: [settled.albumID]))?.first {
            showing = key
            pick = album
            return
        }

        let candidates = (try? index.criticallyAcclaimedAlbums(atLeast: EditorsChoice.minimumScore)) ?? []
        guard let chosen = EditorsChoice.pick(
            for: day,
            from: candidates,
            recentlyShown: history(for: library)
        ) else {
            pick = nil
            // Deliberately not stamped as shown: a library that gains a
            // well-reviewed record this afternoon should get a card this
            // afternoon rather than tomorrow.
            showing = nil
            return
        }

        showing = key
        pick = chosen
        remember(chosen, on: day, for: library)
    }

    // MARK: What has been shown

    private func history(for library: String) -> [EditorsChoice.Appearance] {
        guard let data = defaults.data(forKey: Self.historyKey(library)),
              let saved = try? JSONDecoder().decode([EditorsChoice.Appearance].self, from: data)
        else { return [] }
        return saved
    }

    private func remember(_ album: Album, on day: Int, for library: String) {
        var saved = history(for: library)
        // One entry per day: opening the app twice in an afternoon is not
        // two appearances.
        saved.removeAll { $0.day == day }
        saved.append(EditorsChoice.Appearance(album: album, day: day))
        // Nothing older than the rest period can affect a decision again.
        saved.removeAll { day - $0.day >= EditorsChoice.restDays }
        guard let encoded = try? JSONEncoder().encode(saved) else { return }
        defaults.set(encoded, forKey: Self.historyKey(library))
    }

    private static func historyKey(_ library: String) -> String {
        "home.editorsChoice.v1.\(library)"
    }
}
