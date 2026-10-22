import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// Changes made with nowhere to send them.
@Suite("Change outbox")
struct OutboxTests {
    private let server = ServerID()

    private func index() throws -> LibraryIndex {
        try LibraryIndex(inMemoryFor: server)
    }

    @Test("A rating changed twice reaches the server once")
    func ratingsFold() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 3))
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 4.5))

        let pending = try index.pendingChanges()
        #expect(pending.count == 1)
        #expect(pending.first?.rating == 4.5)
    }

    @Test("Clearing a rating is a change, not an absence of one")
    func clearingIsAChange() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 4))
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: nil))

        let pending = try index.pendingChanges()
        #expect(pending.count == 1)
        #expect(pending.first?.rating == nil)
        #expect(pending.first?.kind == .rating)
    }

    @Test("Hearting an album and a track that share an id are two changes")
    func mediaKindsDoNotFold() throws {
        let index = try index()
        // Server ids are opaque strings, and nothing promises an album and a
        // track cannot share one.
        try index.enqueueChange(
            OutboxRecord(kind: .favorite, itemId: "42", mediaKind: "album", flag: true)
        )
        try index.enqueueChange(
            OutboxRecord(kind: .favorite, itemId: "42", mediaKind: "track", flag: false)
        )
        let pending = try index.pendingChanges()
        #expect(pending.count == 2)
        #expect(Set(pending.compactMap(\.mediaKind)) == ["album", "track"])

        // The same kind still folds.
        try index.enqueueChange(
            OutboxRecord(kind: .favorite, itemId: "42", mediaKind: "album", flag: false)
        )
        #expect(try index.pendingChangeCount() == 2)
        let album = try #require(try index.pendingChanges().first { $0.mediaKind == "album" })
        #expect(album.flag == false)
    }

    @Test("A heart and a rating on the same song are two changes")
    func kindsDoNotFoldTogether() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 5))
        try index.enqueueChange(OutboxRecord(kind: .favorite, itemId: "t1", mediaKind: "track", flag: true))
        #expect(try index.pendingChangeCount() == 2)
    }

    @Test("Two listens are two listens")
    func playsNeverFold() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .play, itemId: "t1", at: Date(timeIntervalSince1970: 10)))
        try index.enqueueChange(OutboxRecord(kind: .play, itemId: "t1", at: Date(timeIntervalSince1970: 400)))
        let pending = try index.pendingChanges()
        #expect(pending.count == 2)
        #expect(pending.map(\.at.timeIntervalSince1970) == [10, 400])
    }

    @Test("They come back in the order they happened")
    func orderIsKept() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 3))
        try index.enqueueChange(OutboxRecord(kind: .favorite, itemId: "t2", mediaKind: "album", flag: true))
        try index.enqueueChange(OutboxRecord(kind: .play, itemId: "t3"))
        #expect(try index.pendingChanges().map(\.itemId) == ["t1", "t2", "t3"])
    }

    @Test("A folded change keeps its place in the queue")
    func foldingKeepsPosition() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 3))
        try index.enqueueChange(OutboxRecord(kind: .play, itemId: "t2"))
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 5))
        let pending = try index.pendingChanges()
        #expect(pending.map(\.itemId) == ["t1", "t2"])
        #expect(pending.first?.rating == 5)
    }

    @Test("A failure is remembered rather than losing the change")
    func failuresAreCounted() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 3))
        let id = try #require(try index.pendingChanges().first?.id)
        try index.recordChangeFailure(id: id, message: "no route to host")
        try index.recordChangeFailure(id: id, message: "no route to host")

        let entry = try #require(try index.pendingChanges().first)
        #expect(entry.attempts == 2)
        #expect(entry.lastError == "no route to host")

        try index.removeChange(id: id)
        #expect(try index.pendingChangeCount() == 0)
    }

    // MARK: A sync must not take back what is waiting to be sent

    private func track(_ raw: String, rating: Double? = nil, playCount: Int? = nil) -> Track {
        Track(
            id: MediaID(server: server, rawValue: raw),
            title: raw,
            albumName: "A",
            artistName: "B",
            rating: rating.flatMap(StarRating.init),
            playCount: playCount
        )
    }

    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    @Test("A rating waiting in the outbox survives a walk that read the old one")
    func waitingRatingSurvivesUpsert() throws {
        let index = try index()
        let generation = try index.beginSyncGeneration()
        try index.upsertTracks([track("t1", rating: 1)], generation: generation)

        try index.mirrorRating(StarRating(5), for: id("t1"))
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 5))
        // A later page, from before the write, says 2.
        try index.upsertTracks([track("t1", rating: 2)], generation: generation)
        #expect(try index.track(id: id("t1"))?.rating == StarRating(5))

        try index.finishSync(generation: generation)
        #expect(try index.track(id: id("t1"))?.rating == StarRating(5))
    }

    @Test("A waiting 'no rating' is put back too")
    func waitingClearedRatingSurvives() throws {
        let index = try index()
        let generation = try index.beginSyncGeneration()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: nil))
        try index.upsertTracks([track("t1", rating: 4)], generation: generation)
        try index.finishSync(generation: generation)
        #expect(try index.track(id: id("t1"))?.rating == nil)
    }

    @Test("A waiting heart survives, for the kind it was given to")
    func waitingHeartSurvives() throws {
        let index = try index()
        let generation = try index.beginSyncGeneration()
        try index.enqueueChange(
            OutboxRecord(kind: .favorite, itemId: "x", mediaKind: "album", flag: true)
        )
        try index.upsertAlbums([Album(id: id("x"), name: "Album")], generation: generation)
        var sameIDTrack = track("x")
        sameIDTrack.isFavorite = false
        try index.upsertTracks([sameIDTrack], generation: generation)
        try index.finishSync(generation: generation)
        #expect(try index.album(id: id("x"))?.isFavorite == true)
        #expect(try index.track(id: id("x"))?.isFavorite == false)
    }

    @Test("A rating given while a walk is running is not taken back by it")
    func ratingDuringTheWalkSurvives() throws {
        let index = try index()
        let generation = try index.beginSyncGeneration()
        // Sent straight to the server, so there is no outbox row to point at.
        try index.mirrorRating(StarRating(5), for: id("t1"))
        try index.upsertTracks([track("t1", rating: 2)], generation: generation)
        try index.finishSync(generation: generation)
        #expect(try index.track(id: id("t1"))?.rating == StarRating(5))
    }

    @Test("What was given before the walk began is the server's to overrule")
    func olderLocalWriteYieldsToTheServer() throws {
        let index = try index()
        try index.mirrorRating(StarRating(5), for: id("t1"))
        let generation = try index.beginSyncGeneration()
        try index.upsertTracks([track("t1", rating: 2)], generation: generation)
        try index.finishSync(generation: generation)
        #expect(try index.track(id: id("t1"))?.rating == StarRating(2))
    }

    @Test("Waiting plays do not change a count the server sent")
    func waitingPlaysAreNotAddedTwice() throws {
        let index = try index()
        let generation = try index.beginSyncGeneration()
        try index.enqueueChange(OutboxRecord(kind: .play, itemId: "t1"))
        try index.upsertTracks([track("t1", playCount: 3)], generation: generation)
        try index.finishSync(generation: generation)
        #expect(try index.track(id: id("t1"))?.playCount == 3)
    }

    @Test("Removing a change by value leaves a newer one alone")
    func compareAndDelete() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 2))
        let sent = try #require(try index.pendingChanges().first)
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 5))
        #expect(try index.removeChange(matching: sent) == false)
        #expect(try index.pendingChanges().first?.rating == 5)

        let current = try #require(try index.pendingChanges().first)
        #expect(try index.removeChange(matching: current))
        #expect(try index.pendingChangeCount() == 0)
    }

    @Test("Retiring what waits for an item never touches its plays")
    func discardSparesPlays() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 2))
        try index.enqueueChange(OutboxRecord(kind: .play, itemId: "t1"))
        #expect(try index.discardChanges(kind: .rating, itemId: "t1", mediaKind: nil) == 1)
        #expect(try index.discardChanges(kind: .play, itemId: "t1", mediaKind: nil) == 0)
        #expect(try index.pendingChanges().map(\.kind) == [.play])
    }

    @Test("Sending the library round again leaves the outbox alone")
    func syncDoesNotClearIt() throws {
        let index = try index()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 3))
        _ = try index.beginSyncGeneration()
        try index.finishSync(generation: 2)
        #expect(try index.pendingChangeCount() == 1)
    }
}
