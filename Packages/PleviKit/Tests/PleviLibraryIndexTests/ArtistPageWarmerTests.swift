import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

@Suite("A failed artist fetch is never filed as the answer")
struct ArtistPageWarmerTests {
    private let server = ServerID()

    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seededIndex() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("ar1"), name: "Aurora Skies"),
            Artist(id: id("ar2"), name: "Cobalt Waves"),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "First Light", artistID: id("ar1")),
            Track(id: id("t2"), title: "Slow Horizon", artistID: id("ar1")),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private static let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)

    private let offline = ProviderError.network(underlying: URLError(.notConnectedToInternet))

    private func info(_ bio: String = "Fresh bio.") -> @Sendable () async throws -> ArtistInfo {
        let similar = Artist(id: id("ar2"), name: "Cobalt Waves")
        return { ArtistInfo(biography: bio, similarArtists: [similar]) }
    }

    private func top() -> @Sendable () async throws -> [Track] {
        let track = Track(id: id("t1"), title: "First Light", artistID: id("ar1"))
        return { [track] }
    }

    private func failing<T>(_ error: ProviderError) -> @Sendable () async throws -> T {
        { throw error }
    }

    /// A good page that has gone stale, as the index holds it after a week.
    private func seedStalePage(_ index: LibraryIndex) throws {
        try index.storeArtistPage(
            for: id("ar1"), biography: "Old but good.",
            similarArtistIDs: [id("ar2")], topTrackIDs: [id("t2"), id("t1")],
            fetchedAt: Self.eightDaysAgo
        )
    }

    @Test("Both requests failing writes nothing and leaves a stale good page alone")
    func failureLeavesTheStalePage() async throws {
        let index = try seededIndex()
        try seedStalePage(index)
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false,
            fetchInfo: failing(offline), fetchTopTracks: failing(offline)
        )
        #expect(outcome == .failed)
        let page = try #require(try index.cachedArtistPage(for: id("ar1")))
        #expect(page.biography == "Old but good.")
        #expect(page.topTracks.map(\.title) == ["Slow Horizon", "First Light"])
        #expect(page.isStale())
    }

    @Test("Both requests failing with no page stored stores nothing, so it is asked again")
    func failureStoresNothingAtAll() async throws {
        let index = try seededIndex()
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false,
            fetchInfo: failing(offline), fetchTopTracks: failing(offline)
        )
        #expect(outcome == .failed)
        #expect(try index.cachedArtistPage(for: id("ar1")) == nil)
    }

    @Test("A cancelled fetch writes nothing")
    func cancellationWritesNothing() async throws {
        let index = try seededIndex()
        try seedStalePage(index)
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ArtistPageWarmer.warm(
                id("ar1"), in: index, isOffline: false,
                fetchInfo: info(), fetchTopTracks: top()
            )
        }.value
        #expect(outcome == .cancelled)
        #expect(try index.cachedArtistPage(for: id("ar1"))?.biography == "Old but good.")
    }

    @Test("Offline asks nothing and touches nothing")
    func offlineDoesNothing() async throws {
        let index = try seededIndex()
        try seedStalePage(index)
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: true,
            fetchInfo: { Issue.record("offline must not call the server"); return ArtistInfo() },
            fetchTopTracks: { Issue.record("offline must not call the server"); return [] }
        )
        #expect(outcome == .offline)
        #expect(try index.cachedArtistPage(for: id("ar1"))?.biography == "Old but good.")
    }

    @Test("One request failing keeps that half of the old page and does not mark it fresh")
    func partialFailureMerges() async throws {
        let index = try seededIndex()
        try seedStalePage(index)
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false,
            fetchInfo: info("New bio."), fetchTopTracks: failing(offline)
        )
        #expect(outcome == .storedPartly)
        let page = try #require(try index.cachedArtistPage(for: id("ar1")))
        #expect(page.biography == "New bio.")
        #expect(page.topTracks.map(\.title) == ["Slow Horizon", "First Light"])
        #expect(page.isStale(), "a partly refreshed page is still owed a refresh")
    }

    @Test("A partial page with nothing stored before is stale, not fresh")
    func partialFailureWithNothingBefore() async throws {
        let index = try seededIndex()
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false,
            fetchInfo: info(), fetchTopTracks: failing(offline)
        )
        #expect(outcome == .storedPartly)
        let page = try #require(try index.cachedArtistPage(for: id("ar1")))
        #expect(page.isStale())
    }

    @Test("Successful answers are stored fresh, replacing a stale page")
    func successStoresFresh() async throws {
        let index = try seededIndex()
        try seedStalePage(index)
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false,
            fetchInfo: info("New bio."), fetchTopTracks: top()
        )
        #expect(outcome == .stored)
        let page = try #require(try index.cachedArtistPage(for: id("ar1")))
        #expect(page.biography == "New bio.")
        #expect(page.topTracks.map(\.title) == ["First Light"])
        #expect(!page.isStale())
    }

    @Test("A server that says there is nothing is an answer, and is stored")
    func notFoundIsAnAnswer() async throws {
        let index = try seededIndex()
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false,
            fetchInfo: failing(.notFound), fetchTopTracks: failing(.unsupportedOperation(needs: []))
        )
        #expect(outcome == .stored)
        let page = try #require(try index.cachedArtistPage(for: id("ar1")))
        #expect(page.biography == nil)
        #expect(!page.isStale())
    }

    @Test("A server without either capability stores the empty page fresh")
    func noCapabilities() async throws {
        let index = try seededIndex()
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false, fetchInfo: nil, fetchTopTracks: nil
        )
        #expect(outcome == .stored)
        #expect(!(try #require(try index.cachedArtistPage(for: id("ar1")))).isStale())
    }

    @Test("A fresh page is left alone and nothing is asked")
    func freshPageIsKept() async throws {
        let index = try seededIndex()
        try index.storeArtistPage(
            for: id("ar1"), biography: "Fresh already.", similarArtistIDs: [], topTrackIDs: []
        )
        let outcome = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false,
            fetchInfo: { Issue.record("must not ask"); return ArtistInfo() }, fetchTopTracks: nil
        )
        #expect(outcome == .alreadyFresh)
    }

    @Test("A retry after a failure fetches again")
    func retryAfterFailure() async throws {
        let index = try seededIndex()
        let first = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false,
            fetchInfo: failing(offline), fetchTopTracks: failing(offline)
        )
        #expect(first == .failed)
        let second = await ArtistPageWarmer.warm(
            id("ar1"), in: index, isOffline: false, fetchInfo: info(), fetchTopTracks: top()
        )
        #expect(second == .stored)
        #expect(try index.cachedArtistPage(for: id("ar1"))?.biography == "Fresh bio.")
    }
}
