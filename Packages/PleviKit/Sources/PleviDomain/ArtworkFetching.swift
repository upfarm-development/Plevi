import Foundation

/// How one artwork request ended, sorted by what it says about the server.
public enum ArtworkAnswer: Sendable, Equatable {
    /// A picture that decoded.
    case delivered
    /// The server looked at the request and said no — a 4xx, or a 200 whose
    /// body is not an image. The original may still work.
    case rejected
    /// The server answered with a 5xx that is not plainly an overloaded or unreachable front end.
    case serverFault
    /// It did not get through: a timeout, a dropped connection, or a gateway
    /// or rate-limit answer (408, 429, 502, 503, 504). Nothing is known about
    /// the picture.
    case unreachable
    /// Called off. Says nothing at all.
    case cancelled

    /// What the status of a response that arrived means. `bodyDecodes` is
    /// whether a 200's body turned out to be an image.
    public static func classify(statusCode: Int, bodyDecodes: Bool) -> ArtworkAnswer {
        switch statusCode {
        case 200:
            return bodyDecodes ? .delivered : .rejected
        case 408, 429, 502, 503, 504:
            return .unreachable
        case 500...599:
            return .serverFault
        default:
            return .rejected
        }
    }

    /// Whether a sized request ending this way is worth answering with the
    /// unsized original. Only when the server replied and the reply was about
    /// the request, not about the route to the server.
    public var allowsOriginalFallback: Bool {
        self == .rejected || self == .serverFault
    }

    /// Whether the final ending deserves a short negative entry, so scrolling
    /// back over the same cells does not ask again straight away. Never a
    /// cancellation, and never a success.
    public var isWorthRemembering: Bool {
        switch self {
        case .rejected, .serverFault, .unreachable: return true
        case .delivered, .cancelled: return false
        }
    }
}

/// A counting gate that lets the newest caller in first.
public actor RecencyGate {
    private let limit: Int
    private var running = 0
    private var nextWaiter = 0
    private var waiting: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var runningCount: Int { running }
    public var waitingCount: Int { waiting.count }

    /// Runs `operation` when a place is free, newest waiter first. Returns
    /// nil, without running it, if the caller is cancelled before its turn.
    public func withPlace<T: Sendable>(_ operation: @Sendable () async -> T) async -> T? {
        guard await acquire() else { return nil }
        let result = await operation()
        release()
        return result
    }

    private func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        nextWaiter += 1
        let id = nextWaiter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    private func abandon(_ id: Int) {
        guard let position = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: position).continuation.resume(returning: false)
    }

    private func release() {
        if let next = waiting.popLast() {
            // The place passes straight on, so `running` does not dip.
            next.continuation.resume(returning: true)
        } else {
            running -= 1
        }
    }
}

/// Shares one request between everyone asking for the same thing, and calls it off when the last of
/// them stops waiting.
public actor RequestCoalescer<Value: Sendable> {
    private struct Entry {
        let serial: Int
        let task: Task<Void, Never>
        var waiters: [Int: CheckedContinuation<Value?, Never>] = [:]
    }

    private var entries: [String: Entry] = [:]
    private var nextSerial = 0

    public init() {}

    public var inFlightCount: Int { entries.count }

    /// The value for `key`, starting `work` if nobody is already doing so.
    /// Returns nil when the work produced nothing, or when the caller was
    /// cancelled before it finished.
    public func value(
        for key: String,
        work: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        nextSerial += 1
        let waiter = nextSerial

        let serial: Int
        if let entry = entries[key] {
            serial = entry.serial
        } else {
            serial = waiter
            let task = Task { [weak self] in
                let result = await work()
                await self?.finished(key, serial: serial, result: result)
            }
            entries[key] = Entry(serial: serial, task: task)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                if entries[key] != nil {
                    entries[key]?.waiters[waiter] = continuation
                } else {
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            Task { await self.abandon(key, serial: serial, waiter: waiter) }
        }
    }

    private func abandon(_ key: String, serial: Int, waiter: Int) {
        guard var entry = entries[key], entry.serial == serial,
              let continuation = entry.waiters.removeValue(forKey: waiter)
        else { return }
        continuation.resume(returning: nil)
        if entry.waiters.isEmpty {
            entry.task.cancel()
            entries[key] = nil
        } else {
            entries[key] = entry
        }
    }

    private func finished(_ key: String, serial: Int, result: Value?) {
        guard let entry = entries[key], entry.serial == serial else { return }
        entries[key] = nil
        for continuation in entry.waiters.values { continuation.resume(returning: result) }
    }
}
