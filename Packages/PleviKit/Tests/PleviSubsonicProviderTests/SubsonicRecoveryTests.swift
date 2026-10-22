import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviSubsonicProvider

/// Answers the extension probe and the calls after it as a test scripts, and
/// records how it was asked.
private actor ScriptedTransport: HTTPTransport {
    struct Asked {
        var verb: String
        var method: String
    }

    /// One answer per request, in order for the probe; whatever else is asked
    /// gets the ping answer.
    private var probeAnswers: [@Sendable () async throws -> (Data, Int)]
    private(set) var asked: [Asked] = []

    init(probeAnswers: [@Sendable () async throws -> (Data, Int)]) {
        self.probeAnswers = probeAnswers
    }

    var probeCount: Int { asked.filter { $0.verb == "getOpenSubsonicExtensions" }.count }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let verb = request.url?.lastPathComponent ?? ""
        asked.append(Asked(verb: verb, method: request.httpMethod ?? "GET"))
        let (data, status): (Data, Int)
        if verb == "getOpenSubsonicExtensions" {
            let answer = probeAnswers.isEmpty ? Self.extensions : probeAnswers.removeFirst()
            (data, status) = try await answer()
        } else {
            (data, status) = (Self.ping, 200)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    static let extensions: @Sendable () async throws -> (Data, Int) = {
        (Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonic":true,"openSubsonicExtensions":[{"name":"formPost","versions":[1]},{"name":"transcodeOffset","versions":[1]}]}}"#.utf8), 200)
    }

    static let ping = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.53","openSubsonic":true}}"#.utf8)
}

private func makeClient(_ transport: ScriptedTransport) -> SubsonicClient {
    SubsonicClient(
        baseURL: URL(string: "https://music.example")!,
        credentials: .apiKey("k"),
        transport: transport
    )
}

/// The extension probe is not a latch that one bad moment can set for good.
@Suite("Extension probe on a flaky link")
struct SubsonicProbeRecoveryTests {
    /// The bug: one timeout on the first call cached "no extensions" for the
    /// life of the client, so lyrics offsets and form POST stayed off however
    /// well the connection behaved afterwards.
    @Test("A probe that could not be answered is asked again by the next connection test")
    func inconclusiveProbeIsRetried() async {
        let transport = ScriptedTransport(probeAnswers: [
            { throw ProviderError.network(underlying: URLError(.notConnectedToInternet)) },
        ])
        let client = makeClient(transport)

        let first = await client.serverExtensions()
        #expect(first.isEmpty, "nothing was learned, so nothing is claimed")

        let second = await client.serverExtensions(retryingInconclusive: true)
        #expect(second.contains("transcodeOffset"))
        #expect(second.contains("formPost"))
        #expect(await transport.probeCount == 2)
    }

    @Test("A definitive answer is kept and never asked for again")
    func definitiveAnswerIsKept() async {
        let transport = ScriptedTransport(probeAnswers: [])
        let client = makeClient(transport)
        _ = await client.serverExtensions()
        _ = await client.serverExtensions(retryingInconclusive: true)
        _ = await client.serverExtensions()
        #expect(await transport.probeCount == 1)
    }

    /// A legacy server answering "no such method" has told us it has no
    /// extensions. That is an answer, and is kept.
    @Test("A server that says it has no extension list is believed")
    func legacyServerIsDefinitive() async {
        let transport = ScriptedTransport(probeAnswers: [{
            (Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#.utf8), 200)
        }])
        let client = makeClient(transport)
        #expect(await client.serverExtensions().isEmpty)
        #expect(await client.serverExtensions(retryingInconclusive: true).isEmpty)
        #expect(await transport.probeCount == 1)
    }

    /// A proxy's own five hundred says nothing about the server behind it.
    @Test("A gateway error is not an answer")
    func gatewayErrorIsInconclusive() async {
        let transport = ScriptedTransport(probeAnswers: [{
            (Data("<html>Bad gateway</html>".utf8), 502)
        }])
        let client = makeClient(transport)
        #expect(await client.serverExtensions().isEmpty)
        #expect(await client.serverExtensions(retryingInconclusive: true).contains("formPost"))
    }

    /// Calls in a run on a dead link must not each pay for a probe.
    @Test("Calls do not re-probe within the cooldown, and the test does")
    func cooldownAppliesToCallsNotToTheTest() async {
        let transport = ScriptedTransport(probeAnswers: [
            { throw ProviderError.network(underlying: URLError(.timedOut)) },
        ])
        let client = makeClient(transport)
        _ = await client.serverExtensions()
        _ = await client.serverExtensions()
        _ = await client.serverExtensions()
        #expect(await transport.probeCount == 1, "the cooldown holds the calls back")
        _ = await client.serverExtensions(retryingInconclusive: true)
        #expect(await transport.probeCount == 2)
    }

    /// The other half of the latch: a probe set before it finished let a
    /// concurrent caller see "probed" with form POST still off, and send its
    /// request as a GET with the credentials in the URL.
    @Test("A call made while the probe is running waits for it and uses form POST")
    func concurrentCallWaitsForTheProbe() async throws {
        let transport = ScriptedTransport(probeAnswers: [{
            try await Task.sleep(for: .milliseconds(150))
            return try await ScriptedTransport.extensions()
        }])
        let client = makeClient(transport)
        async let a: SubsonicPayload = client.call("ping")
        try await Task.sleep(for: .milliseconds(20))
        async let b: SubsonicPayload = client.call("ping")
        _ = try await (a, b)
        let asked = await transport.asked.filter { $0.verb == "ping" }
        #expect(asked.count == 2)
        #expect(asked.allSatisfy { $0.method == "POST" }, "both waited for the probe: \(asked)")
        #expect(await transport.probeCount == 1)
    }

    /// A caller that goes away must not take the probe with it.
    @Test("A cancelled caller does not poison the probe")
    func cancellationDoesNotStickAsAnAnswer() async throws {
        let transport = ScriptedTransport(probeAnswers: [{
            try await Task.sleep(for: .milliseconds(100))
            return try await ScriptedTransport.extensions()
        }])
        let client = makeClient(transport)
        let waiting = Task { await client.serverExtensions() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        _ = await waiting.value
        #expect(await client.serverExtensions().contains("formPost"))
    }
}

/// A proxy in front of a restarting server is not a sign-in wall.
@Suite("Proxy error pages")
struct SubsonicProxyErrorPageTests {
    private let url = URL(string: "https://music.example/rest/ping")!

    @Test("A 502 with an HTML page is the server being away", arguments: [500, 502, 503, 504, 522])
    func gatewayPageIsAServerError(status: Int) {
        #expect(throws: ProviderError.serverError(code: status, message: "HTTP \(status)", helpURL: nil)) {
            _ = try SubsonicClient.decodePayload(
                Data("<!DOCTYPE html><html><body>Bad gateway</body></html>".utf8),
                httpStatus: status,
                mimeType: "text/html",
                url: url
            )
        }
    }

    @Test("Every such page classifies as the server being unreachable", arguments: [502, 503, 504])
    func classifiesAsUnreachable(status: Int) {
        let error = ProviderError.serverError(code: status, message: "HTTP \(status)", helpURL: nil)
        #expect(ConnectionFailureKind.classify(error) == .unreachable)
    }

    /// The other side of the line: a sign-in page on 200, 302's target page,
    /// 401 or 403 is still a wall.
    @Test("The same page on a status a proxy uses for its wall still is one", arguments: [200, 401, 403])
    func wallStillDetected(status: Int) {
        #expect(throws: ProviderError.proxySignInRequired(url: url)) {
            _ = try SubsonicClient.decodePayload(
                Data("<html><body>Sign in</body></html>".utf8),
                httpStatus: status,
                mimeType: "text/html",
                url: url
            )
        }
    }
}
