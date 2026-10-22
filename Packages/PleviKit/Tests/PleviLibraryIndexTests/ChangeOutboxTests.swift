import Foundation
import Synchronization
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// A server that writes down what it was told, in the order it was told, and
/// can be made to stall or refuse on demand.
private final class RecordingServer: MusicServerProvider, Sendable {
    let serverID: ServerID
    let capabilities: ServerCapabilities = []

    private let told = Mutex<[String]>([])
    /// Runs while a call is "in the air", after it has been written down.
    private let hook = Mutex<(@Sendable (String) async throws -> Void)?>(nil)

    init(serverID: ServerID) { self.serverID = serverID }

    var calls: [String] { told.withLock { $0 } }

    func whileInTheAir(_ body: (@Sendable (String) async throws -> Void)?) {
        hook.withLock { $0 = body }
    }

    private func record(_ call: String) async throws {
        told.withLock { $0.append(call) }
        let body = hook.withLock { $0 }
        try await body?(call)
    }

    func setRating(_ rating: StarRating?, for id: MediaID) async throws {
        try await record("rating:\(id.rawValue):\(rating.map { String($0.value) } ?? "none")")
    }

    func setFavorite(_ favorite: Bool, for id: MediaID, kind: MediaKind) async throws {
        try await record("favorite:\(kind.rawValue):\(id.rawValue):\(favorite)")
    }

    func scrobble(id: MediaID, at date: Date, submission: Bool) async throws {
        try await record("play:\(id.rawValue):\(Int(date.timeIntervalSince1970))")
    }

    func artists() async throws -> [Artist] { [] }
    func albums(filter: AlbumFilter, offset: Int, limit: Int) async throws -> [Album] { [] }
    func tracks(offset: Int, limit: Int) async throws -> [Track] { [] }
    func search(_ query: String, limit: Int, offset: Int) async throws -> SearchResults { SearchResults() }
    func testConnection() async throws -> ServerInfo { ServerInfo() }
    func artist(id: MediaID) async throws -> ArtistDetail { throw ProviderError.notFound }
    func album(id: MediaID) async throws -> AlbumDetail { throw ProviderError.notFound }
    func track(id: MediaID) async throws -> Track { throw ProviderError.notFound }
    func playlists() async throws -> [Playlist] { [] }
    func playlist(id: MediaID) async throws -> PlaylistDetail { throw ProviderError.notFound }
    func createPlaylist(name: String, trackIDs: [MediaID]) async throws -> Playlist {
        throw ProviderError.unsupportedOperation(needs: .playlists)
    }
    func renamePlaylist(id: MediaID, name: String) async throws {}
    func addToPlaylist(id: MediaID, trackIDs: [MediaID]) async throws {}
    func removeFromPlaylist(id: MediaID, entries: [PlaylistEntryID]) async throws {}
    func streamRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.invalid")!)
    }
    func downloadRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.invalid")!)
    }
    func artworkRequest(for id: ArtworkID, size: Int?) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.invalid")!)
    }
}

/// A door a test holds shut until it decides otherwise.
private actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for waiter in waiting { waiter.resume() }
        waiting = []
    }
}

private final class Switch: Sendable {
    private let value: Mutex<Bool>
    init(_ initial: Bool) { value = Mutex(initial) }
    var isOn: Bool { value.withLock { $0 } }
    func set(_ new: Bool) { value.withLock { $0 = new } }
}

@MainActor
@Suite("Change outbox behaviour")
struct ChangeOutboxTests {
    private let server = ServerID()

    private func make(
        offline: Switch = Switch(false)
    ) throws -> (LibraryIndex, RecordingServer, ChangeOutbox, Switch) {
        let index = try LibraryIndex(inMemoryFor: server)
        let provider = RecordingServer(serverID: server)
        let outbox = ChangeOutbox(index: index, provider: provider, isOffline: { offline.isOn })
        return (index, provider, outbox, offline)
    }

