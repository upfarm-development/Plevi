import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// Answers the sign-in poll from a script, one entry per request.
private actor PollScript: HTTPTransport {
    enum Step: Sendable {
        case fail(URLError.Code)
        case status(Int, String)
    }

    private var steps: [Step]
    private(set) var polls = 0

    init(_ steps: [Step]) { self.steps = steps }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        polls += 1
        // Past the end of the script it keeps answering "not yet".
        let step = steps.isEmpty ? .status(200, #"{"id":1,"code":"A","authToken":null}"#) : steps.removeFirst()
        switch step {
        case .fail(let code):
            throw ProviderError.network(underlying: URLError(code))
        case .status(let status, let json):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
    }
}

private let approved = #"{"id":1,"code":"A","authToken":"tok"}"#

/// One poll failing is not the sign-in failing. A user who has approved the
/// PIN in a browser must not be sent round again by a dropped connection.
@Suite("Plex sign-in polling on a flaky link")
struct PlexSignInRecoveryTests {
    private func poll(_ steps: [PollScript.Step]) async throws -> (String?, Int) {
        let script = PollScript(steps)
        let poller = PlexSignInPoller(interval: .milliseconds(1), timeout: .seconds(30))
        let token = try await poller.awaitToken(
            for: PlexPin(id: 1, code: "A"),
            client: PlexClient(identity: PlexIdentity(clientIdentifier: "c"), transport: script)
        )
        return (token, await script.polls)
    }

    @Test("A timeout on the first poll and a token on the second returns the token")
    func transientFailureIsSurvived() async throws {
        let (token, polls) = try await poll([.fail(.timedOut), .status(200, approved)])
        #expect(token == "tok")
        #expect(polls == 2)
    }

    @Test("A dropped connection, a busy plex.tv and a garbled reply are all survived")
    func manyKindsOfTransientFailure() async throws {
        let (token, _) = try await poll([
            .fail(.networkConnectionLost),
            .status(503, "busy"),
            .status(429, "slow down"),
            .status(200, "not json"),
            .status(200, approved),
        ])
        #expect(token == "tok")
    }

    @Test("A success in between resets the count, so failures spread over a long wait never add up")
    func successResetsTheCount() async throws {
        let notYet = PollScript.Step.status(200, #"{"id":1,"code":"A","authToken":null}"#)
        var steps: [PollScript.Step] = []
        for _ in 0..<4 {
            steps += [.fail(.timedOut), .fail(.timedOut), .fail(.timedOut), .fail(.timedOut), notYet]
        }
        steps.append(.status(200, approved))
        let (token, _) = try await poll(steps)
        #expect(token == "tok")
    }

    @Test("A run of failures is believed")
    func aRunOfFailuresEnds() async {
        let script = Array(repeating: PollScript.Step.fail(.timedOut), count: 10)
        await #expect(throws: ProviderError.network(underlying: URLError(.timedOut))) {
            _ = try await poll(script)
        }
    }

    @Test("An answer that will not change ends it at once", arguments: [401, 403, 404])
    func refusalEndsAtOnce(status: Int) async {
        let script = PollScript([.status(status, "{}")])
        let poller = PlexSignInPoller(interval: .milliseconds(1), timeout: .seconds(30))
        await #expect(throws: (any Error).self) {
            _ = try await poller.awaitToken(
                for: PlexPin(id: 1, code: "A"),
                client: PlexClient(identity: PlexIdentity(clientIdentifier: "c"), transport: script)
            )
        }
        #expect(await script.polls == 1, "asking again would only hear the same thing")
    }

    @Test("Which errors are worth polling again after")
    func transience() {
        #expect(PlexSignInPoller.isTransient(ProviderError.network(underlying: URLError(.timedOut))))
        #expect(!PlexSignInPoller.isTransient(ProviderError.network(underlying: URLError(.cancelled))))
        #expect(PlexSignInPoller.isTransient(ProviderError.serverError(code: 502, message: nil, helpURL: nil)))
        #expect(PlexSignInPoller.isTransient(ProviderError.serverError(code: 429, message: nil, helpURL: nil)))
        #expect(!PlexSignInPoller.isTransient(ProviderError.serverError(code: 404, message: nil, helpURL: nil)))
        #expect(!PlexSignInPoller.isTransient(ProviderError.notAuthenticated(.wrongCredentials)))
        #expect(!PlexSignInPoller.isTransient(CancellationError()))
    }
}
