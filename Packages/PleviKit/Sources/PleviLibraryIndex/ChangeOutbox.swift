import Foundation
import Observation
import PleviDomain

/// What became of one change.
public enum ChangeOutcome: Sendable, Equatable {
    /// The server has it.
    case sent
    /// It is waiting: offline, or the server did not answer in a way that
    /// says anything about the change itself.
    case queued
    /// The server answered and turned it down, and asking again will not
    /// change that. Nothing is kept; whoever took the change locally owns
    /// putting things back.
    case refused(ProviderError)
}

/// Changes made while there was no server to tell.
@MainActor
@Observable
public final class ChangeOutbox {
    public private(set) var pending = 0
    public private(set) var lastFailure: String?

    /// Told once per drain, when changes the server will never accept had to
    /// be let go, so the loss is not silent.
    public var onDropped: (@MainActor (String) -> Void)?

    private let index: LibraryIndex
    private var provider: any MusicServerProvider
    /// Asked rather than told: whether the app is offline changes while this
    /// object lives.
    private let isOffline: @MainActor () -> Bool
    private var stopped = false

    public init(
        index: LibraryIndex,
        provider: any MusicServerProvider,
        isOffline: @escaping @MainActor () -> Bool
    ) {
        self.index = index
        self.provider = provider
        self.isOffline = isOffline
        pending = (try? index.pendingChangeCount()) ?? 0
    }

    /// Whether this is the queue for that index.
    public func serves(_ index: LibraryIndex) -> Bool { self.index === index }

    /// A reconnect to the same library: the queue stays, and so does a drain
    /// that is running — its next change goes to the new provider.
    public func rebind(provider: any MusicServerProvider) {
        self.provider = provider
        stopped = false
    }

    /// The library this belongs to is being left. A drain in the air stops
    /// before its next change rather than carrying on for a library that is
    /// no longer the one in use.
    public func stop() {
        stopped = true
    }

    // MARK: Taking changes

    @discardableResult
    public func rate(_ rating: StarRating?, id: MediaID) async -> ChangeOutcome {
        await sendKept(
            OutboxRecord(kind: .rating, itemId: id.rawValue, rating: rating?.value),
            direct: { try await self.provider.setRating(rating, for: id) }
        )
    }

    @discardableResult
    public func favorite(_ favorite: Bool, id: MediaID, kind: MediaKind) async -> ChangeOutcome {
        await sendKept(
            OutboxRecord(kind: .favorite, itemId: id.rawValue, mediaKind: kind.rawValue, flag: favorite),
            direct: { try await self.provider.setFavorite(favorite, for: id, kind: kind) }
        )
    }

    /// Plays are events, so they stay out of the ordering that ratings and
    /// hearts need: they are never replaced by a newer one, and none has to
    /// wait for another.
    @discardableResult
    public func play(id: MediaID, at date: Date = Date()) async -> ChangeOutcome {
        let outcome = await attempt(
            OutboxRecord(kind: .play, itemId: id.rawValue, at: date),
            direct: { try await self.provider.scrobble(id: id, at: date, submission: true) }
        )
        if outcome == .sent { await drain() }
        return outcome
    }

    /// A rating or a heart: one at a time per item, in the order they were
    /// given, and the last one given wins whatever else is waiting.
    private func sendKept(_ entry: OutboxRecord, direct: () async throws -> Void) async -> ChangeOutcome {
        let outcome = await exclusively(Self.orderingKey(index, entry)) {
            let outcome = await attempt(entry, direct: direct)
            if outcome == .sent {
                // Whatever was waiting for this same item is older than what the server has just
                // been told.
                _ = try? index.discardChanges(kind: entry.kind, itemId: entry.itemId, mediaKind: entry.mediaKind)
                pending = (try? index.pendingChangeCount()) ?? pending
            }
            return outcome
        }
        // A change that got through is also a chance to clear the queue
        // behind it: the connection is evidently working. After the ordering
        // is let go, because the drain takes it for each change of its own.
        if outcome == .sent { await drain() }
        return outcome
    }

    private func attempt(_ entry: OutboxRecord, direct: () async throws -> Void) async -> ChangeOutcome {
        guard !isOffline() else {
            enqueue(entry)
            return .queued
        }
        do {
            try await direct()
            lastFailure = nil
            return .sent
        } catch let error as ProviderError where Self.isRefusal(error) {
            lastFailure = error.errorDescription
            return .refused(error)
        } catch let error as ProviderError where Self.mightBeInTheWay(error) {
            // Said to be a refusal, but a proxy or a server restarting says
            // the same thing. Kept, so a rating given on a plane is not lost
            // to a bad minute; the reason is where someone can read it.
            lastFailure = error.errorDescription
            enqueue(entry)
            return .queued
        } catch {
            // Anything that looks like the network rather than the request:
            // keep it and try again later.
            enqueue(entry)
            return .queued
        }
    }

    private func enqueue(_ entry: OutboxRecord) {
        try? index.enqueueChange(entry)
        pending = (try? index.pendingChangeCount()) ?? pending + 1
    }

    /// How many times one change may fail before the queue stops waiting for
    /// it and carries on with the rest. It is kept, not dropped — a rating
    /// someone gave is not ours to discard because a server is being strange.
    private static let attemptsBeforeStepAside = 5

