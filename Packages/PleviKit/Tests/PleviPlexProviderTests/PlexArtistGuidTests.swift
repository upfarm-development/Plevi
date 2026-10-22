import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// The bulk artist listing is the one call that needs `includeGuids=1` —
/// it's the only place a matched artist's MusicBrainz id can be read from,
/// and asking for it on every other call would be pointless cost.
@Suite("Plex artist listing asks for Guids")
struct PlexArtistGuidTests {
    private final class Router: HTTPTransport, @unchecked Sendable {
        private(set) var lastRequest: URLRequest?

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            let json = """
            {"MediaContainer": {"size": 1, "Metadata": [
              {"ratingKey": "12", "type": "artist", "title": "Television",
               "Guid": [{"id": "mbid://70248960-cb53-4ea4-943a-edb18f9c0ce9"}]}
            ]}}
            """
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

    @Test func artistsAsksForIncludeGuids() async throws {
        let server = ServerID()
        let transport = Router()
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

        let artists = try await provider.artists()

        let requestURL = try #require(transport.lastRequest?.url)
        let query = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "includeGuids", value: "1")))
        #expect(artists.first?.musicBrainzID == "70248960-cb53-4ea4-943a-edb18f9c0ce9")
    }
}
