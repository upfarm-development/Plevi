import Foundation
import Synchronization
import Testing
@testable import PleviDomain

/// Why a connection failed, and so what to say and whether to wait.
@Suite("Connection failure kinds")
struct ConnectionFailureKindTests {
    @Test("The network's own failures are unreachable", arguments: [
        URLError.Code.timedOut, .cannotConnectToHost, .networkConnectionLost,
        .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed,
    ])
    func transport(code: URLError.Code) {
        let kind = ConnectionFailureKind.classify(ProviderError.network(underlying: URLError(code)))
        #expect(kind == .unreachable)
        #expect(kind.isWorthRetrying)
    }

    @Test("No path at all is its own kind, and still worth retrying once there is one")
    func noNetwork() {
        let kind = ConnectionFailureKind.classify(
            ProviderError.network(underlying: URLError(.notConnectedToInternet))
        )
        #expect(kind == .noNetwork)
        #expect(kind.isWorthRetrying)
    }

    /// A wrong password answered by the server is not "can't reach the
    /// server", and asking again every few seconds only repeats it.
    @Test("A rejected sign-in is not a reachability problem and is not retried")
    func rejected() {
        let kind = ConnectionFailureKind.classify(ProviderError.notAuthenticated(.wrongCredentials))
        #expect(kind == .rejected)
        #expect(!kind.isWorthRetrying)
        #expect(!kind.isReachabilityProblem)
    }

    @Test("Certificates, walls and unfamiliar servers are answers")
    func answers() {
        #expect(ConnectionFailureKind.classify(ProviderError.tls(.clientCertificateRejected)) == .certificate)
        #expect(ConnectionFailureKind.classify(
            ProviderError.network(underlying: URLError(.serverCertificateUntrusted))
        ) == .certificate)
        #expect(ConnectionFailureKind.classify(
            ProviderError.proxySignInRequired(url: URL(string: "https://x.example")!)
        ) == .proxyWall)
        #expect(ConnectionFailureKind.classify(ProviderError.incompatibleServer(details: nil)) == .incompatible)
        #expect(ConnectionFailureKind.classify(ProviderError.notAuthorized) == .notAuthorized)
        for kind in [ConnectionFailureKind.certificate, .proxyWall, .incompatible, .notAuthorized, .setupIncomplete] {
            #expect(!kind.isWorthRetrying)
        }
    }

    @Test("A five hundred is the server being away; another status is not")
    func serverErrors() {
        #expect(ConnectionFailureKind.classify(
            ProviderError.serverError(code: 503, message: nil, helpURL: nil)
        ) == .unreachable)
        #expect(ConnectionFailureKind.classify(
            ProviderError.serverError(code: 429, message: nil, helpURL: nil)
        ) == .unreachable)
        #expect(ConnectionFailureKind.classify(
            ProviderError.serverError(code: 404, message: nil, helpURL: nil)
        ) == .other)
    }

    @Test("A bare URLError and a foreign error are sorted too")
    func rawErrors() {
        #expect(ConnectionFailureKind.classify(URLError(.timedOut)) == .unreachable)
        #expect(ConnectionFailureKind.classify(CancellationError()) == .other)
    }
}

@Suite("Retrying a failed connection")
struct ConnectionRetryScheduleTests {
    @Test("Quick at first, then settling")
    func delays() {
        #expect(ConnectionRetrySchedule.delay(afterFailures: 0) == .seconds(3))
        #expect(ConnectionRetrySchedule.delay(afterFailures: 1) == .seconds(10))
        #expect(ConnectionRetrySchedule.delay(afterFailures: 2) == .seconds(30))
        #expect(ConnectionRetrySchedule.delay(afterFailures: 3) == .seconds(60))
        #expect(ConnectionRetrySchedule.delay(afterFailures: 50) == .seconds(60))
    }

    @Test("A loop runs only for a network failure, online, with a path")
    func whenItRuns() {
        #expect(ConnectionRetrySchedule.shouldRun(failure: .unreachable, offlineByChoice: false, pathSatisfied: true))
        #expect(!ConnectionRetrySchedule.shouldRun(failure: .unreachable, offlineByChoice: true, pathSatisfied: true))
        #expect(!ConnectionRetrySchedule.shouldRun(failure: .unreachable, offlineByChoice: false, pathSatisfied: false))
        #expect(!ConnectionRetrySchedule.shouldRun(failure: .rejected, offlineByChoice: false, pathSatisfied: true))
        #expect(!ConnectionRetrySchedule.shouldRun(failure: .proxyWall, offlineByChoice: false, pathSatisfied: true))
    }

