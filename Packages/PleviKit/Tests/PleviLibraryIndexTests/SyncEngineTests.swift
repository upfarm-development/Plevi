import Foundation
import GRDB
import Synchronization
import Testing
import PleviDomain
import PleviMockProvider
@testable import PleviLibraryIndex

/// A server that answers exactly what a test tells it to, and remembers what it was asked.
private final class ScriptedServer: MusicServerProvider, Sendable {
    struct Script: Sendable {
        var artists: [Artist] = []
        var albums: [Album] = []
        var tracks: [Track] = []
        var counts = LibraryCounts()
        var token: String?
        /// Serve no more than this many songs however many are asked for,
        /// which is what a library that half arrives looks like from here.
        var servesAtMost: Int?
        /// How long each page takes to come back. Without some delay every
        /// page is answered before the next one is even asked for, and a
        /// test cannot tell a wave from a queue.
        var pageTakes: Duration?
        /// Requests that fail before they succeed, by what is asked for:
        /// "artists", "albums@0", "tracks@500". What a link that drops one
        /// request in a hundred looks like from here.
        var failures: [String: (remaining: Int, error: ProviderError)] = [:]
    }

    struct Asked: Sendable {
        var trackPages: [Int] = []
        var searches = 0
        var tokenReads = 0
        var countReads = 0
        /// The most pages that were ever in the air at the same moment.
        var pagesAtOnce = 0
        fileprivate var inFlight = 0
    }

    let serverID = ServerID()
    let capabilities: ServerCapabilities = []

    private let script: Mutex<Script>
    private let asked = Mutex(Asked())

    init(_ script: Script) {
        self.script = Mutex(script)
    }

    func rewrite(_ change: @Sendable (inout Script) -> Void) {
        script.withLock { change(&$0) }
    }

    var record: Asked { asked.withLock { $0 } }

    // MARK: What a sync asks for

    /// Throws the scripted failure for `key`, while it has any left.
    private func failIfScripted(_ key: String) throws {
        let error = script.withLock { script -> ProviderError? in
            guard var scripted = script.failures[key], scripted.remaining > 0 else { return nil }
            scripted.remaining -= 1
            script.failures[key] = scripted
            return scripted.error
        }
        if let error { throw error }
    }

    func artists() async throws -> [Artist] {
        try failIfScripted("artists")
        return script.withLock(\.artists)
    }

    func albums(filter: AlbumFilter, offset: Int, limit: Int) async throws -> [Album] {
        try failIfScripted("albums@\(offset)")
        let all = script.withLock(\.albums)
        return Array(all.dropFirst(offset).prefix(limit))
    }

    func tracks(offset: Int, limit: Int) async throws -> [Track] {
        asked.withLock {
            $0.trackPages.append(offset)
            $0.inFlight += 1
            $0.pagesAtOnce = max($0.pagesAtOnce, $0.inFlight)
        }
        defer { asked.withLock { $0.inFlight -= 1 } }
        try failIfScripted("tracks@\(offset)")
        let script = script.withLock { $0 }
        if let takes = script.pageTakes { try? await Task.sleep(for: takes) }
        let all = Array(script.tracks.prefix(script.servesAtMost ?? script.tracks.count))
        return Array(all.dropFirst(offset).prefix(limit))
    }

    func libraryCounts() async throws -> LibraryCounts {
        asked.withLock { $0.countReads += 1 }
        return script.withLock(\.counts)
    }

    func libraryChangeToken() async throws -> String? {
        asked.withLock { $0.tokenReads += 1 }
        return script.withLock(\.token)
    }

    func search(_ query: String, limit: Int, offset: Int) async throws -> SearchResults {
        asked.withLock { $0.searches += 1 }
        return SearchResults()
    }

