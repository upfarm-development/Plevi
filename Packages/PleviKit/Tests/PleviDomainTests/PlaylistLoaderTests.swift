import Foundation
import Testing
@testable import PleviDomain

/// A server that hands out a playlist a page at a time, and remembers what it
/// was asked for.
private final class StubSource: PlaylistPageSource, @unchecked Sendable {
    let playlist: Playlist
    /// One element per song. A nil means a row the app can make no song of —
    /// a video, say — which the server still counts and pages by.
    let rows: [Track?]
    /// Set to hold back the total, as a server that does not report one.
    let reportsTotal: Bool
    private(set) var asked: [(offset: Int, limit: Int)] = []
    /// Waits here, once, so a test can act while a page is in flight.
    var pause: (@Sendable () async -> Void)?
    /// Thrown by the next request, once.
    var failNext: (any Error)?

    init(playlist: Playlist, rows: [Track?], reportsTotal: Bool = true) {
        self.playlist = playlist
        self.rows = rows
        self.reportsTotal = reportsTotal
    }

    func playlistPage(id: MediaID, offset: Int, limit: Int) async throws -> PlaylistPage {
        asked.append((offset, limit))
        if let failure = failNext {
            failNext = nil
            throw failure
        }
        if let pause {
            self.pause = nil
            await pause()
        }
        let window = rows.dropFirst(offset).prefix(limit)
        let entries = window.enumerated().compactMap { index, track -> PlaylistEntry? in
            guard let track else { return nil }
            return PlaylistEntry(
                entryID: PlaylistEntryID(server: playlist.id.server, rawValue: "e\(offset + index)"),
                track: track
            )
        }
        return PlaylistPage(
            playlist: playlist,
            entries: entries,
            total: reportsTotal ? rows.count : nil,
            returnedRows: window.count
        )
    }
}

/// Holds a request until the test lets it go.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A store that remembers pages in memory.
private actor MemoryStore: PlaylistPageStoring {
    private(set) var pages: [MediaID: PlaylistPage] = [:]
    func page(for id: MediaID) -> PlaylistPage? { pages[id] }
    func save(_ page: PlaylistPage, for id: MediaID) { pages[id] = page }
    func hasPage(for id: MediaID, newerThan seconds: TimeInterval) -> Bool { pages[id] != nil }
    func put(_ page: PlaylistPage, for id: MediaID) { pages[id] = page }
}

@MainActor
@Suite("Loading a playlist a page at a time")
struct PlaylistLoaderTests {
    private static let server = ServerID()

    private static func playlist(count: Int) -> Playlist {
        Playlist(
            id: MediaID(server: server, rawValue: "pl1"),
            name: "Everything",
            trackCount: count,
            isSmart: true
        )
    }

    private static func song(_ n: Int, seconds: TimeInterval? = 100) -> Track {
        Track(
            id: MediaID(server: server, rawValue: "t\(n)"),
            title: "Song \(n)",
            duration: seconds
        )
    }

    private static func source(songs: Int, reportsTotal: Bool = true) -> StubSource {
        StubSource(
            playlist: playlist(count: songs),
            rows: (0..<songs).map { song($0) },
            reportsTotal: reportsTotal
        )
    }

    @Test("The first page is all it asks for to start with")
    func firstPageOnly() async {
        let source = Self.source(songs: 5_000)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.start()

        #expect(loader.entries.count == PlaylistLoader.pageSize)
        #expect(source.asked.count == 1)
        #expect(source.asked[0].offset == 0)
        // The full length is known long before the songs are.
        #expect(loader.total == 5_000)
        #expect(loader.songCount == 5_000)
        #expect(!loader.hasEverything)
    }

    @Test("A kept page is on screen before the server answers, then replaced by it")
    func keptPageThenFresh() async {
        let source = Self.source(songs: 300)
        let store = MemoryStore()
        // The last visit saw an older, shorter playlist.
        let old = PlaylistPage(
            playlist: source.playlist,
            entries: [PlaylistEntry(
                entryID: PlaylistEntryID(server: Self.server, rawValue: "old"),
                track: Self.song(999)
            )],
            total: 1
        )
        await store.put(old, for: source.playlist.id)
        let gate = Gate()
        source.pause = { await gate.wait() }

        let loader = PlaylistLoader(playlist: source.playlist, source: source, store: store)
        let loading = Task { await loader.start() }
        // Until the server answers, the kept songs are what is shown.
        while loader.entries.isEmpty { await Task.yield() }
        #expect(loader.isShowingKeptPage)
        #expect(loader.entries.map(\.track.title) == ["Song 999"])

        await gate.open()
        await loading.value
        #expect(!loader.isShowingKeptPage)
        #expect(loader.entries.count == PlaylistLoader.pageSize)
        #expect(loader.entries.first?.track.title == "Song 0")
        #expect(loader.total == 300)
        #expect(source.asked.first?.offset == 0)
    }

