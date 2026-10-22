import Foundation
import Testing
@testable import PleviDomain

@Suite("Writing long playlists in batches")
struct PlaylistBatchingTests {
    private let server = ServerID()
    private func ids(_ count: Int) -> [MediaID] {
        (0..<count).map { MediaID(server: server, rawValue: "t\($0)") }
    }

    private actor Log {
        var made: [[MediaID]] = []
        var added: [[MediaID]] = []
        var addCalls = 0
        func make(_ ids: [MediaID]) { made.append(ids) }
        func add(_ ids: [MediaID]) -> Int { addCalls += 1; added.append(ids); return addCalls }
    }

    @Test("Chunks keep order and cover everything")
    func chunking() {
        let all = ids(10)
        let chunks = PlaylistBatching.chunks(of: all, size: 4)
        #expect(chunks.map(\.count) == [4, 4, 2])
        #expect(chunks.flatMap { $0 } == all)
        #expect(PlaylistBatching.chunks(of: [], size: 4).count == 1)
    }

    @Test("5,000 songs are made with the first batch and added in order, none over the size")
    func createsThenAdds() async throws {
        let all = ids(5_000)
        let log = Log()
        let playlist = Playlist(id: MediaID(server: server, rawValue: "p"), name: "Big")
        let result = try await PlaylistBatching.create(
            name: "Big", trackIDs: all, batchSize: 200,
            make: { _, batch in await log.make(batch); return playlist },
            add: { id, batch in
                #expect(id == playlist.id)
                _ = await log.add(batch)
            }
        )
        #expect(result.id == playlist.id)
        let made = await log.made
        let added = await log.added
        #expect(made.count == 1)
        #expect(added.count == 24)
        #expect((made + added).allSatisfy { $0.count <= 200 })
        #expect((made + added).flatMap { $0 } == all)
    }

    @Test("A short list is one call")
    func shortList() async throws {
        let log = Log()
        let playlist = Playlist(id: MediaID(server: server, rawValue: "p"), name: "Small")
        _ = try await PlaylistBatching.create(
            name: "Small", trackIDs: ids(10),
            make: { _, batch in await log.make(batch); return playlist },
            add: { _, batch in _ = await log.add(batch) }
        )
        #expect(await log.addCalls == 0)
    }

    @Test("A failure part way names the playlist and how far it got")
    func partialFailure() async throws {
        let playlist = Playlist(id: MediaID(server: server, rawValue: "p"), name: "Big")
        let log = Log()
        do {
            _ = try await PlaylistBatching.create(
                name: "Big", trackIDs: ids(1_000), batchSize: 100,
                make: { _, _ in playlist },
                add: { _, batch in
                    let call = await log.add(batch)
                    if call == 3 { throw ProviderError.notAuthorized }
                }
            )
            Issue.record("should have thrown")
        } catch let error as PartialPlaylistError {
            #expect(error.added == 300)
            #expect(error.total == 1_000)
            #expect(error.playlist.id == playlist.id)
            #expect(error.errorDescription?.contains("300 of 1000") == true)
        }
    }
}
