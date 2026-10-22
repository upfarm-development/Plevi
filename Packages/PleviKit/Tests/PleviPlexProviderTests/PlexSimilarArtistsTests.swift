import Foundation
import Testing
import PleviDomain
import PleviTransport
import Synchronization
@testable import PleviPlexProvider

/// Sonically similar artists: Plex has no scene-based list of its own, so the
/// artist page's shelf is filled from the same `/nearest` analysis that
/// answers for albums and tracks.
@Suite("Plex similar artists")
struct PlexSimilarArtistsTests {
    /// Answers by path, because `artistInfo` asks two questions at once —
    /// and records what it was asked, under a lock, because it asks them
    /// concurrently.
    private final class Router: HTTPTransport, @unchecked Sendable {
        private let seen = Mutex<[URLRequest]>([])
        let metadata: String
        let nearest: String?

        init(metadata: String, nearest: String?) {
            self.metadata = metadata
            self.nearest = nearest
        }

        var requests: [URLRequest] { seen.withLock { $0 } }

        func url(containing fragment: String) -> URL? {
            requests.compactMap(\.url).first { $0.path().contains(fragment) }
        }

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            seen.withLock { $0.append(request) }
            let isNearest = request.url?.path().hasSuffix("/nearest") == true
            if isNearest, nearest == nil {
                // What a server that has never run its sonic analysis does.
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
                )!
                return (Data(), response)
            }
            let body = isNearest ? nearest! : metadata
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
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

    private func provider(metadata: String, nearest: String?) -> (PlexProvider, Router) {
        let transport = Router(metadata: metadata, nearest: nearest)
        let provider = PlexProvider(
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
        return (provider, transport)
    }

    private let artistRow = """
    {"MediaContainer": {"size": 1, "Metadata": [
      {"ratingKey": "12", "type": "artist", "title": "Television",
       "summary": "Formed in New York in 1973."}
    ]}}
    """

    /// Two artists, the seed itself, and an album row with no business on a
    /// shelf of artists.
    private let neighbours = """
    {"MediaContainer": {"size": 4, "Metadata": [
      {"ratingKey": "21", "type": "artist", "title": "Wire",
       "thumb": "/library/metadata/21/thumb/1"},
      {"ratingKey": "12", "type": "artist", "title": "Television"},
      {"ratingKey": "99", "type": "album", "title": "Marquee Moon"},
      {"ratingKey": "22", "type": "artist", "title": "Mission of Burma"}
    ]}}
    """

    @Test("Asks the artist's own nearest endpoint, widened like the album one")
    func asksTheNearestEndpoint() async throws {
        let (provider, transport) = provider(metadata: artistRow, nearest: neighbours)
        _ = try await provider.artistInfo(id: id("12"))

        let url = try #require(transport.url(containing: "/nearest"))
        #expect(url.path() == "/library/metadata/12/nearest")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "maxDistance", value: "0.5")))
        #expect(query.contains { $0.name == "limit" })
    }

    @Test("Only artists come back, and never the artist you are looking at")
    func mapsArtistsAndDropsTheSeed() async throws {
        let (provider, _) = provider(metadata: artistRow, nearest: neighbours)
        let info = try await provider.artistInfo(id: id("12"))
        #expect(info.similarArtists.map(\.name) == ["Wire", "Mission of Burma"])
    }

    @Test("The biography still arrives when the analysis has never been run")
    func aMissingAnalysisDoesNotCostTheBiography() async throws {
        let (provider, _) = provider(metadata: artistRow, nearest: nil)
        let info = try await provider.artistInfo(id: id("12"))
        #expect(info.biography == "Formed in New York in 1973.")
        #expect(info.similarArtists.isEmpty)
    }

    @Test("An analysed server with no neighbours for this one is not an error")
    func noNeighboursIsAnOrdinaryAnswer() async throws {
        let (provider, _) = provider(
            metadata: artistRow,
            nearest: #"{"MediaContainer": {"size": 0}}"#
        )
        let info = try await provider.artistInfo(id: id("12"))
        #expect(info.similarArtists.isEmpty)
        #expect(info.biography != nil)
    }
}