    @Test("The first page from the server is kept for the next visit")
    func firstPageIsKept() async {
        let source = Self.source(songs: 50)
        let store = MemoryStore()
        let loader = PlaylistLoader(playlist: source.playlist, source: source, store: store)
        await loader.start()
        // Saved off the main actor, so give it a moment.
        for _ in 0..<200 where await store.page(for: source.playlist.id) == nil { await Task.yield() }
        let kept = await store.page(for: source.playlist.id)
        #expect(kept?.entries.count == 50)
    }

    @Test("Scrolling to the trigger row brings the next page")
    func nextPageOnScroll() async {
        let source = Self.source(songs: 5_000)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.start()

        // A row near the top asks for nothing.
        await loader.loadMoreIfNeeded(at: loader.entries[10])
        #expect(source.asked.count == 1)

        // The row the loader is watching for does.
        let trigger = loader.entries[PlaylistLoader.pageSize - 25]
        await loader.loadMoreIfNeeded(at: trigger)
        #expect(source.asked.count == 2)
        #expect(source.asked[1].offset == PlaylistLoader.pageSize)
        #expect(loader.entries.count == PlaylistLoader.pageSize * 2)
    }

    @Test("A short last page is the end of the playlist")
    func shortPageEndsIt() async {
        let source = Self.source(songs: 250)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.start()
        #expect(!loader.hasEverything)

        await loader.loadEverything()
        #expect(loader.entries.count == 250)
        #expect(loader.hasEverything)
        // 200 + 50, and no pointless request for a page past the end.
        #expect(source.asked.count == 2)
    }

    @Test("A playlist that ends exactly on a page boundary stops there")
    func exactBoundary() async {
        let source = Self.source(songs: PlaylistLoader.pageSize * 2)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.loadEverything()

        #expect(loader.entries.count == PlaylistLoader.pageSize * 2)
        #expect(loader.hasEverything)
        // The total says it is finished; without that it would take a whole
        // extra round trip to find out.
        #expect(source.asked.count == 2)
    }

    @Test("Rows that make no song still count towards the next page")
    func droppedRowsDoNotShiftPaging() async {
        // Every tenth row is something this app cannot play.
        let rows: [Track?] = (0..<500).map { $0 % 10 == 0 ? nil : Self.song($0) }
        let source = StubSource(playlist: Self.playlist(count: 500), rows: rows)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.loadEverything()

        // 450 songs kept, and no song fetched twice or skipped: paging counts
        // rows, so the offsets step by the page size regardless.
        #expect(loader.entries.count == 450)
        #expect(source.asked.map(\.offset) == [0, 200, 400])
        #expect(Set(loader.entries.map(\.entryID)).count == 450)
    }

    @Test("A page of nothing but unplayable rows does not end the list")
    func emptyPageKeepsGoing() async {
        // The first page is all video; the songs are behind it.
        var rows: [Track?] = Array(repeating: nil, count: 200)
        rows += (0..<50).map { Self.song($0) }
        let source = StubSource(playlist: Self.playlist(count: 250), rows: rows)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.start()

        // One call to `start`, and the songs are on screen rather than an
        // empty list that claims the playlist is empty.
        #expect(loader.entries.count == 50)
        #expect(loader.hasEverything)
        #expect(!loader.isEmpty)
    }

    @Test("A server that reports no total still finds the end")
    func noTotalReported() async {
        let source = Self.source(songs: 450, reportsTotal: false)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.loadEverything()

        #expect(loader.entries.count == 450)
        #expect(loader.hasEverything)
        // Nothing to go on but what arrives, so the count is what arrived.
        #expect(loader.total == nil)
        #expect(loader.songCount == 450)
        // Three requests: 200, 200, and a short 50 that says the list is
        // over. A fourth would mean the short page was not recognised as the
        // end and the server was asked for songs past it.
        #expect(source.asked.map(\.offset) == [0, 200, 400])
    }

    @Test("Reloading throws away a page still in flight")
    func reloadDiscardsInFlightPage() async {
        let source = Self.source(songs: 5_000)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        let held = Held()
        source.pause = { await held.wait() }

        // A first page that will not land until it is let go.
        async let first: Void = loader.start()
        await Task.yield()

        // Meanwhile the list is reloaded and finishes.
        await loader.reload()
        #expect(loader.entries.count == PlaylistLoader.pageSize)

        await held.release()
        await first
        // The page from before the reload did not append itself on top of the
        // one that replaced it.
        #expect(loader.entries.count == PlaylistLoader.pageSize)
        #expect(!loader.isLoadingPage)
    }