    /// The claim: a connection that failed once, on a network that then
    /// stayed exactly as it was, is asked again within the schedule and
    /// stops being asked when it comes back.
    @MainActor
    @Test("A failed connection is retried on the schedule until it recovers")
    func retriesUntilRecovered() async {
        var failing = true
        var attempts = 0
        var slept: [Duration] = []
        await ConnectionRetrySchedule.run(
            sleep: { slept.append($0) },
            isStillFailing: { failing },
            attempt: {
                attempts += 1
                if attempts == 3 { failing = false }
            }
        )
        #expect(attempts == 3)
        #expect(
            slept == [.seconds(3), .seconds(10), .seconds(30), .seconds(60)],
            "waited before every attempt and once more before seeing it recovered"
        )
    }

    @MainActor
    @Test("A connection that came back by itself ends the loop without another request")
    func recoveredByItself() async {
        var attempts = 0
        await ConnectionRetrySchedule.run(
            sleep: { _ in },
            isStillFailing: { false },
            attempt: { attempts += 1 }
        )
        #expect(attempts == 0)
    }

    @MainActor
    @Test("Cancelling ends the loop")
    func cancelled() async {
        var attempts = 0
        let task = Task { @MainActor in
            await ConnectionRetrySchedule.run(
                sleep: { _ in try await Task.sleep(for: .seconds(60)) },
                isStillFailing: { true },
                attempt: { attempts += 1 }
            )
        }
        task.cancel()
        await task.value
        #expect(attempts == 0)
    }
}

@Suite("What a refresh of the address does")
struct EndpointRefreshPlanTests {
    typealias Plan = EndpointRefreshPlan

    @Test("A connection being built is left to choose for itself")
    func connecting() {
        #expect(Plan.action(phase: .connecting, addressMoved: true, includingIdle: true) == .skip)
    }

    @Test("Idle is left alone, unless the caller is going online")
    func idle() {
        #expect(Plan.action(phase: .idle, addressMoved: true, includingIdle: false) == .skip)
        #expect(Plan.action(phase: .idle, addressMoved: false, includingIdle: true) == .fullTest)
    }

    @Test("A failed connection is tested whether or not the address moved")
    func failed() {
        #expect(Plan.action(phase: .failed, addressMoved: false, includingIdle: false) == .fullTest)
        #expect(Plan.action(phase: .failed, addressMoved: true, includingIdle: false) == .fullTest)
    }

    /// network-offline-06: the one address of a LAN-only server never moves,
    /// so "same address" used to mean "nothing to learn".
    @Test("A good connection on the same address is checked briefly, not trusted")
    func sameAddress() {
        #expect(Plan.action(phase: .connected, addressMoved: false, includingIdle: false) == .quickCheck)
        #expect(Plan.action(phase: .connected, addressMoved: true, includingIdle: false) == .fullTest)
    }
}

@Suite("Going online")
struct GoOnlinePlanTests {
    @Test("With a provider and an endpoint it refreshes instead of rebuilding the stack")
    func refreshes() {
        #expect(GoOnlinePlan.action(hasProvider: true, hasEndpoint: true) == .refresh)
    }

    @Test("Without them it connects")
    func connects() {
        #expect(GoOnlinePlan.action(hasProvider: false, hasEndpoint: false) == .connect)
        #expect(GoOnlinePlan.action(hasProvider: true, hasEndpoint: false) == .connect)
    }
}

@Suite("Questions with a deadline")
struct DeadlineTests {
    @Test("An answer inside the deadline is returned")
    func answers() async {
        let outcome = await Deadline.run(within: .seconds(5)) { 42 }
        guard case .value(let value) = outcome else { Issue.record("expected a value"); return }
        #expect(value == 42)
    }

    @Test("An error inside the deadline is returned")
    func errors() async {
        let outcome = await Deadline.run(within: .seconds(5)) { () async throws -> Int in
            throw URLError(.timedOut)
        }
        guard case .failed(let error) = outcome else { Issue.record("expected a failure"); return }
        #expect((error as? URLError)?.code == .timedOut)
    }

