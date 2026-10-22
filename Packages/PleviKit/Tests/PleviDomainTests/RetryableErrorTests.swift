import Foundation
import Testing
@testable import PleviDomain

/// Which failures are worth asking again about.
@Suite("Whether a failure is worth another go")
struct RetryableErrorTests {
    @Test("A dropped connection is worth retrying", arguments: [
        URLError.Code.networkConnectionLost,
        .timedOut,
        .cannotConnectToHost,
        .notConnectedToInternet,
        .dnsLookupFailed,
        .cannotFindHost,
        .resourceUnavailable,
        .secureConnectionFailed,
    ])
    func transportFailures(code: URLError.Code) {
        #expect(ProviderError.network(underlying: URLError(code)).isWorthRetrying)
    }

    /// The important half. Anything the server said in words is an answer,
    /// and asking again only puts the same question twice — slowly.
    @Test("An answer from the server is not")
    func realAnswers() {
        #expect(!ProviderError.notFound.isWorthRetrying)
        #expect(!ProviderError.notAuthorized.isWorthRetrying)
        #expect(!ProviderError.serverError(code: 404, message: "gone", helpURL: nil).isWorthRetrying)
        #expect(!ProviderError.serverError(code: 500, message: "oops", helpURL: nil).isWorthRetrying)
        #expect(!ProviderError.serverError(code: 501, message: "no", helpURL: nil).isWorthRetrying)
        #expect(!ProviderError.serverError(code: 403, message: "no", helpURL: nil).isWorthRetrying)
        #expect(!ProviderError.notAuthenticated(.wrongCredentials).isWorthRetrying)
        #expect(!ProviderError.malformedResponse(details: "nonsense").isWorthRetrying)
    }

    /// A gateway in front of the server that could not reach it is not the
    /// server answering: worth the same second go as a dropped connection.
    @Test("A gateway error is a blip, not an answer")
    func gatewayErrors() {
        for code in [502, 503, 504] {
            #expect(ProviderError.serverError(code: code, message: "bad gateway", helpURL: nil).isWorthRetrying, "\(code)")
        }
    }

    /// A request we cancelled ourselves — skipping to the next song — must
    /// not be retried, or a skip would drag the song you left behind back.
    @Test("A cancelled request is not retried")
    func cancellation() {
        #expect(!ProviderError.network(underlying: URLError(.cancelled)).isWorthRetrying)
    }

    /// Trust failures are a decision, not a blip.
    @Test("A refused certificate is not retried")
    func trust() {
        #expect(!ProviderError.tls(.clientCertificateRejected).isWorthRetrying)
        #expect(!ProviderError.network(underlying: URLError(.serverCertificateUntrusted)).isWorthRetrying)
    }
}
