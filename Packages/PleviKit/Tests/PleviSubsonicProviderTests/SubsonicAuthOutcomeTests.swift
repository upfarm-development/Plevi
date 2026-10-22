import Foundation
import Synchronization
import Testing
import PleviDomain
import PleviTransport
@testable import PleviSubsonicProvider

/// A `var` captured by an `@Sendable` closure needs its own synchronization
/// under strict concurrency, even in a test where the closure only ever
/// runs before the `await` it is checked after.
private final class OutcomeBox: Sendable {
    private let stored = Mutex<[SubsonicClient.AuthOutcome]>([])

    func append(_ outcome: SubsonicClient.AuthOutcome) {
        stored.withLock { $0.append(outcome) }
    }

    var all: [SubsonicClient.AuthOutcome] {
        stored.withLock { $0 }
    }
}

/// what `CredentialHealth` is fed from — a server error 40 in a decoded
/// envelope, never a plain HTTP 401 (which never proves Subsonic itself looked at the credentials),
/// and whether the request that got through…
@Suite struct SubsonicDecodePayloadOutcomeTests {
    private let url = URL(string: "https://music.example.com/rest/ping.view")!

    private func envelope(status: String, error: (code: Int, message: String)? = nil) -> Data {
        var body: [String: Any] = ["status": status, "version": "1.16.1"]
        if let error {
            body["error"] = ["code": error.code, "message": error.message]
        }
        return try! JSONSerialization.data(withJSONObject: ["subsonic-response": body])
    }

    @Test func errorCode40FiresRejection() {
        var rejected = false
        #expect(throws: (any Error).self) {
            try SubsonicClient.decodePayload(
                envelope(status: "failed", error: (40, "Wrong username or password")),
                httpStatus: 200, url: url,
                onServerRejection: { rejected = true }
            )
        }
        #expect(rejected)
    }

    @Test func aPlain401NeverReachesTheRejectionHook() {
        var rejected = false
        #expect(throws: ProviderError.notAuthenticated(.wrongCredentials)) {
            try SubsonicClient.decodePayload(
                Data(), httpStatus: 401, url: url,
                onServerRejection: { rejected = true }
            )
        }
        #expect(!rejected)
    }

    /// 41-44 are about the auth *method*, not the password — reporting them
    /// as a rejection would mark a healthy credential as wrong.
    @Test func otherAuthErrorCodesDoNotFireRejection() {
        var rejected = false
        #expect(throws: (any Error).self) {
            try SubsonicClient.decodePayload(
                envelope(status: "failed", error: (44, "Invalid API key")),
                httpStatus: 200, url: url,
                onServerRejection: { rejected = true }
            )
        }
        #expect(!rejected)
    }

    @Test func successNeverFiresRejection() throws {
        var rejected = false
        _ = try SubsonicClient.decodePayload(
            envelope(status: "ok"), httpStatus: 200, url: url,
            onServerRejection: { rejected = true }
        )
        #expect(!rejected)
    }
}

/// End-to-end through `SubsonicClient.call(_:_:)`, over `FakeSubsonicServer`
/// (real auth validation, always HTTP 200 — a lower layer than the 401 case
/// above, which a fake OpenSubsonic server can never itself produce).
@Suite struct SubsonicClientAuthOutcomeTests {
    @Test func correctCredentialsReportAcceptedAndDirect() async throws {
        let server = FakeSubsonicServer()
        let outcomes = OutcomeBox()
        let client = SubsonicClient(
            baseURL: URL(string: "https://fake.example")!,
            credentials: .usernamePassword(username: server.username, password: server.password),
            transport: server,
            onAuthOutcome: { outcomes.append($0) }
        )
        _ = try await client.call("ping")
        #expect(outcomes.all == [.accepted(direct: true)])
    }

    @Test func wrongPasswordReportsRejected() async {
        let server = FakeSubsonicServer()
        let outcomes = OutcomeBox()
        let client = SubsonicClient(
            baseURL: URL(string: "https://fake.example")!,
            credentials: .usernamePassword(username: server.username, password: "not-the-password"),
            transport: server,
            onAuthOutcome: { outcomes.append($0) }
        )
        await #expect(throws: (any Error).self) { try await client.call("ping") }
        #expect(outcomes.all == [.rejected])
    }

    /// A custom header makes a call "not direct" even when the transport
    /// itself reports no proxy session — the client's own knowledge, which
    /// the transport cannot see.
    @Test func aCustomHeaderReportsAcceptedButNotDirect() async throws {
        let server = FakeSubsonicServer()
        let outcomes = OutcomeBox()
        let client = SubsonicClient(
            baseURL: URL(string: "https://fake.example")!,
            credentials: .usernamePassword(username: server.username, password: server.password),
            transport: server,
            customHeaders: ["CF-Access-Client-Id": "abc"],
            onAuthOutcome: { outcomes.append($0) }
        )
        _ = try await client.call("ping")
        #expect(outcomes.all == [.accepted(direct: false)])
    }
}
