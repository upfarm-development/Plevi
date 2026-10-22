import Foundation
import Testing
@testable import PleviDomain

@Suite("Credentials never reach a log line")
struct LogRedactionTests {
    private static let stream = "https://music.example.com/rest/stream.view"

    @Test("Every sensitive query key is masked", arguments: [
        "u", "t", "s", "p", "apiKey", "api_key", "token", "password", "auth", "jwt", "X-Plex-Token",
    ])
    func everyKeyIsMasked(key: String) {
        let text = "Could not load \(Self.stream)?id=42&\(key)=SECRETVALUE&v=1.16.1&c=Plevi"
        let scrubbed = LogRedaction.scrub(text)
        #expect(!scrubbed.contains("SECRETVALUE"))
        // The rest of the line is untouched.
        #expect(scrubbed.contains("id=42"))
        #expect(scrubbed.contains("v=1.16.1"))
        #expect(scrubbed.contains("c=Plevi"))
    }

    @Test("The first parameter after the question mark is masked too")
    func theFirstParameterIsMasked() {
        let scrubbed = LogRedaction.scrub("\(Self.stream)?u=alice&t=deadbeef&s=salty")
        #expect(!scrubbed.contains("alice"))
        #expect(!scrubbed.contains("deadbeef"))
        #expect(!scrubbed.contains("salty"))
    }

    @Test("A parameter that merely ends in a key letter is left alone")
    func lookalikesAreLeftAlone() {
        let text = "\(Self.stream)?requests=5&subset=1&format=mp3&maxBitRate=320"
        #expect(LogRedaction.scrub(text) == text)
    }

    @Test("Percent-encoded URLs nested in another URL are masked")
    func encodedFormsAreMasked() {
        let text = "https://proxy/redirect?to=https%3A%2F%2Fhost%2Frest%2Fping%3Fu%3Dalice%26t%3DSECRETTOKEN%26s%3Dsalty%26v%3D1"
        let scrubbed = LogRedaction.scrub(text)
        #expect(!scrubbed.contains("alice"))
        #expect(!scrubbed.contains("SECRETTOKEN"))
        #expect(!scrubbed.contains("salty"))
        #expect(scrubbed.contains("v%3D1"))
    }

    @Test("Userinfo in an address is masked")
    func userinfoIsMasked() {
        let scrubbed = LogRedaction.scrub("failed https://alice:hunter2@music.example.com/rest/ping")
        #expect(!scrubbed.contains("hunter2"))
        #expect(!scrubbed.contains("alice"))
        #expect(scrubbed.contains("music.example.com"))
    }

    @Test("A header printed as text is masked")
    func headersAreMasked() {
        let scrubbed = LogRedaction.scrub("headers: X-Plex-Token: PLEXSECRET, Accept: json")
        #expect(!scrubbed.contains("PLEXSECRET"))
        #expect(scrubbed.contains("Accept: json"))
    }

    @Test("Ordinary lines pass through unchanged")
    func ordinaryLinesAreUnchanged() {
        let line = "startCurrentTrack: Karma Police — retry 1 in 1.5s (bitrate=320 kbps, host: a.b)"
        #expect(LogRedaction.scrub(line) == line)
    }

    // MARK: Errors

    private func failingURLError(_ code: URLError.Code = .timedOut) -> URLError {
        let url = URL(string: "\(Self.stream)?id=42&u=alice&t=SECRETTOKEN&s=SECRETSALT&apiKey=SECRETKEY&v=1.16.1")!
        return URLError(code, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSURLErrorFailingURLStringErrorKey: url.absoluteString,
            NSLocalizedDescriptionKey: "The request timed out. \(url.absoluteString)",
        ])
    }

    private func assertClean(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for secret in ["alice", "SECRETTOKEN", "SECRETSALT", "SECRETKEY"] {
            #expect(!text.contains(secret), "\(secret) leaked: \(text)", sourceLocation: sourceLocation)
        }
    }

    @Test("A network ProviderError interpolates without its failing URL's credentials")
    func providerErrorInterpolatesSafely() {
        let error = ProviderError.network(underlying: failingURLError())
        assertClean("\(error)")
        assertClean(error.description)
        assertClean(String(describing: error))
        // Still useful: the code, and where it happened.
        #expect(error.description.contains("-1001"))
        #expect(error.description.contains("music.example.com"))
    }

    @Test("Every ProviderError case that carries text scrubs it")
    func otherCasesScrub() {
        let leaky = "\(Self.stream)?u=alice&t=SECRETTOKEN&s=SECRETSALT&apiKey=SECRETKEY"
        let url = URL(string: leaky)!
        let errors: [ProviderError] = [
            .serverError(code: 500, message: leaky, helpURL: url),
            .malformedResponse(details: leaky),
            .incompatibleServer(details: leaky),
            .conflict(details: leaky),
            .missingParameter(name: leaky),
            .proxySignInRequired(url: url),
        ]
        for error in errors { assertClean("\(error)") }
    }

    @Test("describe handles a bare URLError and an arbitrary error alike")
    func describeCoversBareErrors() {
        assertClean(LogRedaction.describe(failingURLError(.networkConnectionLost)))
        assertClean(LogRedaction.describe(failingURLError() as any Error))

        struct Wrapped: Error { let url: URL }
        let wrapped = Wrapped(url: URL(string: "\(Self.stream)?u=alice&t=SECRETTOKEN&s=SECRETSALT&apiKey=SECRETKEY")!)
        assertClean(LogRedaction.describe(wrapped))

        // NSError-backed URLError, as it arrives from URLSession.
        let ns = failingURLError() as NSError
        assertClean(LogRedaction.describe(ns))
    }

    @Test("The redactor and the log scrubber agree on which keys are sensitive")
    func oneKeyList() {
        for key in LogRedaction.sensitiveQueryKeys {
            #expect(!LogRedaction.scrub("http://h/x?a=1&\(key)=SECRETVALUE").contains("SECRETVALUE"), "\(key)")
        }
    }
}
