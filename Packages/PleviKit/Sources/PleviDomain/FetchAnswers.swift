import Foundation

/// The rules for what a request that did not come back may be recorded as.

/// Whether an error is the shape a called-off request comes back as.
public enum FetchCancellation {
    public static func isCancelled(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if case .network(let underlying)? = error as? ProviderError,
           underlying.code == .cancelled {
            return true
        }
        return false
    }
}

/// How one request ended, in the three ways that must not be confused.
public enum FetchOutcome<Value> {
    /// The server answered. An empty answer is still an answer.
    case answered(Value)
    /// The request was called off — a view went away, a key moved on. Says
    /// nothing about the server, and is worth neither a message nor a memory.
    case cancelled
    /// The request did not get through, or the server refused it. Says
    /// nothing about what is there.
    case failed(message: String)

    /// Runs the request and sorts what happens into one of the three.
    public static func attempt(
        isolation: isolated (any Actor)? = #isolation,
        _ request: () async throws -> Value
    ) async -> FetchOutcome<Value> {
        do {
            return .answered(try await request())
        } catch {
            if Task.isCancelled || FetchCancellation.isCancelled(error) { return .cancelled }
            return .failed(message: error.localizedDescription)
        }
    }

    public var answer: Value? {
        if case .answered(let value) = self { return value }
        return nil
    }
}

extension FetchOutcome: Sendable where Value: Sendable {}

/// What a screen that lists something fetched from the server knows about it:
/// nothing yet, a list, or a failure — and keeps the last good list through a
/// failed refresh instead of replacing it with "nothing".
public struct FetchedList<Element>: Sendable where Element: Sendable {
    /// The last list the server actually gave, nil until it has given one.
    public private(set) var items: [Element]?
    /// Why the latest attempt failed, nil after a success.
    public private(set) var failure: String?

    public init(items: [Element]? = nil) {
        self.items = items
    }

    /// Nothing asked yet, or nothing answered yet.
    public var isLoading: Bool { items == nil && failure == nil }
    /// There is nothing good to show and the reason is a failure, not an
    /// empty answer: the place for "Can't reach the server" and Retry.
    public var isFailed: Bool { items == nil && failure != nil }
    /// A real, answered "none". The only state that may say so.
    public var isEmptyAnswer: Bool { items?.isEmpty == true }
    /// A good list is on show but the latest refresh did not get through.
    public var isStale: Bool { items != nil && failure != nil }

    public mutating func apply(_ outcome: FetchOutcome<[Element]>) {
        switch outcome {
        case .answered(let list):
            items = list
            failure = nil
        case .cancelled:
            break
        case .failed(let message):
            failure = message
        }
    }

    /// Back to a fresh "loading", for a Retry that should show it.
    public mutating func beginRetry() {
        failure = nil
    }

    /// Forgets everything, for a change of library or server.
    public mutating func reset() {
        items = nil
        failure = nil
    }
}

/// When a failure may be asked about again.
public struct FailureMemo: Sendable {
    public let lifetime: TimeInterval
    private let capacity: Int
    private var failedAt: [String: Date] = [:]

    public init(lifetime: TimeInterval, capacity: Int = 2_000) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    public var count: Int { failedAt.count }

    public mutating func note(_ key: String, at now: Date = .now) {
        failedAt[key] = now
        guard failedAt.count > capacity else { return }
        failedAt = failedAt.filter { now.timeIntervalSince($0.value) < lifetime }
        // Still over: the oldest half is the least likely to be asked again.
        if failedAt.count > capacity {
            let newest = failedAt.sorted { $0.value > $1.value }.prefix(capacity / 2)
            failedAt = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }

    public func isRemembered(_ key: String, at now: Date = .now) -> Bool {
        guard let when = failedAt[key] else { return false }
        return now.timeIntervalSince(when) < lifetime
    }

    public mutating func forget(_ key: String) {
        failedAt[key] = nil
    }

    public mutating func removeAll() {
        failedAt.removeAll()
    }
}

/// The reviews On This Day has learned, kept for the session.
public struct ReviewLedger: Sendable {
    private var reviews: [MediaID: String] = [:]