    /// Errors that will not come right by waiting.
    private static func isRefusal(_ error: ProviderError) -> Bool {
        switch error {
        case .notFound, .unsupportedOperation, .missingParameter:
            true
        // A garbled reply is not a refusal: a proxy having a bad minute
        // should not cost someone the rating they gave on a plane.
        default:
            false
        }
    }

    private static func mightBeInTheWay(_ error: ProviderError) -> Bool {
        switch error {
        case .notAuthorized, .incompatibleServer: true
        default: false
        }
    }

    // MARK: Ordering

    // Held for the whole of a write to one item, whichever object makes it:
    // the direct write of a new value, and the replay of an old one. Without
    // it the old one could land after the new one.
    private static var busy = Set<String>()
    private static var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private static var draining = Set<ObjectIdentifier>()

    private static func orderingKey(_ index: LibraryIndex, _ entry: OutboxRecord) -> String {
        "\(ObjectIdentifier(index).hashValue)|\(entry.kind.rawValue)|\(entry.itemId)|\(entry.mediaKind ?? "")"
    }

    private func exclusively<T>(_ key: String, _ body: () async -> T) async -> T {
        if Self.busy.contains(key) {
            await withCheckedContinuation { Self.waiting[key, default: []].append($0) }
        } else {
            Self.busy.insert(key)
        }
        defer {
            if var queue = Self.waiting[key], !queue.isEmpty {
                // Handed straight on, the key never being free in between.
                let next = queue.removeFirst()
                Self.waiting[key] = queue.isEmpty ? nil : queue
                next.resume()
            } else {
                Self.waiting[key] = nil
                Self.busy.remove(key)
            }
        }
        return await body()
    }

    // MARK: Replaying

    /// Sends what is waiting, oldest first, and stops at the first thing that
    /// looks like the network — there is no point shouting the rest at a
    /// server that is not listening.
    public func drain() async {
        guard !stopped, !isOffline() else { return }
        // One drain per index, whoever asks: the table is shared, and a
        // second walk over it sends what the first has not yet removed.
        let mine = ObjectIdentifier(index)
        guard Self.draining.insert(mine).inserted else { return }
        defer { Self.draining.remove(mine) }

        var dropped: [String] = []
        var clean = true
        let waiting = (try? index.pendingChanges()) ?? []
        for entry in waiting {
            guard !stopped, !isOffline() else { clean = false; break }
            guard let id = entry.id else { continue }
            // Ratings and hearts wait their turn behind any write to the same
            // item. Plays do not: they never replace one another.
            let step = entry.kind == .play
                ? await replay(id)
                : await exclusively(Self.orderingKey(index, entry)) { await replay(id) }
            if let reason = step.dropped { dropped.append(reason) }
            if step.failed { clean = false }
            if !step.carryOn { break }
        }
        pending = (try? index.pendingChangeCount()) ?? 0
        if clean { lastFailure = nil }
        if !dropped.isEmpty {
            onDropped?(Self.summary(of: dropped))
        }
    }

    private static func summary(of reasons: [String]) -> String {
        let noun = reasons.count == 1 ? "change" : "changes"
        return "\(reasons.count) \(noun) could not be sent and \(reasons.count == 1 ? "was" : "were") dropped: \(reasons[0])"
    }

    private struct Step {
        var carryOn = true
        var failed = false
        var dropped: String?
    }

    /// One waiting change. Read again first: what was in the snapshot may
    /// have been replaced by a newer choice, or already sent by a write made
    /// since.
    private func replay(_ id: Int64) async -> Step {
        guard let entry = (try? index.change(id: id)) ?? nil else { return Step() }
        do {
            try await perform(entry)
            // Only if it still says what was sent: a newer choice folded in while this was in the
            // air is not sent yet and must stay.
            _ = try? index.removeChange(matching: entry)
            return Step()
        } catch let error as ProviderError where Self.isRefusal(error) {
            // The server will never accept it: drop it rather than carry
            // it for ever, and say so once.
            let message = error.errorDescription ?? "The server refused it."
            lastFailure = message
            _ = try? index.removeChange(matching: entry)
            return Step(failed: true, dropped: message)
        } catch {
            let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            try? index.recordChangeFailure(id: id, message: message)
            lastFailure = message
            // The first thing to fail usually means the network has gone again, and shouting the
            // rest at it achieves nothing — so the queue stops where it stands and keeps its order.
            return Step(carryOn: entry.attempts + 1 >= Self.attemptsBeforeStepAside, failed: true)
        }
    }

    private func perform(_ entry: OutboxRecord) async throws {
        let id = MediaID(server: index.server, rawValue: entry.itemId)
        switch entry.kind {
        case .rating:
            try await provider.setRating(entry.rating.flatMap(StarRating.init), for: id)
        case .favorite:
            try await provider.setFavorite(
                entry.flag ?? false,
                for: id,
                kind: entry.mediaKind.flatMap(MediaKind.init) ?? .track
            )
        case .play:
            // The time it happened, not the time it was sent: a flight's worth
            // of listening should not all land at the moment you reconnect.
            try await provider.scrobble(id: id, at: entry.at, submission: true)
        }
    }
}
