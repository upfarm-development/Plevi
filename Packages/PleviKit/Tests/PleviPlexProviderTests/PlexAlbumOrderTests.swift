import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// What order a record's songs come back in.
@Suite("Plex album track order")
struct PlexAlbumOrderTests {
    /// Answers by path, because `album(id:)` asks two questions at once — the
    /// record itself, and its songs.
    private final class ByPath: HTTPTransport, @unchecked Sendable {
        let album: String
        let children: String

        init(album: String, children: String) {
            self.album = album
            self.children = children
        }

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path
            let body = path.hasSuffix("/children") ? children : album
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

    private func provider(album: String, children: String) -> PlexProvider {
        PlexProvider(
            serverID: server,
            config: PlexServerConfig(
                baseURL: URL(string: "https://plex.example")!,
                token: "secret",
                sectionKey: "6",
                sectionTitle: "Music"
            ),
            identity: PlexIdentity(clientIdentifier: "client-1", deviceName: "Test iPhone"),
            transport: ByPath(album: album, children: children)
        )
    }

    private let albumPayload = """
    {"MediaContainer": {"size": 1, "Metadata": [
      {"ratingKey": "501", "type": "album", "title": "London Calling",
       "parentRatingKey": "12", "parentTitle": "The Clash"}
    ]}}
    """

    /// Two discs, handed over shuffled and interleaved — disc two's closer
    /// first, disc one's songs split around it. `index` is the track number;
    /// `parentIndex` is the disc, which is where Plex puts it on a track row.
    private let shuffledChildren = """
    {"MediaContainer": {"size": 5, "Metadata": [
      {"ratingKey": "704", "type": "track", "title": "Two-Two",
       "parentRatingKey": "501", "grandparentRatingKey": "12",
       "index": 2, "parentIndex": 2},
      {"ratingKey": "702", "type": "track", "title": "One-Two",
       "parentRatingKey": "501", "grandparentRatingKey": "12",
       "index": 2, "parentIndex": 1},
      {"ratingKey": "703", "type": "track", "title": "Two-One",
       "parentRatingKey": "501", "grandparentRatingKey": "12",
       "index": 1, "parentIndex": 2},
      {"ratingKey": "701", "type": "track", "title": "One-One",
       "parentRatingKey": "501", "grandparentRatingKey": "12",
       "index": 1, "parentIndex": 1},
      {"ratingKey": "705", "type": "track", "title": "One-Three",
       "parentRatingKey": "501", "grandparentRatingKey": "12",
       "index": 3, "parentIndex": 1}
    ]}}
    """

    @Test("A record whose songs arrive shuffled is put back in disc-then-track order")
    func sortsAcrossDiscs() async throws {
        let detail = try await provider(album: albumPayload, children: shuffledChildren)
            .album(id: MediaID(server: server, rawValue: "501"))

        #expect(detail.tracks.map(\.title) == [
            "One-One", "One-Two", "One-Three", "Two-One", "Two-Two",
        ])
        #expect(detail.tracks.map { $0.discNumber ?? 1 } == [1, 1, 1, 2, 2])
    }

    /// A record whose files never had the disc field filled in, which is most
    /// of them. Untagged has to sort as disc one rather than as nothing, or a
    /// single-disc record whose rows disagree about the field comes apart.
    private let untaggedChildren = """
    {"MediaContainer": {"size": 3, "Metadata": [
      {"ratingKey": "703", "type": "track", "title": "Third",
       "parentRatingKey": "501", "grandparentRatingKey": "12", "index": 3},
      {"ratingKey": "701", "type": "track", "title": "First",
       "parentRatingKey": "501", "grandparentRatingKey": "12", "index": 1},
      {"ratingKey": "702", "type": "track", "title": "Second",
       "parentRatingKey": "501", "grandparentRatingKey": "12",
       "index": 2, "parentIndex": 1}
    ]}}
    """

    @Test("An untagged disc sorts as disc one, beside a row that says so outright")
    func untaggedDiscIsDiscOne() async throws {
        let detail = try await provider(album: albumPayload, children: untaggedChildren)
            .album(id: MediaID(server: server, rawValue: "501"))

        #expect(detail.tracks.map(\.title) == ["First", "Second", "Third"])
    }
}