    public init() {}

    /// How one album's review request ended.
    public enum Step: Equatable, Sendable {
        case review(String)
        /// The server answered and had nothing written.
        case unreviewed
        case failed
        case cancelled
    }

    /// What is known about an album: nil when it has never been answered
    /// for, empty when it is known to have nothing, otherwise the review.
    public func review(for id: MediaID) -> String? { reviews[id] }

    public var count: Int { reviews.count }

    /// Asks, and sorts the ending. Does not touch a ledger — the caller
    /// records the step, so no mutation is held open across the await.
    public static func ask(
        isolation: isolated (any Actor)? = #isolation,
        _ notes: () async throws -> String?
    ) async -> Step {
        switch await FetchOutcome.attempt(isolation: isolation, notes) {
        case .answered(let text):
            let tidied = Self.tidied(text ?? "")
            return tidied.isEmpty ? .unreviewed : .review(tidied)
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        }
    }

    /// Records only what the server actually said.
    public mutating func record(_ step: Step, for id: MediaID) {
        switch step {
        case .review(let text): reviews[id] = text
        case .unreviewed: reviews[id] = ""
        case .failed, .cancelled: break
        }
    }

    /// A review the index already holds. Only a real one: a missing column
    /// is "nobody has said", not "there is none", and writing an empty entry
    /// for it would mark the record unreviewed for the session.
    public mutating func noteStored(_ review: String?, for id: MediaID) {
        guard reviews[id] == nil,
              let text = review?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        reviews[id] = Self.tidied(text)
    }

    /// Reviews arrive with paragraph breaks and stray whitespace, which on
    /// three lines of a card shows up as a gap rather than as a paragraph.
    public static func tidied(_ notes: String) -> String {
        notes
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Which stored shelf choices to drop when the shelf on show changes.
public enum ShelfCachePruning {
    public struct Entry: Hashable, Sendable {
        public let key: String
        public let library: String
        public let period: String

        public init(key: String, library: String, period: String) {
            self.key = key
            self.library = library
            self.period = period
        }
    }

    public struct Plan: Equatable, Sendable {
        /// The `key`s of the entries to delete.
        public let remove: [String]
        /// The libraries to remember as recent, most recent first.
        public let recentLibraries: [String]
    }

    public static let defaultMaximumLibraries = 8

    public static func plan(
        entries: [Entry],
        currentLibrary: String,
        currentPeriod: String,
        recentLibraries: [String],
        maximumLibraries: Int = defaultMaximumLibraries
    ) -> Plan {
        var recent = [currentLibrary]
        for library in recentLibraries where library != currentLibrary && !recent.contains(library) {
            recent.append(library)
        }
        recent = Array(recent.prefix(max(1, maximumLibraries)))
        let kept = Set(recent)

        let remove = entries.filter { entry in
            if !kept.contains(entry.library) { return true }
            return entry.library == currentLibrary && entry.period != currentPeriod
        }.map(\.key)
        return Plan(remove: remove, recentLibraries: recent)
    }

    /// Applies `plan(...)` to preferences: every key under `prefix` is read with `parse` (given the
    /// part after the prefix), the dead ones are removed, and the recent-library list under
    /// `recentKey` is rewritten.
    public static func prune(
        _ defaults: UserDefaults,
        prefix: String,
        recentKey: String,
        currentLibrary: String,
        currentPeriod: String,
        maximumLibraries: Int = defaultMaximumLibraries,
        parse: (String) -> (library: String, period: String)?
    ) {
        var entries: [Entry] = []
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            guard let parsed = parse(String(key.dropFirst(prefix.count))) else {
                defaults.removeObject(forKey: key)
                continue
            }
            entries.append(Entry(key: key, library: parsed.library, period: parsed.period))
        }
        let plan = plan(
            entries: entries,
            currentLibrary: currentLibrary,
            currentPeriod: currentPeriod,
            recentLibraries: defaults.stringArray(forKey: recentKey) ?? [],
            maximumLibraries: maximumLibraries
        )
        for key in plan.remove { defaults.removeObject(forKey: key) }
        defaults.set(plan.recentLibraries, forKey: recentKey)
    }
}
