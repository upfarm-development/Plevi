import Foundation
import Testing
@testable import PleviDomain

@Suite("Plays the watch counted while offline, and how they are reported (playback-18, watch-13, ui-views-08)")
struct WatchPlaysTests {
    private let server = ServerID()
    private let t0 = Date(timeIntervalSince1970: 50_000)

    // MARK: playback-18

    @Test("Three songs played in airplane mode are kept in order, each with its own time")
    func keepsEachPlay() {
        var pending = PendingPlays()
        pending.enqueue(trackID: "a", at: t0)
        pending.enqueue(trackID: "b", at: t0.addingTimeInterval(240))
        pending.enqueue(trackID: "c", at: t0.addingTimeInterval(500))

        #expect(pending.plays.map(\.trackID) == ["a", "b", "c"])
        #expect(pending.next?.playedAt == t0)
    }

    @Test("A play leaves the list only when it is taken off, oldest first")
    func drainsFirstInFirstOut() {
        var pending = PendingPlays()
        pending.enqueue(trackID: "a", at: t0)
        pending.enqueue(trackID: "b", at: t0.addingTimeInterval(60))

        #expect(pending.next?.trackID == "a")
        // Peeking removes nothing: a failed send leaves it where it was.
        #expect(pending.next?.trackID == "a")
        pending.removeNext()
        #expect(pending.next?.trackID == "b")
        pending.removeNext()
        #expect(pending.isEmpty)
        pending.removeNext()   // harmless on an empty list
    }

    @Test("The same play queued twice is one play")
    func duplicatesAreOnePlay() {
        var pending = PendingPlays()
        pending.enqueue(trackID: "a", at: t0)
        pending.enqueue(trackID: "a", at: t0)
        #expect(pending.plays.count == 1)
        // The same song played again later is another play.
        pending.enqueue(trackID: "a", at: t0.addingTimeInterval(300))
        #expect(pending.plays.count == 2)
    }

    @Test("The list is capped and the oldest plays go first")
    func capped() {
        var pending = PendingPlays()
        for number in 0..<(PendingPlays.capacity + 25) {
            pending.enqueue(trackID: "s\(number)", at: t0.addingTimeInterval(Double(number)))
        }
        #expect(pending.plays.count == PendingPlays.capacity)
        #expect(pending.plays.first?.trackID == "s25")
        #expect(pending.plays.last?.trackID == "s\(PendingPlays.capacity + 24)")
    }

    @Test("A list survives being written down and read back")
    func codable() throws {
        var pending = PendingPlays()
        pending.enqueue(trackID: "a", at: t0)
        let back = try JSONDecoder().decode(PendingPlays.self, from: JSONEncoder().encode(pending))
        #expect(back == pending)
    }

    @Test("No network or a server having a moment keeps the play and stops; a refusal drops it")
    func outcomes() {
        #expect(PendingPlays.outcome(afterFailure: URLError(.notConnectedToInternet)) == .keepAndStop)
        #expect(PendingPlays.outcome(afterFailure: ProviderError.network(underlying: URLError(.timedOut))) == .keepAndStop)
        #expect(PendingPlays.outcome(afterFailure: ProviderError.serverError(code: 503, message: nil, helpURL: nil)) == .keepAndStop)
        #expect(PendingPlays.outcome(afterFailure: CancellationError()) == .keepAndStop)
        #expect(PendingPlays.outcome(afterFailure: URLError(.cancelled)) == .keepAndStop)
        // Answered, and said no: it would say no for ever at the front of the list.
        #expect(PendingPlays.outcome(afterFailure: ProviderError.notAuthenticated(.wrongCredentials)) == .drop)
        #expect(PendingPlays.outcome(afterFailure: ProviderError.notFound) == .drop)
    }

    // MARK: watch-13

    private func source(_ raw: String) -> PlayedSource {
        PlayedSource(kind: .album, mediaID: MediaID(server: server, rawValue: raw), title: raw)
    }

    @Test("A replayed play is placed by when it happened, not at the front")
    func replayedPlayGoesByTime() {
        // The album played an hour ago, then a morning run reported this evening.
        var shelf = PlayHistory.recording(source("recent"), at: t0.addingTimeInterval(-3_600), in: [])
        shelf = PlayHistory.replaying(source("morning-run"), at: t0.addingTimeInterval(-36_000), in: shelf)

        #expect(shelf.map(\.source.title) == ["recent", "morning-run"])
    }

    @Test("A replayed play that is the newest still goes first")
    func replayedNewestIsFirst() {
        var shelf = PlayHistory.recording(source("old"), at: t0.addingTimeInterval(-7_200), in: [])
        shelf = PlayHistory.replaying(source("new"), at: t0, in: shelf)
        #expect(shelf.map(\.source.title) == ["new", "old"])
    }

    @Test("The same thing played on both devices keeps its newer time")
    func sameThingKeepsNewerTime() {
        let phone = PlayHistory.recording(source("x"), at: t0, in: [])
        let merged = PlayHistory.replaying(source("x"), at: t0.addingTimeInterval(-500), in: phone)
        #expect(merged.count == 1)
        #expect(merged.first?.playedAt == t0)

        let other = PlayHistory.replaying(source("x"), at: t0.addingTimeInterval(500), in: phone)
        #expect(other.first?.playedAt == t0.addingTimeInterval(500))
    }

    @Test("A replay respects the cap")
    func replayCapped() {
        var shelf: [PlayedEntry] = []
        for number in 0..<(PlayHistory.kept + 5) {
            shelf = PlayHistory.replaying(
                source("s\(number)"), at: t0.addingTimeInterval(Double(number)), in: shelf
            )
        }
        #expect(shelf.count == PlayHistory.kept)
        #expect(shelf.first?.source.title == "s\(PlayHistory.kept + 4)")
    }

    // MARK: ui-views-08

    @Test("Adding to the queue from Downloads leaves out songs that are not on the watch")
    func onlyDownloadedSongs() {
        func track(_ raw: String) -> Track {
            Track(id: MediaID(server: server, rawValue: raw), title: raw)
        }
        let album = ["1", "2", "3", "4"].map(track)
        let playable = PlayableSongs.filter(album, downloaded: ["2", "4"])
        #expect(playable.map(\.title) == ["2", "4"])
        #expect(PlayableSongs.filter(album, downloaded: []).isEmpty)
    }
}
