import Foundation
import Testing
@testable import PleviDomain

/// Telling "this playlist is gone" apart from "the server is having a moment", on both backends.
@Suite("Whether an error means a playlist is gone")
struct PlaylistGoneTests {
    private func meansGone(_ error: ProviderError) -> Bool { error.meansNotFound }

    /// Plex answers a request for a deleted playlist with HTTP 404, which the
    /// client turns into a server error carrying the code.
    @Test("Plex's 404 means gone")
    func plexNotFound() {
        #expect(meansGone(.serverError(code: 404, message: "not found", helpURL: nil)))
    }

    /// Subsonic answers 200 with error code 70 in the body, which the client
    /// turns into `notFound` — a different case entirely, and the one that was
    /// being missed.
    @Test("Subsonic's not-found means gone")
    func subsonicNotFound() {
        #expect(meansGone(.notFound))
    }

    @Test("A server having a moment does not mean gone")
    func transientFailures() {
        #expect(!meansGone(.serverError(code: 500, message: "server error", helpURL: nil)))
        #expect(!meansGone(.serverError(code: 503, message: "unavailable", helpURL: nil)))
        #expect(!meansGone(.serverError(code: nil, message: "status failed", helpURL: nil)))
        #expect(!meansGone(.notAuthorized))
        #expect(!meansGone(.malformedResponse(details: "nonsense")))
    }

    /// The one that would be worst: a sign-in that has expired must never be
    /// read as every downloaded playlist having been deleted at once.
    @Test("Expired credentials do not mean gone")
    func credentials() {
        #expect(!meansGone(.notAuthenticated(.wrongCredentials)))
    }
}
