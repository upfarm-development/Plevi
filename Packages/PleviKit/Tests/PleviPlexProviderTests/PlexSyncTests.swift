import Foundation
import Synchronization
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// What a sync asks Plex for: songs without the rest of the library, the
/// server's own counts, and whether anything has changed since last time.
@Suite("Plex, syncing")
struct PlexSyncTests {
    /// Answers by what was asked for, and keeps every request so the shape of
    /// the conversation can be asserted.
    private final class Router: HTTPTransport, @unchecked Sendable {
        /// Locked, because `libraryCounts()` fires its three probes at once
        /// and three tasks appending to one array is not an array.
        let recorded = Mutex<[URLRequest]>([])
        var sections = PlexSyncTests.sectionsJSON
        var totals: [String: Int?] = ["8": 1_473, "9": 5_324, "10": 61_397]
        /// A server that cannot be reached at all.
        var refuses = false

        var requests: [URLRequest] { recorded.withLock { $0 } }

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            recorded.withLock { $0.append(request) }
            if refuses { throw ProviderError.network(underlying: URLError(.timedOut)) }
            let url = request.url!
            let path = url.path()
            let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "type" }?.value
            let json: String
            if path == "/library/sections" {
                json = sections
            } else if request.value(forHTTPHeaderField: "X-Plex-Container-Size") == "1" {
                let total = (totals[type ?? ""] ?? nil).map { "\"totalSize\": \($0)," } ?? ""
                json = "{\"MediaContainer\": {\"size\": 1, \(total) \"Metadata\": []}}"
            } else {
                json = PlexSyncTests.trackPageJSON
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(json.utf8), response)
        }

        func download(
            _ request: URLRequest,
            to destination: URL,
            onProgress: @Sendable (Int64, Int64?) -> Void
        ) async throws {
            throw ProviderError.notFound
        }
    }

    /// Two songs, enough to prove a page came back mapped.
    static let trackPageJSON = """
    {"MediaContainer": {"size": 2, "totalSize": 61397, "Metadata": [
        {"ratingKey": "101", "type": "track", "title": "One", "duration": 210000,
         "parentRatingKey": "11", "grandparentRatingKey": "1",
         "parentTitle": "A Record", "grandparentTitle": "A Band"},
        {"ratingKey": "102", "type": "track", "title": "Two", "duration": 190000,
         "parentRatingKey": "11", "grandparentRatingKey": "1",
         "parentTitle": "A Record", "grandparentTitle": "A Band"}
    ]}}
    """

    /// A server with two libraries, of which one is this app's — and a row of
    /// rubbish in the middle, because one unreadable section must not take
    /// the answer down with it.
    static let sectionsJSON = """
    {"MediaContainer": {"size": 3, "Directory": [
        {"key": "3", "title": "Films", "type": "movie", "contentChangedAt": 111},
        "nonsense",
        {"key": "6", "title": "Music", "type": "artist",
         "contentChangedAt": 1757000000, "updatedAt": 1756000000, "scannedAt": 1756500000}
    ]}}
    """

    private let server = ServerID()

    private func provider(_ transport: any HTTPTransport) -> PlexProvider {
        PlexProvider(
            serverID: server,
            config: PlexServerConfig(
                baseURL: URL(string: "https://plex.example")!,
                token: "secret",
                sectionKey: "6",
                sectionTitle: "Music"
            ),
            identity: PlexIdentity(clientIdentifier: "client-1", deviceName: "Test iPhone"),
            transport: transport
        )
    }

    @Test("A page of songs is one request for songs, not three for everything")
    func songsAreOneRequest() async throws {
        let router = Router()
        let songs = try await provider(router).tracks(offset: 1_000, limit: 500)

        #expect(songs.count == 2)
        #expect(router.requests.count == 1)
        let request = try #require(router.requests.first)
        #expect(request.url?.query()?.contains("type=10") == true)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Container-Start") == "1000")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Container-Size") == "500")
    }

    @Test("Counts are read from a single row, not from the library")
    func countsAreAskedForCheaply() async throws {
        let router = Router()
        let counts = try await provider(router).libraryCounts()

        #expect(counts.artists == 1_473)
        #expect(counts.albums == 5_324)
        #expect(counts.tracks == 61_397)
        #expect(router.requests.count == 3)
        // One row asked for, not none: a server that ignored a size of zero
        // would answer a count with the whole library.
        for request in router.requests {
            #expect(request.value(forHTTPHeaderField: "X-Plex-Container-Size") == "1")
        }
    }

    @Test("A count the server does not give is nothing, never zero")
    func anUnansweredCountIsNil() async throws {
        let router = Router()
        router.totals["10"] = Int?.none
        let counts = try await provider(router).libraryCounts()

        // Zero here would tell a sync its walk had found everything there was
        // to find, and let it delete the rest of the library.
        #expect(counts.tracks == nil)
        #expect(counts.albums == 5_324)
    }

    @Test("The change token is this library's own content stamp")
    func theTokenIsThisLibrarysStamp() async throws {
        let router = Router()
        let token = try await provider(router).libraryChangeToken()

        // The music section's number, not the film library's, and carrying
        // where it came from so one server's counter cannot pass for
        // another's.
        #expect(token == "plex:6:1757000000")
    }

    @Test("A library that reports no stamp is never taken for unchanged")
    func noStampMeansNoToken() async throws {
        let router = Router()
        router.sections = """
        {"MediaContainer": {"size": 1, "Directory": [
            {"key": "6", "title": "Music", "type": "artist", "updatedAt": 1756000000}
        ]}}
        """
        #expect(try await provider(router).libraryChangeToken() == nil)
    }

    @Test("A stamp sent as text reads the same as one sent as a number")
    func aTextStampIsReadToo() async throws {
        let router = Router()
        router.sections = """
        {"MediaContainer": {"size": 1, "Directory": [
            {"key": "6", "title": "Music", "contentChangedAt": "1757000000"}
        ]}}
        """
        #expect(try await provider(router).libraryChangeToken() == "plex:6:1757000000")
    }

    @Test("A probe that cannot be made is no token, not a failed sync")
    func anUnreachableServerHasNoToken() async throws {
        let router = Router()
        router.refuses = true

        // Nil and a throw mean the same thing to the sync — walk the library
        // — but only one of them can be told apart from a sync that could not
        // run at all, and it is not the throw.
        #expect(try await provider(router).libraryChangeToken() == nil)
        #expect(try await provider(router).libraryCounts().tracks == nil)
    }
}
