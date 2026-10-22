import Foundation
import Observation
import PleviDomain
import PleviLibraryIndex

/// The records the Rediscover shelf is showing, and for how long.
@MainActor
@Observable
final class RediscoverStore {
    /// The whole day's pick, in order: what "See More" shows.
    private(set) var all: [Album] = []

    /// The first few of it: what the shelf shows.
    var albums: [Album] { Array(all.prefix(Self.shelfCount)) }

    private let defaults: UserDefaults
    /// The day and library on show, so a phone left open past midnight
    /// refreshes, and so does a switch to another library.
    private var showing: String?

    /// How many the shelf shows, and how many the day's pick holds.
    private static let shelfCount = 10
    private static let count = 20

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func refresh(index: LibraryIndex?, downloadedOnly: Bool, now: Date = .now) {
        guard let index else { return }
        let day = MadeForYou.dayOfYear(for: now)
        let key = "\(day)|\(index.server.rawValue.uuidString)|\(downloadedOnly)"
        guard key != showing else { return }
        showing = key

        if let kept = defaults.array(forKey: Self.storeKey(key)) as? [String] {
            let restored = (try? index.albums(
                ids: kept.map { MediaID(server: index.server, rawValue: $0) }
            )) ?? []
            // A day's records can go missing between one visit and the next — a rescan, a deletion.
            if kept.count == Self.count, restored.count >= Self.count / 2 {
                all = restored
                return
            }
        }

        all = (try? index.albums(
            filter: .rediscover,
            offset: 0,
            limit: Self.count,
            downloadedOnly: downloadedOnly
        )) ?? []
        defaults.set(all.map(\.id.rawValue), forKey: Self.storeKey(key))
        forgetDead(day: day, library: index.server.rawValue.uuidString)
    }

    private static let prefix = "home.rediscover."

    private static func storeKey(_ key: String) -> String { "\(prefix)\(key)" }

    /// Yesterday's is no use to anyone — but another library's pick for today is, so a switch back
    /// to it finds the shelf it left.
    private func forgetDead(day: Int, library: String) {
        ShelfCachePruning.prune(
            defaults, prefix: Self.prefix, recentKey: Self.recentKey,
            currentLibrary: library, currentPeriod: String(day)
        ) { suffix in
            // "<day>|<library id>|<downloaded only>"
            let parts = suffix.split(separator: "|").map(String.init)
            guard parts.count == 3 else { return nil }
            return (library: parts[1], period: parts[0])
        }
    }

    /// Outside `prefix`, so it is never mistaken for a stored pick.
    private static let recentKey = "home.shelfLibraries.rediscover"
}
