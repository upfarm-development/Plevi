import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// What reaches the server when somebody types a character the query string
/// spells differently than they do.
@Suite("Plex query encoding")
struct PlexQueryEncodingTests {
    /// Records the request and answers with nothing, which is enough: every
    /// call here is made for its URL, not for what comes back.
    private final class Recorder: HTTPTransport, @unchecked Sendable {
        var lastRequest: URLRequest?

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
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

    @Test("A plus in a name is a plus, not a space")
    func plusSurvivesInAPlaylistName() async throws {
        let transport = Recorder()
        let provider = provider(transport: transport)
        // Throws: the recorder answers with no body, so nothing is created.
        // The request was still made, and the request is the whole question.
        _ = try? await provider.createPlaylist(
            name: "Leif Vollebekk 3+",
            trackIDs: [MediaID(server: server, rawValue: "1")]
        )

        let url = try #require(transport.lastRequest?.url)
        let sent = url.absoluteString
        // A plus is legal in a query string, so Foundation used to hand it over as written — and
        // Plex reads a query as form data, where a plus is a space.
        #expect(sent.contains("%2B"))
        #expect(!sent.contains("3+"))

        // And it is still the name on the other side of the encoding.
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "title", value: "Leif Vollebekk 3+")))
    }

    @Test("Everything else in a query is left as it was")
    func ordinaryValuesAreUnharmed() async throws {
        let transport = Recorder()
        let provider = provider(transport: transport)
        _ = try? await provider.createPlaylist(
            name: "Jazz & Blues 100%",
            trackIDs: [MediaID(server: server, rawValue: "1")]
        )

        let url = try #require(transport.lastRequest?.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "title", value: "Jazz & Blues 100%")))
        #expect(query.contains(URLQueryItem(name: "type", value: "audio")))
        #expect(query.contains(URLQueryItem(name: "smart", value: "0")))
    }
}