    // MARK: Everything else

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
    func setFavorite(_ favorite: Bool, for id: MediaID, kind: MediaKind) async throws {}
    func scrobble(id: MediaID, at date: Date, submission: Bool) async throws {}
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

private func library(
    tracks count: Int,
    on server: ServerID
) -> (artists: [Artist], albums: [Album], tracks: [Track]) {
    let artistID = MediaID(server: server, rawValue: "artist-1")
    let albumID = MediaID(server: server, rawValue: "album-1")
    return (
        [Artist(id: artistID, name: "The Scripted")],
        [Album(id: albumID, name: "One Long Record", artistName: "The Scripted", artistID: artistID)],
        (0..<count).map { number in
            Track(
                id: MediaID(server: server, rawValue: "track-\(number)"),
                title: "Song \(number)",
                albumName: "One Long Record",
                albumID: albumID,
                artistName: "The Scripted",
                artistID: artistID,
                trackNumber: number + 1
            )
        }
    )
}

/// An index in a file rather than in memory, so a test can open a second
/// connection and put `syncState` into a state the public API cannot reach.
private func indexOnDisk(for server: ServerID) throws -> (LibraryIndex, URL, () -> Void) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.sqlite")
    return (
        try LibraryIndex(databaseURL: url, serverID: server),
        url,
        { try? FileManager.default.removeItem(at: directory) }
    )
}

private func editSyncState(_ url: URL, _ sql: String) throws {
    try DatabaseQueue(path: url.path).write { try $0.execute(sql: sql) }
}

private func scripted(tracks count: Int) -> ScriptedServer {
    let server = ServerID()
    let made = library(tracks: count, on: server)
    return ScriptedServer(
        ScriptedServer.Script(artists: made.artists, albums: made.albums, tracks: made.tracks)
    )
}

@Suite("Walking a library")
struct SyncWalkTests {
    @Test("Songs are asked for on their own, never through a search")
    func asksForSongsNotASearch() async throws {
        let provider = scripted(tracks: 1_200)
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        let summary = try await engine.fullSync()

        #expect(summary.tracks == 1_200)
        #expect(provider.record.searches == 0)
    }

    @Test("Pages go out together and the walk still ends on the empty one")
    func pagesGoOutTogether() async throws {
        let provider = scripted(tracks: 1_200)
        provider.rewrite { $0.pageTakes = .milliseconds(30) }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()

        // Three pages of songs and the empty one that says where the library stops — all four asked
        // for at once, rather than four round trips one after another.
        #expect(provider.record.trackPages.sorted() == [0, 500, 1_000, 1_500])
        #expect(provider.record.pagesAtOnce == 4)
        #expect(try index.stats().trackCount == 1_200)
    }

    @Test("A count the server understates does not slow the rest of the walk to a crawl")
    func anUnderstatedTotalDoesNotCollapseTheWave() async throws {
        let provider = scripted(tracks: 4_000)
        // The server says 1 000 and holds 4 000.
        provider.rewrite {
            $0.counts = LibraryCounts(tracks: 1_000)
            $0.pageTakes = .milliseconds(20)
        }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()

        #expect(try index.stats().trackCount == 4_000)
        #expect(provider.record.pagesAtOnce == 4)
    }

    @Test("A server that understates its own size is still walked to the end")
    func understatedTotalDoesNotEndTheWalk() async throws {
        let provider = scripted(tracks: 1_200)
        provider.rewrite { $0.counts = LibraryCounts(tracks: 600) }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        let summary = try await engine.fullSync()

        // The count narrows how many pages are asked for at a time. It is
        // never allowed to decide where the library ends.
        #expect(summary.tracks == 1_200)
        #expect(try index.stats().trackCount == 1_200)
        #expect(summary.outcome == .walked)
    }

