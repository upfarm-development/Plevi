import Foundation
import Testing
@testable import PleviDomain

@Suite("Stress: a song found in another library")
struct StressDownloadsTrackKeyTests {
    @Test("D-05: a song is rekeyed to another library's identity without losing anything else")
    func rekeyed() {
        let sibling = ServerID(), active = ServerID()
        let original = Track(
            id: MediaID(server: sibling, rawValue: "9001"),
            title: "Elsewhere",
            albumName: "Nightfall",
            artistName: "Aurora Skies",
            trackNumber: 3,
            duration: 201
        )

        let local = original.rekeyed(to: active)

        #expect(local.id == MediaID(server: active, rawValue: "9001"))
        #expect(local.id.rawValue == original.id.rawValue)
        #expect(local.title == "Elsewhere")
        #expect(local.albumName == "Nightfall")
        #expect(local.trackNumber == 3)
        #expect(local.duration == 201)
    }

    @Test("D-05: a song already in the right library is returned as it is")
    func rekeyedIsIdempotent() {
        let server = ServerID()
        let track = Track(id: MediaID(server: server, rawValue: "1"), title: "Here")
        #expect(track.rekeyed(to: server) == track)
        let once = track.rekeyed(to: ServerID())
        #expect(once.rekeyed(to: once.id.server) == once)
    }
}
