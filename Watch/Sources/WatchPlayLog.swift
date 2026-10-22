import Foundation
import Observation
import PleviDomain

/// What was put on, on this watch.
@MainActor
@Observable
final class WatchPlayLog {
    private(set) var entries: [PlayedEntry] = []

    private let defaults: UserDefaults
    private var library: ServerID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func use(library: ServerID?) {
        guard library != self.library else { return }
        self.library = library
        entries = library.flatMap(load) ?? []
    }

    /// Forgets a library's list altogether, for one that has been removed.
    func forget(library removed: ServerID) {
        defaults.removeObject(forKey: key(for: removed))
        if library == removed { entries = [] }
    }

    /// Records something put on here. The same guard the phone's log keeps:
    /// a source minted while no library was open belongs to nothing, and
    /// writing it would leave an unopenable row at the top of the shelf.
    func record(_ source: PlayedSource, at date: Date) {
        guard let library, source.mediaID.server == library else { return }
        entries = PlayHistory.recording(source, at: date, in: entries)
        write()
    }

    /// This watch's list and the phone's, as one shelf.
    func merged(with phone: [PlayedEntry]) -> [PlayedEntry] {
        PlayHistory.seeded(entries + phone)
    }

    private func key(for library: ServerID) -> String {
        "watch.playLog.\(library.rawValue.uuidString)"
    }

    private func load(_ library: ServerID) -> [PlayedEntry] {
        guard let data = defaults.data(forKey: key(for: library)),
              let saved = try? JSONDecoder().decode([PlayedEntry].self, from: data)
        else { return [] }
        return saved
    }

    private func write() {
        guard let library, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key(for: library))
    }
}

/// Plays counted while the server could not be told, kept until it can be.
@MainActor
final class WatchPendingPlays {
    private let defaults: UserDefaults
    private var library: ServerID?
    private var pending = PendingPlays()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func use(library: ServerID?) {
        guard library != self.library else { return }
        self.library = library
        pending = library.flatMap(load) ?? PendingPlays()
    }

    /// Whether anything is waiting to be sent.
    var isEmpty: Bool { pending.isEmpty }

    /// Notes a play against the library it was played in. A song from another
    /// library is not this list's to send: it would be reported to the wrong
    /// server.
    func enqueue(_ track: MediaID, at date: Date) {
        guard let library, track.server == library else { return }
        pending.enqueue(trackID: track.rawValue, at: date)
        write()
    }

    /// Sends what is waiting, oldest first, stopping at the first failure that
    /// says the server is not there. An entry leaves only when the server has
    /// accepted it, or has refused it for good.
    func drain(using provider: any MusicServerProvider) async {
        guard let library else { return }
        while let next = pending.next, !Task.isCancelled {
            do {
                try await provider.scrobble(
                    id: MediaID(server: library, rawValue: next.trackID),
                    at: next.playedAt,
                    submission: true
                )
                pending.removeNext()
                write()
            } catch {
                switch PendingPlays.outcome(afterFailure: error) {
                case .keepAndStop:
                    return
                case .drop:
                    pending.removeNext()
                    write()
                }
            }
        }
    }

    /// Forgets a library's list, for one that has been removed.
    func forget(library removed: ServerID) {
        defaults.removeObject(forKey: key(for: removed))
        if library == removed { pending = PendingPlays() }
    }

    private func key(for library: ServerID) -> String {
        "watch.pendingPlays.\(library.rawValue.uuidString)"
    }

    private func load(_ library: ServerID) -> PendingPlays? {
        defaults.data(forKey: key(for: library))
            .flatMap { try? JSONDecoder().decode(PendingPlays.self, from: $0) }
    }

    private func write() {
        guard let library, let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: key(for: library))
    }
}