    @Test("A walk that comes back half empty deletes nothing, and is retried")
    func aShortWalkDeletesNothingAndIsRetried() async throws {
        let provider = scripted(tracks: 1_000)
        provider.rewrite {
            $0.token = "same"
            $0.counts = LibraryCounts(tracks: 1_000)
        }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        #expect(try index.stats().trackCount == 1_000)
        let walkedAt = try #require(try index.checkpoint().lastFullSyncAt)

        // Now the server still says a thousand songs and hands back a hundred — a flake, not a
        // library that shrank, so the token has not moved.
        provider.rewrite { $0.servesAtMost = 100 }
        let summary = try await engine.fullSync(force: true)

        #expect(summary.outcome == .shortWalk)
        #expect(try index.stats().trackCount == 1_000)
        // The token this walk was fetched under is forgotten rather than kept.
        #expect(try index.checkpoint().changeToken == nil)
        // And the clock that forces a whole walk from time to time is not
        // reset by a walk that did not manage one.
        #expect(try index.checkpoint().lastFullSyncAt == walkedAt)

        // Which is the point of both: the next sync goes back for it.
        provider.rewrite { $0.servesAtMost = nil }
        #expect(try await engine.fullSync().outcome == .walked)
    }

    @Test("A walk nothing corroborated is not allowed to promise the next one may skip")
    func anUncountedWalkDoesNotVouch() async throws {
        let provider = scripted(tracks: 600)
        // A token, but no counts at all — which is what every probe failure collapses to.
        provider.rewrite { $0.token = "same" }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        #expect(try index.checkpoint().changeToken == nil)

        let walked = provider.record.trackPages.count
        #expect(try await engine.fullSync().outcome == .walked)
        #expect(provider.record.trackPages.count > walked)
    }

    @Test("An honest count ends the walk in one request, not four")
    func theTerminatingWaveIsOnePage() async throws {
        // Four pages exactly, which is the size that can tell the answers apart.
        let provider = scripted(tracks: 2_000)
        provider.rewrite { $0.counts = LibraryCounts(tracks: 2_000) }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()

        // Four pages of songs, then the one empty page that says where the library stops.
        #expect(provider.record.trackPages.sorted() == [0, 500, 1_000, 1_500, 2_000])
        #expect(try index.stats().trackCount == 2_000)
    }

    @Test("Counting the artists does not vouch for a walk of the songs")
    func aCountOfSomethingElseVouchesForNothing() async throws {
        let provider = scripted(tracks: 1_200)
        // What one timed-out probe of three looks like: the artists and
        // albums were counted, the songs were not.
        provider.rewrite {
            $0.token = "same"
            $0.counts = LibraryCounts(artists: 1, albums: 1, tracks: nil)
            $0.servesAtMost = 100
        }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()

        // The artist count matched, and it has nothing to say about a track walk that stopped at
        // page one of three.
        #expect(try index.checkpoint().changeToken == nil)
        let walked = provider.record.trackPages.count
        #expect(try await engine.fullSync().outcome == .walked)
        #expect(provider.record.trackPages.count > walked)
    }

    @Test("A count of zero vouches for nothing either")
    func aZeroCountVouchesForNothing() async throws {
        let provider = scripted(tracks: 1_200)
        provider.rewrite {
            $0.token = "same"
            $0.counts = LibraryCounts(tracks: 0)
        }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()

        // A zero is not a count. Nothing declines to judge it and nothing may
        // be concluded from it — least of all that the next six hours of
        // syncs can be skipped because an empty answer was verified.
        #expect(try index.checkpoint().changeToken == nil)
    }

    @Test("A server part way through its own scan is never swept")
    func aRescanningServerIsNeverSwept() async throws {
        let provider = scripted(tracks: 1_000)
        provider.rewrite { $0.counts = LibraryCounts(tracks: 1_000) }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()

        // Half the library is missing because the server is rebuilding its
        // database, and it says so. Its own count agrees with what it served,
        // so the numbers alone would call this a healthy walk.
        provider.rewrite {
            $0.servesAtMost = 500
            $0.counts = LibraryCounts(tracks: 500, isRescanning: true)
        }
        let summary = try await engine.fullSync()

        #expect(summary.outcome == .shortWalk)
        #expect(try index.stats().trackCount == 1_000)
    }

    @Test("An honest sweep still removes what is gone")
    func anHonestSweepStillPrunes() async throws {
        let provider = scripted(tracks: 1_000)
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        #expect(try index.stats().trackCount == 1_000)

        // Half the library really did go, and the server says so.
        provider.rewrite {
            $0.counts = LibraryCounts(tracks: 500)
            $0.servesAtMost = 500
        }
        let summary = try await engine.fullSync()

        #expect(summary.outcome == .walked)
        #expect(try index.stats().trackCount == 500)
    }

