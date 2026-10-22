import Foundation
import Synchronization

/// The decisions behind reaching, and reaching again, the server — kept as plain values so they can
/// be checked without an app around them.

// MARK: - Why a connection failed

/// The reason a connection is down, in the terms that decide what the person looking at it should
/// be told and whether waiting will help.
public enum ConnectionFailureKind: Sendable, Hashable {
    /// Nothing answered: a timeout, a refused or dropped connection, DNS, or
    /// a server that answered with a five hundred (its proxy's own "back in a
    /// minute" page). Waiting can put this right.
    case unreachable
    /// The device has no network path at all.
    case noNetwork
    /// The server answered and said no to the credentials or token.
    case rejected
    /// Signed in, and not allowed.
    case notAuthorized
    /// A certificate that is not trusted, or one that changed.
    case certificate
    /// A sign-in page of a proxy stands in front of the server.
    case proxyWall
    /// Something answered that is not a server this app understands.
    case incompatible
    /// The connection could not even be started: a token missing, a library
    /// never chosen.
    case setupIncomplete
    /// Anything not listed.
    case other

    /// Whether trying again by itself can be expected to help.
    public var isWorthRetrying: Bool {
        switch self {
        case .unreachable, .noNetwork: true
        default: false
        }
    }

    /// Whether the fault is between the phone and the server rather than in
    /// what the server said. The banner keeps its "Can't reach the server"
    /// for exactly these.
    public var isReachabilityProblem: Bool { isWorthRetrying }

    /// Sorts what a failed connection test threw.
    public static func classify(_ error: any Error) -> ConnectionFailureKind {
        if let error = error as? ProviderError {
            switch error {
            case .network(let underlying):
                return classify(underlying)
            case .tls:
                return .certificate
            case .notAuthenticated:
                return .rejected
            case .notAuthorized:
                return .notAuthorized
            case .proxySignInRequired:
                return .proxyWall
            case .serverError(let code, _, _):
                // A 502/503/504 from the proxy in front of a restarting
                // server, and the 408 and 429 a struggling one answers with,
                // are the server being away, not the server refusing.
                if let code, code >= 500 || code == 408 || code == 429 { return .unreachable }
                return .other
            case .incompatibleServer, .malformedResponse:
                return .incompatible
            case .notFound, .missingParameter, .unsupportedOperation, .conflict:
                return .other
            }
        }
        if let error = error as? URLError { return classify(error) }
        return .other
    }

    private static func classify(_ error: URLError) -> ConnectionFailureKind {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            .certificate
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            .noNetwork
        default:
            .unreachable
        }
    }
}

// MARK: - Trying again

/// When a failed connection is asked again, without anybody tapping Retry.
public enum ConnectionRetrySchedule {
    /// How long to wait after `failures` unsuccessful attempts. Quick at
    /// first, because the common cause is a hiccup, then settling at a
    /// minute so a server that is properly down is asked about rarely.
    public static func delay(afterFailures failures: Int) -> Duration {
        switch failures {
        case ..<1: .seconds(3)
        case 1: .seconds(10)
        case 2: .seconds(30)
        default: .seconds(60)
        }
    }

    /// Whether a retry loop should be running at all for a connection in
    /// this state.
    public static func shouldRun(
        failure: ConnectionFailureKind,
        offlineByChoice: Bool,
        pathSatisfied: Bool
    ) -> Bool {
        failure.isWorthRetrying && !offlineByChoice && pathSatisfied
    }

    /// Asks again until the connection is no longer failing or the task is cancelled.
    @MainActor
    public static func run(
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        isStillFailing: () -> Bool,
        attempt: () async -> Void
    ) async {
        var failures = 0
        while !Task.isCancelled {
            do { try await sleep(delay(afterFailures: failures)) } catch { return }
            guard !Task.isCancelled, isStillFailing() else { return }
            await attempt()
            failures += 1
        }
    }
}

// MARK: - What to do when the network changed

/// What a refresh of the address should do, given where the connection is.
public enum EndpointRefreshPlan {
    public enum Phase: Sendable, Equatable {
        case idle, connecting, connected, failed
    }

    public enum Action: Sendable, Equatable {
        /// Nothing to learn. Either a connection is being built and will
        /// choose for itself, or the app is not building one.
        case skip
        /// Test the connection, whatever the address did.
        case fullTest
        /// The connection reads as good and the address has not moved.
        case quickCheck
    }

