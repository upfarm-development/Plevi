import Testing
@testable import PleviDomain

@Suite("Skipping a song that cannot be played")
struct StressPlaybackBadTrackTests {
    private static func skip(
        automatic: Bool = true,
        network: Bool = false,
        offline: Bool = false,
        hasNext: Bool = true,
        skips: Int = 0,
        repeatOne: Bool = false
    ) -> Bool {
        BadTrackPolicy.shouldSkip(
            arrivedAutomatically: automatic,
            isNetworkClass: network,
            isOffline: offline,
            hasNextInQueue: hasNext,
            consecutiveSkips: skips,
            repeatingOne: repeatOne
        )
    }

    @Test("A song that failed on its own, reached by the previous one ending, is skipped")
    func perTrackFailure() {
        #expect(Self.skip())
    }

    @Test("A song the listener chose stays put")
    func chosenSongStays() {
        #expect(!Self.skip(automatic: false))
    }

    @Test("A dropped connection parks the queue instead of racing through it")
    func networkParks() {
        #expect(!Self.skip(network: true))
    }

    @Test("Offline by choice, a song that is not on the phone is skipped")
    func offlineSkips() {
        #expect(Self.skip(network: true, offline: true))
    }

    @Test("Nothing to skip to, nothing skipped")
    func lastSong() {
        #expect(!Self.skip(hasNext: false))
    }

    @Test("Stops after the limit so a queue of bad files does not race to its end")
    func limit() {
        #expect(Self.skip(skips: BadTrackPolicy.skipLimit - 1))
        #expect(!Self.skip(skips: BadTrackPolicy.skipLimit))
    }

    @Test("Repeat-one would replay the same bad song")
    func repeatOne() {
        #expect(!Self.skip(repeatOne: true))
    }
}
