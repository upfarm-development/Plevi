import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

@Suite("What the watch queue does about a failure (downloads-14, downloads-15)")
struct WatchDownloadRecoveryTests {
    // MARK: downloads-14: the link goes at a song boundary

    @Test("No network while asking the server keeps the song queued, uncharged, and waits")
    func noNetworkWaits() {
        let disposition = TransferFailureClassifier.disposition(
            forPreparation: ProviderError.network(underlying: URLError(.notConnectedToInternet))
        )
        #expect(disposition == .waitForNetwork)
        #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: 0)
            == .retry(after: WatchDownloadRecovery.networkWait, chargesAttempt: false))
        // However often it happens: nothing is wrong with the song.
        #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: 50)
            == .retry(after: WatchDownloadRecovery.networkWait, chargesAttempt: false))
    }

    @Test("A timeout while asking the server is read as no network, not as a refusal")
    func timeoutWhilePreparing() {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost] {
            let disposition = TransferFailureClassifier.disposition(
                forPreparation: ProviderError.network(underlying: URLError(code))
            )
            #expect(disposition == .waitForNetwork, "\(code)")
        }
    }

    @Test("A server that answers 401 or not-found for an original fails the song at once")
    func refusalsAreTerminal() {
        for error: ProviderError in [
            .notAuthenticated(.wrongCredentials), .notFound,
            .serverError(code: 404, message: "no", helpURL: nil),
            .serverError(code: 401, message: "no", helpURL: nil),
        ] {
            let disposition = TransferFailureClassifier.disposition(forPreparation: error)
            #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: 0) == .fail)
        }
    }

    @Test("A server having a moment is retried with growing pauses, then failed")
    func retryThenGiveUp() {
        let disposition = TransferFailureClassifier.disposition(
            forPreparation: ProviderError.serverError(code: 503, message: "busy", helpURL: nil)
        )
        #expect(disposition == .retryable)
        #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: 0) == .retry(after: 5, chargesAttempt: true))
        #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: 1) == .retry(after: 20, chargesAttempt: true))
        #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: 2) == .retry(after: 60, chargesAttempt: true))
        #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: WatchDownloadRecovery.attemptLimit) == .fail)
    }

    @Test("A conversion the server did not finish is asked for again; an original is not")
    func conversionVersusOriginal() {
        let bad = BackgroundDownloadFailure.notAudio(.empty)
        #expect(TransferFailureClassifier.disposition(for: bad, isConversion: true) == .retryable)
        #expect(TransferFailureClassifier.disposition(for: bad, isConversion: false) == .terminal)
    }

    // MARK: downloads-15: a full watch

    @Test("Out of space holds the queue once instead of failing every song")
    func outOfSpaceHolds() {
        let disposition = TransferFailureClassifier.disposition(
            for: .outOfSpace("no room"), isConversion: false
        )
        #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: 0) == .holdQueue(.storageFull))
        #expect(WatchDownloadRecovery.message(for: .storageFull).contains("full"))
    }

    @Test("A sign-in wall holds the queue and says to sign in")
    func proxyWallHolds() {
        let disposition = TransferFailureClassifier.disposition(
            for: .foreignHost(URL(string: "https://login.example.com/")!), isConversion: false
        )
        #expect(WatchDownloadRecovery.decide(disposition, attemptsUsed: 0) == .holdQueue(.proxyWall))
        #expect(WatchDownloadRecovery.message(for: .proxyWall).contains("sign in") ||
                WatchDownloadRecovery.message(for: .proxyWall).contains("Sign in"))
    }

    @Test("Room: songs are taken in order until one would not fit past the margin")
    func roomCountsInOrder() {
        let mb: Int64 = 1_000_000
        // 500 MB free, 200 MB kept back: 300 MB usable.
        let fits = WatchDownloadRoom.countThatFit(
            sizes: [100 * mb, 100 * mb, 90 * mb, 50 * mb], free: 500 * mb
        )
        #expect(fits == 3)
    }

    @Test("Room: an unknown size is not free")
    func roomAssumesUnknownSizes() {
        let mb: Int64 = 1_000_000
        // Each unknown song is taken as 12 MB: 50 MB usable holds four.
        let fits = WatchDownloadRoom.countThatFit(
            sizes: Array(repeating: nil, count: 10), free: 250 * mb
        )
        #expect(fits == 4)
    }

    @Test("Room: a watch with less than the margin takes nothing")
    func roomBelowMargin() {
        #expect(WatchDownloadRoom.countThatFit(sizes: [1], free: 100_000_000) == 0)
    }

    // MARK: downloads-18: a lowered wrist

    @Test("A watchdog that slept through a suspension does not read the silence as a stall")
    func suspensionIsNotSilence() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        // Awake: ticks thirty seconds apart.
        #expect(!WatchDownloadRecovery.sweepWasStarved(since: t0, now: t0.addingTimeInterval(31)))
        #expect(!WatchDownloadRecovery.sweepWasStarved(since: t0, now: t0.addingTimeInterval(60)))
        // Wrist down for eight minutes: the next tick is far overdue.
        #expect(WatchDownloadRecovery.sweepWasStarved(since: t0, now: t0.addingTimeInterval(480)))
        // Nothing to compare against on the very first look.
        #expect(!WatchDownloadRecovery.sweepWasStarved(since: nil, now: t0))
    }
}
