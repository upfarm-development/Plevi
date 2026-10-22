import Foundation
import Testing
@testable import PleviDomain

@Suite("A record's standout songs")
struct HotTracksTests {
    private let server = ServerID()
    private func track(_ raw: String, popularity: Int?) -> Track {
        Track(id: MediaID(server: server, rawValue: raw), title: raw, popularity: popularity)
    }

    @Test("The three most played are marked")
    func theTopThreeAreMarked() {
        let tracks = [
            track("a", popularity: 100),
            track("b", popularity: 90),
            track("c", popularity: 60),
            track("d", popularity: 20),
            track("e", popularity: 15),
        ]
        #expect(HotTracks.ids(in: tracks, releaseType: .album)
            == [tracks[0].id, tracks[1].id, tracks[2].id])
    }

    @Test("A record levelled throughout still has three most played")
    func aLevelRecordIsStillMarked() {
        // No song clears the rest by any margin worth the name. Marked all
        // the same: three of them were still played more than the others,
        // which is the whole of what the mark says.
        let tracks = [
            track("a", popularity: 40),
            track("b", popularity: 38),
            track("c", popularity: 35),
            track("d", popularity: 33),
        ]
        #expect(HotTracks.ids(in: tracks, releaseType: .album)
            == [tracks[0].id, tracks[1].id, tracks[2].id])
    }

    @Test("A single is left alone, however its songs rank")
    func singlesAreNeverMarked() {
        let tracks = [
            track("a", popularity: 900),
            track("b", popularity: 400),
            track("c", popularity: 100),
            track("d", popularity: 50),
        ]
        #expect(HotTracks.ids(in: tracks, releaseType: .single).isEmpty)
        // An EP is a record like any other.
        #expect(HotTracks.ids(in: tracks, releaseType: .ep).count == 3)
    }

    @Test("Marking every song marks nothing, so a record this short is left alone")
    func aRecordWithNothingToSetApartIsNotMarked() {
        let tracks = [
            track("a", popularity: 500),
            track("b", popularity: 300),
            track("c", popularity: 100),
        ]
        #expect(HotTracks.ids(in: tracks, releaseType: .album).isEmpty)
    }

    @Test("A record with almost nothing measured marks nothing")
    func aBarelyMeasuredRecordIsNotMarked() {
        // Only two songs have a figure at all — not enough of the record is
        // known to say which of it stands out.
        let tracks = [
            track("a", popularity: 500),
            track("b", popularity: 5),
            track("c", popularity: nil),
            track("d", popularity: nil),
        ]
        #expect(HotTracks.ids(in: tracks, releaseType: .album).isEmpty)
    }

    @Test("Zero is not measured, and does not count toward the floor")
    func zeroDoesNotCount() {
        let tracks = [
            track("a", popularity: 200),
            track("b", popularity: 150),
            track("c", popularity: 120),
            track("d", popularity: 0),
            track("e", popularity: 0),
        ]
        // Three measured songs once the zeros are set aside, and marking all
        // three of them would be marking everything that has a figure.
        #expect(HotTracks.ids(in: tracks, releaseType: .album).isEmpty)
    }

    @Test("Off Plex, nothing has a figure, and nothing is marked")
    func unmeasuredRecordsAreNeverMarked() {
        let tracks = (0..<8).map { track("t\($0)", popularity: nil) }
        #expect(HotTracks.ids(in: tracks, releaseType: .album).isEmpty)
    }

    @Test("A tie at the bottom of the three picks one of them, not both")
    func aTieDoesNotOverfillTheMark() {
        let tracks = [
            track("a", popularity: 100),
            track("b", popularity: 50),
            track("c", popularity: 30),
            track("d", popularity: 30),
            track("e", popularity: 10),
        ]
        #expect(HotTracks.ids(in: tracks, releaseType: .album).count == 3)
    }
}