    /// - Parameter includingIdle: set by going online. `.idle` is otherwise
    ///   "nobody has tried", and left alone; with a provider built while
    ///   Offline Mode was on it is "tried nothing yet", and needs its test.
    public static func action(
        phase: Phase,
        addressMoved: Bool,
        includingIdle: Bool
    ) -> Action {
        switch phase {
        case .idle: includingIdle ? .fullTest : .skip
        case .connecting: .skip
        case .failed: .fullTest
        case .connected: addressMoved ? .fullTest : .quickCheck
        }
    }
}

/// What turning Offline Mode off has to set going.
public enum GoOnlinePlan {
    public enum Action: Sendable, Equatable {
        /// There is no provider to test: build the stack, which chooses the
        /// address and tests as it goes.
        case connect
        /// A provider exists. Choose the address again and test it, without
        /// rebuilding downloads, the DJ and the outbox for the sake of it.
        case refresh
    }

    public static func action(hasProvider: Bool, hasEndpoint: Bool) -> Action {
        hasProvider && hasEndpoint ? .refresh : .connect
    }
}

// MARK: - Asking briefly

/// The outcome of asking the server a question with a deadline.
public enum DeadlineOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case failed(any Error)
    case timedOut
}

/// A question with a deadline, that really stops waiting at the deadline.
public enum Deadline {
    public static func run<Value: Sendable>(
        within limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> DeadlineOutcome<Value> {
        let gate = Gate<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let work = Task {
                    do { gate.finish(.value(try await operation())) }
                    catch { gate.finish(.failed(error)) }
                }
                let timer = Task {
                    guard (try? await sleep(limit)) != nil else { return }
                    gate.finish(.timedOut)
                }
                gate.onFinish { work.cancel(); timer.cancel() }
            }
        } onCancel: {
            gate.finish(.failed(CancellationError()))
        }
    }

    private final class Gate<Value: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<DeadlineOutcome<Value>, Never>?
            var finished: DeadlineOutcome<Value>?
            var cleanup: (@Sendable () -> Void)?
        }
        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<DeadlineOutcome<Value>, Never>) {
            let early = state.withLock { state -> DeadlineOutcome<Value>? in
                if let finished = state.finished { return finished }
                state.continuation = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }

        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let already = state.withLock { state -> Bool in
                if state.finished != nil { return true }
                state.cleanup = cleanup
                return false
            }
            if already { cleanup() }
        }

        func finish(_ outcome: DeadlineOutcome<Value>) {
            let (continuation, cleanup) = state.withLock { state -> (CheckedContinuation<DeadlineOutcome<Value>, Never>?, (@Sendable () -> Void)?) in
                guard state.finished == nil else { return (nil, nil) }
                state.finished = outcome
                defer { state.continuation = nil; state.cleanup = nil }
                return (state.continuation, state.cleanup)
            }
            continuation?.resume(returning: outcome)
            cleanup?()
        }
    }
}

/// Asks whether a server that reads as connected still answers, and calls it gone only after two
/// misses in a row.
public enum ReachabilityCheck {
    public enum Verdict<Value: Sendable>: Sendable {
        case answered(Value)
        /// Timed out, or the transport failed, on every try.
        case unreachable(lastError: (any Error)?)
        /// The server answered, and the answer was a refusal or a wall — a
        /// verdict at once, not a miss to be repeated.
        case answeredBadly(any Error)
    }

    public static func run<Value: Sendable>(
        deadline: Duration = .seconds(5),
        misses: Int = 2,
        pause: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Verdict<Value> {
        var lastError: (any Error)?
        for attempt in 0..<max(1, misses) {
            if attempt > 0 {
                do { try await sleep(pause) } catch { return .unreachable(lastError: lastError) }
            }
            switch await Deadline.run(within: deadline, sleep: sleep, operation) {
            case .value(let value):
                return .answered(value)
            case .timedOut:
                continue
            case .failed(let error):
                if error is CancellationError { return .unreachable(lastError: lastError) }
                if ConnectionFailureKind.classify(error).isReachabilityProblem {
                    lastError = error
                    continue
                }
                return .answeredBadly(error)
            }
        }
        return .unreachable(lastError: lastError)
    }
}
