import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// How many times Plex is asked about a song in order to download it.
@Suite("Asking Plex how to download a song")
struct PlexDownloadSourceTests {
    private final class Counter: HTTPTransport, @unchecked Sendable {
        var requestCount = 0
        var paths: [String] = []

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requestCount += 1
            paths.append(request.url?.path ?? "")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(Self.metadata.utf8), response)
        }

        func download(
            _ request: URLRequest,
            to destination: URL,
            onProgress: @Sendable (Int64, Int64?) -> Void
        ) async throws {
            throw ProviderError.notFound
        }

        /// One track with one part, which is all `mediaRequest` reads.
        static let metadata = """
        {"MediaContainer": {"size": 1, "Metadata": [
          {"ratingKey": "701", "type": "track", "title": "Song One",
           "Media": [{"id": 1, "Part": [{"id": 9, "key": "/library/parts/9/file.flac",
             "container": "flac"}]}]}
        ]}}
        """
    }

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

    @Test("Preparing a plain download asks once, where it used to ask twice")
    func plainDownloadAsksOnce() async throws {
        let transport = Counter()
        let plex = provider(transport)
        let id = MediaID(server: server, rawValue: "701")

        _ = try await plex.downloadSource(for: id, options: StreamOptions())

        #expect(transport.requestCount == 1, "asked \(transport.requestCount) times: \(transport.paths)")
    }

    @Test("The old pair of calls really did ask twice")
    func theOldWayAskedTwice() async throws {
        // Kept as the measurement the change is judged against: without it,
        // "asks once" is a number with nothing to compare to.
        let transport = Counter()
        let plex = provider(transport)
        let id = MediaID(server: server, rawValue: "701")

        _ = try await plex.streamSource(for: id, options: StreamOptions())
        _ = try await plex.downloadRequest(for: id, options: StreamOptions())

        #expect(transport.requestCount == 2)
        #expect(transport.paths.allSatisfy { $0.contains("/library/metadata/701") })
    }

    @Test("A conversion asks the server nothing before asking for the audio")
    func aConversionCostsOneRequest() async throws {
        // The read-ahead multiplies whatever one song costs.
        let transport = Counter()
        let plex = provider(transport)
        _ = try await plex.streamSource(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus)
        )
        #expect(transport.requestCount == 0, "asked \(transport.requestCount) times")
    }

    @Test("Playing the file as it is still needs to be told where it lives")
    func directPlayStillAsks() async throws {
        // The metadata is not waste here: the part's own key is the one
        // thing only the server knows.
        let transport = Counter()
        let plex = provider(transport)
        _ = try await plex.streamSource(
            for: MediaID(server: server, rawValue: "701"), options: StreamOptions()
        )
        #expect(transport.requestCount == 1)
    }

    @Test("Every conversion is one file now, whatever the codec", arguments: TranscodeCodec.allCases)
    func everyCodecIsAFile(codec: TranscodeCodec) async throws {
        // This test used to assert the opposite for AAC: that it came back
        // as a playlist and cost no request, because the playlist URL was
        // built without asking. That was the segmented path, and it is gone
        // — Plex gives Opus over ordinary HTTP once the profile directive is
        // marked `replace=true`, and one file is a file the system can carry
        // in the background.
        let transport = Counter()
        let plex = provider(transport)
        let id = MediaID(server: server, rawValue: "701")

        let source = try await plex.downloadSource(
            for: id, options: StreamOptions(transcodeTo: codec)
        )

        #expect(source.kind == StreamSource.Kind.file)
        #expect(source.request.url?.absoluteString.contains("start.m3u8") == false)
    }
}