    @Test("Two callers wanting everything while a page is in flight both get all of it")
    func concurrentLoadEverything() async {
        let source = Self.source(songs: 450)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        let held = Held()
        source.pause = { await held.wait() }

        // The list paging itself in, as it does when the screen opens.
        let paging = Task { await loader.start() }
        while !loader.isLoadingPage { await Task.yield() }

        // Shuffle and Play tapped meanwhile: each used to find the page busy,
        // make no progress, and report failure.
        let shuffle = Task { await loader.loadEverything() }
        let play = Task { await loader.loadEverything() }
        await Task.yield()
        await held.release()

        #expect(await shuffle.value)
        #expect(await play.value)
        await paging.value
        #expect(loader.entries.count == 450)
        #expect(loader.hasEverything)
        // One request per page, not one per caller.
        #expect(source.asked.map(\.offset) == [0, 200, 400])
        #expect(!loader.isLoadingPage)
    }

    @Test("A cancelled page fetch is not an error, and the list can finish")
    func cancelledFetchIsNotAnError() async {
        let source = Self.source(songs: 450)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.start()
        source.failNext = CancellationError()

        let complete = await loader.loadEverything()
        #expect(!complete)
        #expect(loader.error == nil)
        #expect(!loader.isLoadingPage)

        #expect(await loader.loadEverything())
        #expect(loader.entries.count == 450)
    }

    @Test("A URLSession cancel, wrapped by the provider, is not an error either")
    func wrappedCancelIsNotAnError() async {
        let source = Self.source(songs: 450)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.start()
        source.failNext = ProviderError.network(underlying: URLError(.cancelled))
        await loader.loadMoreIfNeeded(at: loader.entries[loader.entries.count - 1])
        #expect(loader.error == nil)
        #expect(!loader.isLoadingPage)
    }

    @Test("A real failure is kept, does not stick, and can be retried")
    func realFailureCanBeRetried() async {
        let source = Self.source(songs: 450)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.start()
        source.failNext = ProviderError.network(underlying: URLError(.timedOut))

        #expect(!(await loader.loadEverything()))
        #expect(loader.error != nil)
        #expect(!loader.isLoadingPage)

        await loader.retry()
        #expect(loader.error == nil)
        #expect(await loader.loadEverything())
        #expect(loader.entries.count == 450)
    }

    @Test("Cancelling the caller does not cancel the fetch")
    func cancellingTheCallerLeavesTheFetch() async {
        let source = Self.source(songs: 450)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        let held = Held()
        source.pause = { await held.wait() }

        let caller = Task { await loader.loadEverything() }
        while !loader.isLoadingPage { await Task.yield() }
        caller.cancel()
        await held.release()

        #expect(!(await caller.value))
        // The page it was waiting on still landed.
        #expect(loader.entries.count >= PlaylistLoader.pageSize)
        #expect(loader.error == nil)
        #expect(await loader.loadEverything())
        #expect(loader.entries.count == 450)
    }

    @Test("Length is added up as pages land")
    func durationRunningTotal() async {
        let source = Self.source(songs: 300)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.loadEverything()
        #expect(loader.everyDurationKnown)
        #expect(loader.durationOfLoaded == 300 * 100)
    }

    @Test("One song with no length makes the total an undercount, and it says so")
    func durationUnknown() async {
        var rows: [Track?] = (0..<10).map { Self.song($0) }
        rows.append(Self.song(99, seconds: nil))
        let source = StubSource(playlist: Self.playlist(count: 11), rows: rows)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.loadEverything()
        #expect(!loader.everyDurationKnown)
    }

    @Test("An empty playlist reports itself empty")
    func emptyPlaylist() async {
        let source = Self.source(songs: 0)
        let loader = PlaylistLoader(playlist: source.playlist, source: source)
        await loader.start()
        #expect(loader.isEmpty)
        #expect(loader.hasEverything)
    }
}

/// A gate a test can hold a request at.
private actor Held {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

@MainActor
@Suite("A playlist loader's revision")
struct PlaylistLoaderRevisionTests {
    private static let server = ServerID()

    @Test("Bumps whenever entries change, including a reload to the same count")
    func revisionFollowsEntries() async {
        let playlist = Playlist(id: MediaID(server: Self.server, rawValue: "p"), name: "P", trackCount: 450)
        let rows: [Track?] = (0..<450).map { Track(id: MediaID(server: Self.server, rawValue: "t\($0)"), title: "S\($0)") }
        let source = StubSource(playlist: playlist, rows: rows)
        let loader = PlaylistLoader(playlist: playlist, source: source)
        let initial = loader.revision
        await loader.start()
        let first = loader.revision
        #expect(first > initial)
        await loader.loadEverything()
        let second = loader.revision
        #expect(second > first)
        let count = loader.entries.count
        await loader.reload()
        await loader.loadEverything()
        #expect(loader.entries.count == count)
        #expect(loader.revision > second)
    }
}
