import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

/// What the download queue does about a failure (D-11, D-17), decided in one
/// place the phone and the watch share.
@Suite("Stress: failure classification")
struct StressDownloadsClassificationTests {

    private func network(_ code: URLError.Code) -> BackgroundDownloadFailure {
        .server(.network(underlying: URLError(code)))
    }

    private func http(_ code: Int) -> BackgroundDownloadFailure {
        .server(.serverError(code: code, message: "HTTP \(code)", helpURL: nil))
    }

    // MARK: A transfer that failed

    @Test("D-17: no connection is waited out, not counted against the song")
    func noConnectionWaits() {
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive] {
            #expect(TransferFailureClassifier.disposition(for: network(code), isConversion: false) == .waitForNetwork)
        }
    }

    @Test("D-17: a dropped or timed-out transfer is worth another go")
    func flakyTransferRetries() {
        for code in [URLError.Code.networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed] {
            #expect(TransferFailureClassifier.disposition(for: network(code), isConversion: false) == .retryable)
        }
    }

    @Test("D-17: 401 is final for everything; 403 and 404 are final for an original only")
    func authAndNotFound() {
        #expect(TransferFailureClassifier.disposition(for: http(401), isConversion: false) == .terminal)
        #expect(TransferFailureClassifier.disposition(for: http(401), isConversion: true) == .terminal)
        for status in [403, 404] {
            #expect(TransferFailureClassifier.disposition(for: http(status), isConversion: false) == .terminal)
            // A busy Plex answers a conversion with these; the retry exists for that.
            #expect(TransferFailureClassifier.disposition(for: http(status), isConversion: true) == .retryable)
        }
        #expect(TransferFailureClassifier.disposition(for: http(400), isConversion: true) == .retryable)
    }

    @Test("D-17: a server having a moment is retried")
    func serverErrorsRetry() {
        for status in [408, 429, 500, 502, 503, 504] {
            #expect(TransferFailureClassifier.disposition(for: http(status), isConversion: false) == .retryable)
        }
    }

    @Test("D-17: a certificate problem is final and a full disk stops the queue")
    func tlsAndStorage() {
        #expect(TransferFailureClassifier.disposition(for: .server(.tls(.pinMismatch(expected: "a", actual: "b"))), isConversion: false) == .terminal)
        #expect(TransferFailureClassifier.disposition(for: .storage("nope"), isConversion: false) == .terminal)
        #expect(TransferFailureClassifier.disposition(for: .outOfSpace("full"), isConversion: false) == .storageFull)
    }

    @Test("D-03: something that is not a song is final for an original and retried for a conversion")
    func notAudio() {
        #expect(TransferFailureClassifier.disposition(for: .notAudio(.empty), isConversion: false) == .terminal)
        #expect(TransferFailureClassifier.disposition(for: .notAudio(.empty), isConversion: true) == .retryable)
        #expect(TransferFailureClassifier.disposition(for: .notAudio(.lengthMismatch(expected: 10, actual: 3)), isConversion: false) == .terminal)
    }

    @Test("D-09: a web page in the way, or a redirect off the server, is a sign-in wall")
    func wall() {
        #expect(TransferFailureClassifier.disposition(for: .notAudio(.markup), isConversion: false) == .proxyWall)
        #expect(TransferFailureClassifier.disposition(for: .notAudio(.textual(contentType: "text/html; charset=utf-8")), isConversion: true) == .proxyWall)
        #expect(TransferFailureClassifier.disposition(for: .notAudio(.textual(contentType: "application/json")), isConversion: false) == .terminal)
        #expect(TransferFailureClassifier.disposition(for: .foreignHost(URL(string: "https://idp.example/login")!), isConversion: false) == .proxyWall)
        #expect(TransferFailureClassifier.disposition(for: .server(.proxySignInRequired(url: URL(string: "https://a.example")!)), isConversion: false) == .proxyWall)
    }

    // MARK: Preparation: asking the server how to fetch a song

    @Test("D-11: every way of not reaching the server parks the song instead of failing it")
    func preparationOffline() {
        for code in [
            URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotConnectToHost, .dataNotAllowed, .cannotFindHost, .dnsLookupFailed,
        ] {
            #expect(TransferFailureClassifier.disposition(forPreparation: ProviderError.network(underlying: URLError(code))) == .waitForNetwork)
            #expect(TransferFailureClassifier.disposition(forPreparation: URLError(code)) == .waitForNetwork)
        }
    }

    @Test("D-11: a real refusal to say how to fetch a song is final")
    func preparationRefused() {
        #expect(TransferFailureClassifier.disposition(forPreparation: ProviderError.notAuthenticated(.wrongCredentials)) == .terminal)
        #expect(TransferFailureClassifier.disposition(forPreparation: ProviderError.notAuthorized) == .terminal)
        #expect(TransferFailureClassifier.disposition(forPreparation: ProviderError.notFound) == .terminal)
        #expect(TransferFailureClassifier.disposition(forPreparation: ProviderError.serverError(code: 500, message: nil, helpURL: nil)) == .retryable)
        #expect(TransferFailureClassifier.disposition(forPreparation: ProviderError.proxySignInRequired(url: URL(string: "https://a.example")!)) == .proxyWall)
    }

    @Test("D-11: something unrecognised is treated as the server having a moment, which the attempt count bounds")
    func preparationUnknown() {
        struct Odd: Error {}
        #expect(TransferFailureClassifier.disposition(forPreparation: Odd()) == .retryable)
    }

    // MARK: Out of space

    @Test("D-17: a full disk is recognised however it is spelled")
    func outOfSpace() {
        #expect(TransferFailureClassifier.isOutOfSpace(URLError(.cannotWriteToFile)))
        #expect(TransferFailureClassifier.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: 640)))
        #expect(TransferFailureClassifier.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ])
        #expect(TransferFailureClassifier.isOutOfSpace(wrapped))
        #expect(!TransferFailureClassifier.isOutOfSpace(URLError(.timedOut)))
        #expect(!TransferFailureClassifier.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: 4)))
    }
}
