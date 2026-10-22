import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// `tracks(ids:)` — Remote Control's batch lookup: order, duplicates and gaps preserved, and a large playlist
/// resolved in one call.
@Suite("tracks(ids:)")
struct TracksByIDsTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    @Test("Order, duplicates and a gap")
    func orderDuplicatesAndGaps() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertTracks([
            Track(id: id("t1"), title: "One"),
            Track(id: id("t2"), title: "Two"),
            Track(id: id("t3"), title: "Three"),
        ], generation: 1)
        try index.finishSync(generation: 1)

        let requested = [id("t2"), id("t1"), id("t2"), id("missing"), id("t3")]
        let result = try index.tracks(ids: requested)

        #expect(result.count == 5)
        #expect(result[0]?.title == "Two")
        #expect(result[1]?.title == "One")
        #expect(result[2]?.title == "Two")
        #expect(result[3] == nil)
        #expect(result[4]?.title == "Three")
    }

    @Test("An empty request returns empty, with no query")
    func emptyRequest() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        #expect(try index.tracks(ids: []).isEmpty)
    }

    @Test("60,000 IDs resolve in one call, chunked internally")
    func largeBatch() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let count = 60_000
        let tracks = (0..<count).map { Track(id: id("t\($0)"), title: "Song \($0)") }
        try index.upsertTracks(tracks, generation: 1)
        try index.finishSync(generation: 1)

        let ids = (0..<count).map { id("t\($0)") }
        let result = try index.tracks(ids: ids)
        #expect(result.count == count)
        #expect(result.allSatisfy { $0 != nil })
        #expect(result[0]?.title == "Song 0")
        #expect(result[count - 1]?.title == "Song \(count - 1)")
    }
}