    @Test("A server with nothing better to offer is paged through its search")
    func theDefaultForwardsToSearch() async throws {
        let provider = MockProvider()
        let songs = try await provider.tracks(offset: 0, limit: 100)
        #expect(songs.count == 14)
    }
}

@Suite("Skipping a sync the server says is not owed")
struct SyncGateTests {
    @Test("A token that has not moved skips the walk")
    func anUnmovedTokenSkipsTheWalk() async throws {
        let provider = scripted(tracks: 600)
        provider.rewrite {
            $0.token = "same"
            $0.counts = LibraryCounts(tracks: 600)
        }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        let walked = provider.record.trackPages.count

        // A moment between the two syncs, so the date the skip writes has to
        // be a new one rather than merely not older than the old one.
        try await Task.sleep(for: .milliseconds(20))
        let between = Date()
        try await Task.sleep(for: .milliseconds(20))

        let summary = try await engine.fullSync()

        #expect(summary.outcome == .unchanged)
        #expect(provider.record.trackPages.count == walked)
        #expect(try index.stats().trackCount == 600)
        // Still current, and recorded as such: the launch that asks whether a
        // sync is due has to see that one just happened, or it asks again on
        // every launch for ever.
        #expect(try #require(try index.stats().lastSyncAt) > between)
    }

    @Test("A token that moved is walked")
    func amovedTokenIsWalked() async throws {
        let provider = scripted(tracks: 600)
        provider.rewrite {
            $0.token = "before"
            $0.counts = LibraryCounts(tracks: 600)
        }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        let walked = provider.record.trackPages.count

        provider.rewrite { $0.token = "after" }
        let summary = try await engine.fullSync()

        #expect(summary.outcome == .walked)
        #expect(provider.record.trackPages.count > walked)
    }

    @Test("Asking for a sync by hand walks whatever the server says")
    func forceIgnoresTheToken() async throws {
        let provider = scripted(tracks: 600)
        provider.rewrite {
            $0.token = "same"
            $0.counts = LibraryCounts(tracks: 600)
        }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        let walked = provider.record.trackPages.count

        let summary = try await engine.fullSync(force: true)

        #expect(summary.outcome == .walked)
        #expect(provider.record.trackPages.count > walked)
    }

    @Test("A server with no token of its own is never skipped")
    func noTokenMeansNoSkipping() async throws {
        let provider = scripted(tracks: 600)
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        let walked = provider.record.trackPages.count

        let summary = try await engine.fullSync()

        // Two nils are not a match. A library nobody can vouch for gets read.
        #expect(summary.outcome == .walked)
        #expect(provider.record.trackPages.count > walked)
    }

    @Test("Nothing is skipped before a whole walk has ever finished")
    func nothingIsSkippedBeforeTheFirstWalk() async throws {
        let provider = scripted(tracks: 600)
        provider.rewrite {
            $0.token = "same"
            $0.counts = LibraryCounts(tracks: 600)
        }
        let (index, url, cleanUp) = try indexOnDisk(for: provider.serverID)
        defer { cleanUp() }
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        // An index with a token beside it but nothing saying a walk ever finished — what an upgrade
        // from before this column, or a sync interrupted half way, could leave.
        try editSyncState(url, "UPDATE syncState SET lastFullSyncAt = NULL")
        let walked = provider.record.trackPages.count

        let summary = try await engine.fullSync()
        #expect(summary.outcome == .walked)
        #expect(provider.record.trackPages.count > walked)
    }