    private func item(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    // MARK: One outbox per index

    @Test("Two outboxes draining one index send every play once")
    func twoOutboxesOneIndexSendOnce() async throws {
        let (index, provider, first, _) = try make()
        let second = ChangeOutbox(index: index, provider: provider, isOffline: { false })
        for number in 0..<40 {
            try index.enqueueChange(
                OutboxRecord(kind: .play, itemId: "t\(number)", at: Date(timeIntervalSince1970: Double(number)))
            )
        }
        // Slow enough that the second drain starts while the first is running.
        provider.whileInTheAir { _ in try await Task.sleep(for: .milliseconds(2)) }

        async let a: Void = first.drain()
        async let b: Void = second.drain()
        _ = await (a, b)

        let plays = provider.calls.filter { $0.hasPrefix("play:") }
        #expect(plays.count == 40)
        #expect(Set(plays).count == 40)
        #expect(try index.pendingChangeCount() == 0)
    }

    @Test("A reconnect hands the same outbox a new provider")
    func rebindSwapsTheProvider() async throws {
        let (index, first, outbox, _) = try make()
        let second = RecordingServer(serverID: server)
        #expect(outbox.serves(index))
        outbox.rebind(provider: second)

        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 4))
        await outbox.drain()

        #expect(first.calls.isEmpty)
        #expect(second.calls == ["rating:t1:4.0"])
    }

    @Test("A stopped outbox does not carry on draining")
    func stopEndsADrain() async throws {
        let (index, provider, outbox, _) = try make()
        for number in 0..<10 {
            try index.enqueueChange(OutboxRecord(kind: .play, itemId: "t\(number)"))
        }
        provider.whileInTheAir { [outbox] call in
            if call.hasPrefix("play:t2") { await MainActor.run { outbox.stop() } }
        }
        await outbox.drain()
        #expect(provider.calls.count == 3)
        #expect(try index.pendingChangeCount() == 7)
    }

    // MARK: Ordering

    @Test("A newer rating replaces the older one waiting for it")
    func newerRatingRetiresQueued() async throws {
        let offline = Switch(true)
        let (index, provider, outbox, _) = try make(offline: offline)
        let outcome = await outbox.rate(StarRating(2), id: item("t1"))
        #expect(outcome == .queued)
        #expect(try index.pendingChangeCount() == 1)

        offline.set(false)
        let now = await outbox.rate(StarRating(5), id: item("t1"))
        #expect(now == .sent)
        // The 2 was never sent after the 5, and nothing is left behind.
        #expect(provider.calls == ["rating:t1:5.0"])
        #expect(try index.pendingChangeCount() == 0)
        #expect(outbox.pending == 0)
    }

    @Test("A heart given after an offline one wins the same way")
    func newerHeartRetiresQueued() async throws {
        let offline = Switch(true)
        let (index, provider, outbox, _) = try make(offline: offline)
        await outbox.favorite(true, id: item("a1"), kind: .album)
        offline.set(false)
        await outbox.favorite(false, id: item("a1"), kind: .album)
        #expect(provider.calls == ["favorite:album:a1:false"])
        #expect(try index.pendingChangeCount() == 0)
    }

    @Test("A failed write leaves the older one waiting")
    func failedWriteKeepsQueued() async throws {
        let offline = Switch(true)
        let (index, provider, outbox, _) = try make(offline: offline)
        await outbox.rate(StarRating(2), id: item("t1"))
        offline.set(false)
        provider.whileInTheAir { _ in throw URLError(.timedOut) }
        let outcome = await outbox.rate(StarRating(5), id: item("t1"))
        #expect(outcome == .queued)
        // Folded, so the queue holds the newer value, once.
        let rows = try index.pendingChanges()
        #expect(rows.count == 1)
        #expect(rows.first?.rating == 5)
    }

    @Test("Two quick taps on one item reach the server in order")
    func quickTapsStayInOrder() async throws {
        let (index, provider, outbox, _) = try make()
        // The first is slow: without an ordering the second would overtake it.
        provider.whileInTheAir { call in
            if call == "rating:t1:2.0" { try await Task.sleep(for: .milliseconds(60)) }
        }
        async let first = outbox.rate(StarRating(2), id: item("t1"))
        // Let the first get as far as the server.
        try await Task.sleep(for: .milliseconds(10))
        async let second = outbox.rate(StarRating(5), id: item("t1"))
        let outcomes = await [first, second]

        #expect(outcomes == [.sent, .sent])
        #expect(provider.calls == ["rating:t1:2.0", "rating:t1:5.0"])
        #expect(try index.pendingChangeCount() == 0)
    }

    @Test("A rating given while the queue is sending its older one goes after it")
    func ratingDuringADrain() async throws {
        let (index, provider, outbox, _) = try make()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 2))
        let gate = Gate()
        provider.whileInTheAir { call in
            if call == "rating:t1:2.0" { await gate.pass() }
        }

        async let drained: Void = outbox.drain()
        try await Task.sleep(for: .milliseconds(20))
        async let rated = outbox.rate(StarRating(5), id: item("t1"))
        try await Task.sleep(for: .milliseconds(20))
        // Held behind the write already in the air.
        #expect(provider.calls == ["rating:t1:2.0"])
        await gate.release()
        _ = await (drained, rated)

        #expect(provider.calls == ["rating:t1:2.0", "rating:t1:5.0"])
        #expect(try index.pendingChangeCount() == 0)
    }

    @Test("A choice folded in while its older self is in the air stays queued")
    func foldedChoiceSurvivesTheDrain() async throws {
        let (index, provider, outbox, _) = try make()
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 2))
        provider.whileInTheAir { [index] call in
            // Offline for the newer tap: it folds into the same row.
            if call == "rating:t1:2.0" {
                try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 5))
            }
        }
        await outbox.drain()
        // The 2 went; the row now says 5 and was not removed with it.
        let rows = try index.pendingChanges()
        #expect(rows.count == 1)
        #expect(rows.first?.rating == 5)

        provider.whileInTheAir(nil)
        await outbox.drain()
        #expect(provider.calls == ["rating:t1:2.0", "rating:t1:5.0"])
        #expect(try index.pendingChangeCount() == 0)
    }

    @Test("A row a direct write has retired is not sent from a stale snapshot")
    func drainRereadsTheRow() async throws {
        let (index, provider, outbox, _) = try make()
        try index.enqueueChange(OutboxRecord(kind: .play, itemId: "p1"))
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t1", rating: 2))
        // While the play is being told, a newer rating settles the queued one.
        provider.whileInTheAir { [index] call in
            if call.hasPrefix("play:p1") { try index.discardChanges(kind: .rating, itemId: "t1", mediaKind: nil) }
        }
        await outbox.drain()
        #expect(provider.calls.count == 1)
        #expect(try index.pendingChangeCount() == 0)
    }

    @Test("Plays are not held behind a rating that is in the air")
    func playsSkipTheOrdering() async throws {
        let (_, provider, outbox, _) = try make()
        let gate = Gate()
        provider.whileInTheAir { call in
            if call.hasPrefix("rating:") { await gate.pass() }
        }
        async let rated = outbox.rate(StarRating(3), id: item("t1"))
        try await Task.sleep(for: .milliseconds(20))
        let played = await outbox.play(id: item("t1"), at: Date(timeIntervalSince1970: 5))
        #expect(played == .sent)
        await gate.release()
        _ = await rated
    }

    @Test("The same song played twice is sent twice")
    func repeatedPlaysAreKept() async throws {
        let (index, provider, outbox, _) = try make()
        for seconds in [10.0, 20.0] {
            try index.enqueueChange(OutboxRecord(kind: .play, itemId: "t1", at: Date(timeIntervalSince1970: seconds)))
        }
        await outbox.drain()
        #expect(provider.calls == ["play:t1:10", "play:t1:20"])
    }

    // MARK: Proxies and refusals

    @Test("A proxy's 403 or 404 does not cost a queued change")
    func proxyAnswersAreNotPermanent() async throws {
        for error in [
            ProviderError.notAuthorized,
            ProviderError.incompatibleServer(details: "HTTP 404"),
        ] {
            let (index, provider, outbox, _) = try make()
            for number in 0..<3 {
                try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "t\(number)", rating: 4))
            }
            provider.whileInTheAir { _ in throw error }
            await outbox.drain()

            #expect(try index.pendingChangeCount() == 3)
            let first = try #require(try index.pendingChanges().first)
            #expect(first.attempts == 1)
            #expect(outbox.lastFailure != nil)
        }
    }

    @Test("A direct write a proxy turns away is kept, not dropped")
    func proxyAnswerQueuesADirectWrite() async throws {
        let (index, provider, outbox, _) = try make()
        provider.whileInTheAir { _ in throw ProviderError.notAuthorized }
        let outcome = await outbox.rate(StarRating(4), id: item("t1"))
        #expect(outcome == .queued)
        #expect(try index.pendingChangeCount() == 1)
        #expect(outbox.lastFailure != nil)
    }

    @Test("A direct write the server refuses is reported and not queued")
    func refusalIsReported() async throws {
        let (index, provider, outbox, _) = try make()
        provider.whileInTheAir { _ in throw ProviderError.notFound }
        let outcome = await outbox.favorite(true, id: item("t1"), kind: .track)
        #expect(outcome == .refused(.notFound))
        #expect(try index.pendingChangeCount() == 0)
        #expect(outbox.lastFailure != nil)
    }

    @Test("Changes the server will never take are dropped, and said so once")
    func droppedChangesAreAnnouncedOnce() async throws {
        let (index, provider, outbox, _) = try make()
        for number in 0..<3 {
            try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "gone\(number)", rating: 4))
        }
        try index.enqueueChange(OutboxRecord(kind: .rating, itemId: "fine", rating: 4))
        provider.whileInTheAir { call in
            if call.contains("gone") { throw ProviderError.notFound }
        }
        var messages: [String] = []
        outbox.onDropped = { messages.append($0) }
        await outbox.drain()

        #expect(messages.count == 1)
        #expect(messages.first?.hasPrefix("3 changes") == true)
        #expect(try index.pendingChangeCount() == 0)
        #expect(provider.calls.last == "rating:fine:4.0")
    }

    @Test("Reverting a refused rating leaves a newer one alone")
    func revertOnlyWhileShowing() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let album = Album(id: item("al1"), name: "A", rating: StarRating(3))
        let generation = try index.beginSyncGeneration()
        try index.upsertAlbums([album], generation: generation)

        let before = try index.mirroredRating(for: item("al1"))
        #expect(before == StarRating(3))
        try index.mirrorRating(StarRating(5), for: item("al1"))

        // Still showing what was refused: goes back.
        #expect(try index.revertRating(to: before, for: item("al1"), ifShowing: StarRating(5)))
        #expect(try index.mirroredRating(for: item("al1")) == StarRating(3))

        // Someone chose again since: not this call's to undo.
        try index.mirrorRating(StarRating(4), for: item("al1"))
        #expect(try index.revertRating(to: before, for: item("al1"), ifShowing: StarRating(5)) == false)
        #expect(try index.mirroredRating(for: item("al1")) == StarRating(4))
    }

    @Test("Reverting a refused heart works the same way")
    func revertHeart() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let generation = try index.beginSyncGeneration()
        try index.upsertAlbums([Album(id: item("al1"), name: "A")], generation: generation)
        try index.mirrorFavorite(true, for: item("al1"), kind: .album)
        #expect(try index.mirroredFavorite(for: item("al1"), kind: .album))
        #expect(try index.revertFavorite(to: false, for: item("al1"), kind: .album, ifShowing: true))
        #expect(try index.mirroredFavorite(for: item("al1"), kind: .album) == false)
        #expect(try index.revertFavorite(to: false, for: item("al1"), kind: .album, ifShowing: true) == false)
    }
}