    /// The trap this is written to avoid: a deadline that waits out the work.
    @Test("The caller is released at the deadline even by work that ignores cancellation")
    func releasesAtTheDeadline() async {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: .milliseconds(100)) { () async throws -> Int in
            await Task { try? await Task.sleep(for: .seconds(2)) }.value
            return 1
        }
        let took = ContinuousClock.now - started
        guard case .timedOut = outcome else { Issue.record("expected a timeout"); return }
        #expect(took < .seconds(1), "waited \(took)")
    }
}

@Suite("Asking whether the server still answers")
struct ReachabilityCheckTests {
    @Test("An answer is an answer")
    func answered() async {
        let verdict = await ReachabilityCheck.run(deadline: .seconds(2)) { "ok" }
        guard case .answered(let value) = verdict else { Issue.record("expected an answer"); return }
        #expect(value == "ok")
    }

    /// One miss is a busy server or a handover; two are a connection gone.
    @Test("One timeout is forgiven and a second answer counts")
    func oneMissIsForgiven() async {
        let calls = Mutex(0)
        let verdict = await ReachabilityCheck.run(
            deadline: .seconds(2), pause: .milliseconds(1)
        ) { () async throws -> Int in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { throw ProviderError.network(underlying: URLError(.timedOut)) }
            return call
        }
        guard case .answered(let value) = verdict else { Issue.record("expected an answer"); return }
        #expect(value == 2)
    }

    @Test("Two misses in a row are unreachable")
    func twoMisses() async {
        let calls = Mutex(0)
        let verdict = await ReachabilityCheck.run(
            deadline: .seconds(2), pause: .milliseconds(1)
        ) { () async throws -> Int in
            calls.withLock { $0 += 1 }
            throw ProviderError.network(underlying: URLError(.cannotConnectToHost))
        }
        guard case .unreachable(let error) = verdict else { Issue.record("expected unreachable"); return }
        #expect(calls.withLock { $0 } == 2)
        #expect(error != nil)
    }

    @Test("A silent server is a miss, not a hang")
    func silence() async {
        let started = ContinuousClock.now
        let verdict = await ReachabilityCheck.run(
            deadline: .milliseconds(80), pause: .milliseconds(1)
        ) { () async throws -> Int in
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        guard case .unreachable = verdict else { Issue.record("expected unreachable"); return }
        // Far inside the thirty seconds the work would take; generous because
        // the whole suite runs under load.
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// An answer is a verdict at once: repeating it a second later would only
    /// ask a server that has said no.
    @Test("A refusal is not repeated")
    func refusal() async {
        let calls = Mutex(0)
        let verdict = await ReachabilityCheck.run(
            deadline: .seconds(2), pause: .milliseconds(1)
        ) { () async throws -> Int in
            calls.withLock { $0 += 1 }
            throw ProviderError.notAuthenticated(.wrongCredentials)
        }
        guard case .answeredBadly = verdict else { Issue.record("expected a bad answer"); return }
        #expect(calls.withLock { $0 } == 1)
    }
}

@Suite("Read-ahead depth")
struct ReadAheadTests {
    /// playback-28: fifteen ahead on Wi-Fi, then out of the door; the setting
    /// is three, and the fourth song must not be fetched.
    @Test("The depth is applied at each song, so leaving Wi-Fi stops the pass")
    func depthChangesMidPass() {
        var allowed = 15
        var fetched: [Int] = []
        for offset in 0..<15 {
            if offset == 3 { allowed = 3 } // the phone left the house
            guard ReadAhead.mayFetch(offset: offset, allowedDepth: allowed) else { break }
            fetched.append(offset)
        }
        #expect(fetched == [0, 1, 2])
    }

    @Test("The next song is always allowed, whatever the setting")
    func nextSongIsAlwaysAllowed() {
        #expect(ReadAhead.mayFetch(offset: 0, allowedDepth: 0))
        #expect(!ReadAhead.mayFetch(offset: 1, allowedDepth: 0))
        #expect(!ReadAhead.mayFetch(offset: 1, allowedDepth: 1))
        #expect(ReadAhead.mayFetch(offset: 1, allowedDepth: 2))
    }
}
