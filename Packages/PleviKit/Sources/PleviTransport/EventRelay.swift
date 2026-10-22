import Foundation
import Synchronization

/// Hands a downloader's events to whoever is listening now, and keeps them for whoever listens
/// next.
final class EventRelay: Sendable {
    private struct State {
        var continuation: AsyncStream<BackgroundDownloadEvent>.Continuation?
        var token = 0
        /// The newest not-yet-final report per transfer.
        var live: [String: BackgroundDownloadEvent] = [:]
        /// Endings, in the order they happened.
        var ends: [BackgroundDownloadEvent] = []
    }

    private let state = Mutex(State())

    /// Whether anything is attached right now. For tests.
    var hasReader: Bool { state.withLock { $0.continuation != nil } }

    /// A stream of every event from now on, plus anything that arrived while
    /// nobody was reading. Any earlier reader's stream ends.
    func attach() -> AsyncStream<BackgroundDownloadEvent> {
        let (stream, continuation) = AsyncStream<BackgroundDownloadEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (previous, token) = state.withLock { state -> (AsyncStream<BackgroundDownloadEvent>.Continuation?, Int) in
            let previous = state.continuation
            state.token += 1
            state.continuation = continuation
            // Live reports before endings is the order a reader can make
            // sense of: a transfer's last progress never follows its ending,
            // because the ending removes it from `live`.
            for event in state.live.values { continuation.yield(event) }
            for event in state.ends { continuation.yield(event) }
            state.live = [:]
            state.ends = []
            return (previous, state.token)
        }
        continuation.onTermination = { [weak self] _ in self?.detach(token: token) }
        // Outside the lock: finishing runs the previous reader's termination
        // handler, which takes the lock to detach itself.
        previous?.finish()
        return stream
    }

    func emit(_ event: BackgroundDownloadEvent) {
        state.withLock { state in
            if let continuation = state.continuation {
                if case .terminated = continuation.yield(event) {
                    // The reader went away and its handler has not run yet.
                    state.continuation = nil
                } else {
                    return
                }
            }
            switch event.kind {
            case .finished, .failed:
                state.live[event.id] = nil
                state.ends.append(event)
            default:
                state.live[event.id] = event
            }
        }
    }

    private func detach(token: Int) {
        state.withLock { state in
            // A reader that was replaced is not the current one; its
            // termination must not detach its successor.
            if state.token == token { state.continuation = nil }
        }
    }
}
