import Foundation
import Testing
@testable import PleviDomain

/// `TrackEra.Signals.init(track:album:artistEstimate:)` is what a DJ uses to resolve the era of one
/// anchor track on demand — the single-row counterpart to `LibraryIndex.decadeTracks`'s own bulk
/// SQL resolution, which these tests do not touch.
@Suite("Assembling era signals for one anchor track")
struct DJEraSignalsTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    @Test("A plain, non-compilation track carries its own year straight through")
    func plainTrack() {
        let track = Track(id: id("t1"), title: "Song", year: 1988)
        let album = Album(id: id("al1"), name: "Record", year: 1988, isCompilation: false)
        let signals = TrackEra.Signals(track: track, album: album, artistEstimate: nil)
        #expect(signals.trackYear == 1988)
        #expect(signals.albumYear == 1988)
        #expect(signals.isCompilation == false)
        #expect(signals.albumOriginalYear == nil)
    }

    @Test("The server's own compilation flag is honoured")
    func serverFlaggedCompilation() {
        let track = Track(id: id("t1"), title: "Song")
        let album = Album(id: id("al1"), name: "Best Of", isCompilation: true)
        let signals = TrackEra.Signals(track: track, album: album, artistEstimate: nil)
        #expect(signals.isCompilation)
    }

    @Test("A compilation the server never flagged is still caught, by title")
    func unflaggedCompilationCaughtByTitle() {
        // The whole reason this init exists rather than reading `album.isCompilation` alone: that
        // flag is the server's narrow one, and this reuses the same wide heuristic the bulk era
        // pipeline already relies on.
        let track = Track(id: id("t1"), title: "Song")
        let album = Album(id: id("al1"), name: "Greatest Hits", isCompilation: false)
        let signals = TrackEra.Signals(track: track, album: album, artistEstimate: nil)
        #expect(signals.isCompilation, "\"Greatest Hits\" should be caught by title even with no server flag")
    }

    @Test("A various-artists credit is caught even with a plain title")
    func variousArtistsCredit() {
        let track = Track(id: id("t1"), title: "Song")
        let album = Album(id: id("al1"), name: "Radio Hits 2001", artistName: "Various Artists", isCompilation: false)
        let signals = TrackEra.Signals(track: track, album: album, artistEstimate: nil)
        #expect(signals.isCompilation)
    }

    @Test("A missing album leaves every album-derived signal nil, not a crash")
    func noAlbum() {
        let track = Track(id: id("t1"), title: "Song", year: 1999)
        let signals = TrackEra.Signals(track: track, album: nil, artistEstimate: 1995)
        #expect(signals.albumYear == nil)
        #expect(signals.isCompilation == false)
        #expect(signals.trackYear == 1999)
        #expect(signals.artistEstimate == 1995)
    }

    @Test("The album's release date becomes the original-year signal, read in UTC")
    func releaseDateBecomesOriginalYear() {
        // 1999-12-31 23:00 UTC — a date chosen right at a year boundary,
        // where a local-timezone calendar could disagree with SQLite's own
        // UTC-based strftime by a year.
        let released = Date(timeIntervalSince1970: 946_681_200)
        let track = Track(id: id("t1"), title: "Song")
        let album = Album(id: id("al1"), name: "Record", releaseDate: released)
        let signals = TrackEra.Signals(track: track, album: album, artistEstimate: nil)
        #expect(signals.albumOriginalYear == 1999)
    }

    @Test("Resolving through TrackEra end to end still prefers the track's own original tag")
    func resolvesThroughToClassification() {
        let track = Track(id: id("t1"), title: "Song", year: 2015, originalYear: 1971)
        let album = Album(id: id("al1"), name: "Now That's What I Call Hits", year: 2015)
        let signals = TrackEra.Signals(track: track, album: album, artistEstimate: nil)
        let classification = TrackEra.resolve(signals)
        #expect(classification.year == 1971)
        #expect(classification.decade == 1970)
        #expect(classification.source == TrackEra.Source.trackTag)
    }
}
