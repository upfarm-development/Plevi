import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// Play history: what is asked of `/status/sessions/history/all`, and what
/// is made of the answer.
@Suite("Plex play history")
struct PlexPlayHistoryTests {
    /// Hands back one canned payload for every request and keeps the last
    /// one made, so the URL and headers the provider builds can be
    /// inspected.
    private final class Recorder: HTTPTransport, @unchecked Sendable {
        let json: String
        var lastRequest: URLRequest?
        var requestCount = 0

        init(json: String) { self.json = json }

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
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

    /// A different canned page per call, so paging across several requests
    /// can be exercised without a real server.
    private final class PagingRecorder: HTTPTransport, @unchecked Sendable {
        let pages: [String]
        var requestCount = 0
        var startsSeen: [String] = []

        init(pages: [String]) { self.pages = pages }

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            startsSeen.append(request.value(forHTTPHeaderField: "X-Plex-Container-Start") ?? "")
            let json = requestCount < pages.count ? pages[requestCount] : pages.last!
            requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
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

    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func provider(transport: any HTTPTransport) -> PlexProvider {
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

    private let payload = """
    {"MediaContainer": {"size": 3, "Metadata": [
      {"ratingKey": "701", "type": "track", "title": "Song One",
       "parentRatingKey": "501", "grandparentRatingKey": "12", "viewedAt": 1743400000},
      {"ratingKey": "702", "type": "track", "title": "Song Two",
       "parentRatingKey": "501", "grandparentRatingKey": "12", "viewedAt": 1743500000},
      {"ratingKey": "9", "type": "movie", "title": "Not Music", "viewedAt": 1743300000}
    ]}}
    """

    @Test("Asks the history endpoint sorted oldest-first, with both ends of the window and the section")
    func requestShape() async throws {
        let transport = Recorder(json: payload)
        let provider = provider(transport: transport)
        _ = try await provider.playHistory(
            from: Date(timeIntervalSince1970: 1_700_000_000),
            to: Date(timeIntervalSince1970: 1_800_000_000),
            limit: 50
        )
        let url = try #require(transport.lastRequest?.url)
        #expect(url.path() == "/status/sessions/history/all")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "librarySectionID", value: "6")))
        #expect(query.contains(URLQueryItem(name: "sort", value: "viewedAt:asc")))
        // One second before `from`: the filter is strictly greater-than on
        // the server, so this is what makes a play at exactly `from` itself
        // count — see `playHistory`'s own comment on the query.
        #expect(query.contains(URLQueryItem(name: "viewedAt>", value: "1699999999")))
        // Deliberately not sent — see `playHistory`'s own doc comment for
        // why an upper bound and a type filter are enforced client-side
        // instead, below, rather than trusted to the server.
        #expect(!query.contains { $0.name == "viewedAt<" })
        #expect(!query.contains { $0.name == "type" })
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "X-Plex-Container-Start") == "0")
    }

    @Test("Maps track rows to entries and leaves everything else out")
    func mapping() async throws {
        let transport = Recorder(json: payload)
        let provider = provider(transport: transport)
        let entries = try await provider.playHistory(from: .distantPast, to: .distantFuture, limit: 50)
        #expect(entries.count == 2)
        #expect(entries.map(\.trackID).contains(id("701")))
        #expect(entries.first { $0.trackID == id("701") }?.albumID == id("501"))
        #expect(entries.first { $0.trackID == id("701") }?.playedAt == Date(timeIntervalSince1970: 1_743_400_000))
        #expect(!entries.map(\.trackID).contains(id("9")))
    }

    @Test("The album still resolves when a history row carries only the path form of its parent")
    func fallsBackToTheParentPathWhenTheRatingKeyIsMissing() async throws {
        // No parentRatingKey at all — only parentKey, the shape a session-
        // history row has been seen taking even though an ordinary
        // browsing row always carries both.
        let payload = """
        {"MediaContainer": {"size": 1, "Metadata": [
          {"ratingKey": "701", "type": "track", "parentKey": "/library/metadata/501", "viewedAt": 100}
        ]}}
        """
        let transport = Recorder(json: payload)
        let provider = provider(transport: transport)
        let entries = try await provider.playHistory(from: .distantPast, to: .distantFuture, limit: 50)
        #expect(entries.first?.albumID == id("501"))
    }

    @Test("A row at or past `to` stops paging rather than being kept or read past")
    func stopsAtTheUpperBound() async throws {
        let payload = """
        {"MediaContainer": {"size": 2, "Metadata": [
          {"ratingKey": "1", "type": "track", "parentRatingKey": "9", "viewedAt": 100},
          {"ratingKey": "2", "type": "track", "parentRatingKey": "9", "viewedAt": 200}
        ]}}
        """
        let transport = Recorder(json: payload)
        let provider = provider(transport: transport)
        let entries = try await provider.playHistory(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 150),
            limit: 50
        )
        #expect(entries.count == 1)
        #expect(entries.first?.trackID == id("1"))
    }

    @Test("A window with more plays than one page holds pages through all of them")
    func pagesThroughTheWholeWindow() async throws {
        // Exactly a full page (200 rows) so the provider cannot tell this
        // apart from a genuinely longer window without asking for more.
        let rows = (0..<200).map { index in
            """
            {"ratingKey": "\(index)", "type": "track", "parentRatingKey": "9", "viewedAt": \(100 + index)}
            """
        }.joined(separator: ",")
        let first = #"{"MediaContainer": {"size": 200, "Metadata": [\#(rows)]}}"#
        let second = """
        {"MediaContainer": {"size": 1, "Metadata": [
          {"ratingKey": "200", "type": "track", "parentRatingKey": "9", "viewedAt": 300}
        ]}}
        """
        let transport = PagingRecorder(pages: [first, second])
        let provider = provider(transport: transport)
        let entries = try await provider.playHistory(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 1000),
            limit: 500
        )
        #expect(entries.count == 201)
        #expect(transport.requestCount == 2)
        #expect(transport.startsSeen == ["0", "200"])
    }

    @Test("`limit` is a safety backstop, not the mechanism the window is expressed through")
    func limitStopsEarlyWithinTheWindow() async throws {
        let payload = """
        {"MediaContainer": {"size": 2, "Metadata": [
          {"ratingKey": "1", "type": "track", "parentRatingKey": "9", "viewedAt": 100},
          {"ratingKey": "2", "type": "track", "parentRatingKey": "9", "viewedAt": 200}
        ]}}
        """
        let transport = Recorder(json: payload)
        let provider = provider(transport: transport)
        let entries = try await provider.playHistory(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 1000),
            limit: 1
        )
        #expect(entries.count == 1)
        #expect(entries.first?.trackID == id("1"))
    }
}