    @Test("A walk stamped in the future does not skip the library for ever")
    func aFutureStampDoesNotFreezeTheLibrary() async throws {
        let provider = scripted(tracks: 600)
        provider.rewrite {
            $0.token = "same"
            $0.counts = LibraryCounts(tracks: 600)
        }
        let (index, url, cleanUp) = try indexOnDisk(for: provider.serverID)
        defer { cleanUp() }
        let engine = LibrarySyncEngine(provider: provider, index: index)

        _ = try await engine.fullSync()
        // A phone whose clock was running fast when it last synced, or an index restored from one.
        let ahead = Date().addingTimeInterval(60 * 60 * 24 * 30)
        try editSyncState(url, "UPDATE syncState SET lastFullSyncAt = '\(Self.stamp(ahead))'")
        let walked = provider.record.trackPages.count

        #expect(try await engine.fullSync().outcome == .walked)
        #expect(provider.record.trackPages.count > walked)
    }

    /// The shape GRDB stores a `Date` in.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

/// A walk is a hundred or more requests, and one of them timing out used to throw the whole walk
/// away: nothing finished, and the next attempt began again at the first page.
@Suite("Walking a library over a flaky link")
struct SyncFlakyLinkTests {
    private func engine(_ provider: ScriptedServer, index: LibraryIndex) -> LibrarySyncEngine {
        // No waiting between attempts: the claim is about whether it retries.
        LibrarySyncEngine(provider: provider, index: index, pageRetryDelays: [.zero, .zero])
    }

    private static let timeout = ProviderError.network(underlying: URLError(.timedOut))

    @Test("A page that times out once is asked for again and the walk finishes")
    func aTimeoutOnePageIsRetried() async throws {
        let provider = scripted(tracks: 1_200)
        provider.rewrite { $0.failures["tracks@500"] = (1, Self.timeout) }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)

        let summary = try await engine(provider, index: index).fullSync()

        #expect(summary.tracks == 1_200)
        #expect(summary.outcome != .unchanged)
        #expect(try index.stats().trackCount == 1_200)
        #expect(provider.record.trackPages.filter { $0 == 500 }.count == 2, "asked twice, answered the second time")
    }

    @Test("The artists and album pages are retried the same way")
    func artistsAndAlbumsAreRetried() async throws {
        let provider = scripted(tracks: 10)
        provider.rewrite {
            $0.failures["artists"] = (2, Self.timeout)
            $0.failures["albums@0"] = (1, ProviderError.network(underlying: URLError(.networkConnectionLost)))
        }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)

        let summary = try await engine(provider, index: index).fullSync()
        #expect(summary.artists == 1)
        #expect(summary.albums == 1)
    }

    @Test("A gateway that was briefly away is retried")
    func gatewayIsRetried() async throws {
        let provider = scripted(tracks: 10)
        provider.rewrite { $0.failures["artists"] = (1, ProviderError.serverError(code: 502, message: nil, helpURL: nil)) }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        let summary = try await engine(provider, index: index).fullSync()
        #expect(summary.artists == 1)
    }

    /// Bounded: a page that keeps failing is not blinking, and the walk must end rather than ask
    /// for ever.
    @Test("A page that keeps failing ends the walk, and does not close the sync gate")
    func aPageThatKeepsFailingEndsTheWalk() async throws {
        let provider = scripted(tracks: 1_200)
        provider.rewrite { $0.failures["tracks@500"] = (100, Self.timeout) }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)

        await #expect(throws: Self.timeout) {
            _ = try await engine(provider, index: index).fullSync()
        }
        #expect(provider.record.trackPages.filter { $0 == 500 }.count == 3, "one try and two retries")
        #expect(try index.lastSyncAt() == nil, "an unfinished walk must not stamp the library as synced")
    }

    @Test("What will not change is not asked again", arguments: [
        ProviderError.notAuthenticated(.wrongCredentials),
        ProviderError.notFound,
        ProviderError.malformedResponse(details: "nonsense"),
        ProviderError.serverError(code: 500, message: nil, helpURL: nil),
    ])
    func answersAreNotRetried(error: ProviderError) async throws {
        let provider = scripted(tracks: 10)
        provider.rewrite { $0.failures["artists"] = (1, error) }
        let index = try LibraryIndex(inMemoryFor: provider.serverID)
        await #expect(throws: error) {
            _ = try await engine(provider, index: index).fullSync()
        }
    }
}
