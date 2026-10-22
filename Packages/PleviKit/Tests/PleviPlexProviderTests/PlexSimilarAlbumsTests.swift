import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// Sonically similar albums: what is asked of the server, and what is made of
/// the answer.
@Suite("Plex similar albums")
struct PlexSimilarAlbumsTests {
    /// Hands back one canned payload and keeps the request, so the URL the
    /// provider builds can be inspected.
    private final class Recorder: HTTPTransport, @unchecked Sendable {
        let json: String
        var lastRequest: URLRequest?

        init(json: String) { self.json = json }

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
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

    private func provider(json: String) -> (PlexProvider, Recorder) {
        let transport = Recorder(json: json)
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

    /// A trimmed `/nearest` payload: two albums, the seed itself, and a track
    /// row that has no business on an album shelf.
    private let payload = """
    {"MediaContainer": {"size": 4, "Metadata": [
      {"ratingKey": "501", "type": "album", "title": "Blue Lines",
       "parentTitle": "Massive Attack", "parentRatingKey": "12", "year": 1991,
       "thumb": "/library/metadata/501/thumb/1", "leafCount": 9},
      {"ratingKey": "182285", "type": "album", "title": "The Seed",
       "parentTitle": "Coldplay", "parentRatingKey": "13", "year": 2008},
      {"ratingKey": "502", "type": "track", "title": "Not An Album"},
      {"ratingKey": "503", "type": "album", "title": "Dummy",
       "parentTitle": "Portishead", "parentRatingKey": "14", "year": 1994}
    ]}}
    """

    @Test("Asks the seed's own nearest endpoint, with the limit")
    func requestShape() async throws {
        let (provider, transport) = self.provider(json: payload)
        _ = try await provider.similarAlbums(to: id("182285"), limit: 30)
        let url = try #require(transport.lastRequest?.url)
        #expect(url.path() == "/library/metadata/182285/nearest")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "limit", value: "30")))
    }

    @Test("Keeps the albums in the order given, without the seed or the tracks")
    func mapping() async throws {
        let (provider, _) = provider(json: payload)
        let albums = try await provider.similarAlbums(to: id("182285"), limit: 30)
        #expect(albums.map(\.name) == ["Blue Lines", "Dummy"])
        #expect(albums.first?.artistName == "Massive Attack")
        #expect(albums.first?.year == 1991)
    }

    @Test("A server with nothing to say leaves an empty shelf, not an error")
    func emptyIsFine() async throws {
        let (provider, _) = provider(json: #"{"MediaContainer": {"size": 0}}"#)
        #expect(try await provider.similarAlbums(to: id("1"), limit: 5).isEmpty)
    }
}
