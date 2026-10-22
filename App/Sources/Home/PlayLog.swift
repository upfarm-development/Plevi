import Foundation
import PleviDomain
import PleviLibraryIndex

/// What has been put on lately, kept per library.
@MainActor
@Observable
final class PlayLog {
    private let defaults: UserDefaults
    private var library: ServerID?

    /// Whether there is a library to file a play against yet.
    var isReady: Bool { library != nil }

    private(set) var entries: [PlayedEntry] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Points the log at a library. Called whenever one is connected.
    func use(library: ServerID?) {
        guard library != self.library else { return }
        self.library = library
        entries = library.flatMap(load) ?? []
    }

    /// Reads the open library's log again, from the key a restore by hand
    /// has just written.
    func reload() {
        let current = library
        library = nil
        use(library: current)
    }

    private func key(for library: ServerID) -> String {
        "home.playLog.\(library.rawValue.uuidString)"
    }

    private func seededKey(for library: ServerID) -> String {
        "home.playLog.seeded.\(library.rawValue.uuidString)"
    }

    /// Where a restored log waits for a library to claim it.
    private static let restoredKey = "home.playLog"
    private static let restoredSeededKey = "home.playLog.seeded"

    private func load(_ library: ServerID) -> [PlayedEntry] {
        if let data = defaults.data(forKey: key(for: library)),
           let saved = try? JSONDecoder().decode([PlayedEntry].self, from: data) {
            return saved
        }
        if let data = defaults.data(forKey: Self.restoredKey),
           let restored = try? JSONDecoder().decode([PlayedEntry].self, from: data) {
            defaults.removeObject(forKey: Self.restoredKey)
            // Each entry names the server the install that recorded it gave the library; on this
            // install that id belongs to nothing, and a playlist card carrying it reads "not
            // found".
            let rebased = PlayHistory.rebased(restored, to: library)
            defaults.set((try? JSONEncoder().encode(rebased)) ?? data, forKey: key(for: library))
            // The seeding flag travels with it: a restored log that is then
            // seeded on top would list everything twice.
            if defaults.object(forKey: Self.restoredSeededKey) != nil {
                defaults.removeObject(forKey: Self.restoredSeededKey)
                defaults.set(true, forKey: seededKey(for: library))
            }
            return rebased
        }
        return []
    }

    /// Records something that was actually listened to.
    func record(_ source: PlayedSource, at date: Date) {
        guard let library, source.mediaID.server == library else { return }
        entries = PlayHistory.recording(source, at: date, in: entries)
        write()
    }

    /// The library this log is filing plays against, if one is open.
    var currentLibrary: ServerID? { library }

    /// Records something the watch reported, placed by when it happened.
    func recordReplayed(_ source: PlayedSource, at date: Date) {
        guard let library, source.mediaID.server == library else { return }
        entries = PlayHistory.replaying(source, at: date, in: entries)
        write()
    }

    /// The same, for a library that is not the one open: a watch can be pointed at a library the
    /// phone has since switched away from.
    static func recordReplayed(
        _ source: PlayedSource,
        at date: Date,
        inLibrary library: ServerID,
        defaults: UserDefaults = .standard
    ) {
        let key = "home.playLog.\(library.rawValue.uuidString)"
        let existing = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([PlayedEntry].self, from: $0) } ?? []
        let updated = PlayHistory.replaying(source, at: date, in: existing)
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: key) }
    }

    func remove(_ entry: PlayedEntry) {
        entries.removeAll { $0.id == entry.id }
        write()
    }

    func clear() {
        entries = []
        write()
    }

    /// Fills an empty log once from the records the library already knows
    /// were played, newest first.
    ///
    /// An empty Recently Played on the morning of an update reads as data
    /// loss rather than as a new beginning. These carry the old shelf's
    /// impurity — a record heard only inside a mix is in here, and there is
    /// no way now to tell which — but the shelf is self-clearing: everything
    /// actually put on pushes one of them off the end.
    ///
    /// Marked rather than inferred from emptiness, so clearing the shelf by
    /// hand does not refill it from history the next time Home loads.
    func seedIfNeeded(from index: LibraryIndex, downloadedOnly: Bool) {
        guard let library, !defaults.bool(forKey: seededKey(for: library)) else { return }
        // Anything already here was put here on purpose — a play reported by
        // the watch while the phone was closed arrives before this runs — and
        // the seed replaces the whole log wholesale.
        guard entries.isEmpty else {
            defaults.set(true, forKey: seededKey(for: library))
            return
        }
        let albums = (try? index.albums(
            filter: .recentlyPlayed,
            offset: 0,
            limit: PlayHistory.kept,
            downloadedOnly: downloadedOnly
        )) ?? []
        // Nothing to seed from yet — a library still syncing on first run.
        // Left unmarked so the next load can try again, rather than fixing
        // an empty shelf in place forever.
        guard !albums.isEmpty else { return }
        defaults.set(true, forKey: seededKey(for: library))
        entries = PlayHistory.seeded(albums.compactMap { album in
            guard let playedAt = album.playedAt else { return nil }
            return PlayedEntry(source: PlayedSource(album: album), playedAt: playedAt)
        })
        write()
    }

    private func write() {
        guard let library, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key(for: library))
    }
}
