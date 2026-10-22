import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// What the Plex provider sends when the player is stressed: an id that belongs to a different
/// server, an odd bit rate, hostile positions.
@Suite("Plex requests under stress")
struct StressPlaybackPlexRequestTests {
    private final class Recorder: HTTPTransport, @unchecked Sendable {
        var urls: [URL] = []

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if let url = request.url { urls.append(url) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            // Enough of a track for `streamRequest` to find its part.
            return (Data(Self.metadata.utf8), response)
        }

        func download(
            _ request: URLRequest,
            to destination: URL,
            onProgress: @Sendable (Int64, Int64?) -> Void
        ) async throws {}

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
                baseURL: URL(string: "http://plex.example:32400")!,
                token: "secret",
                sectionKey: "6",
                sectionTitle: "Music"
            ),
            identity: PlexIdentity(clientIdentifier: "client-1", deviceName: "Test iPhone"),
            transport: transport
        )
    }

    private func items(_ url: URL?) -> [String: String] {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary(
            (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: Another server's ids

    @Test("An id from another server is refused, as the Subsonic provider refuses it")
    func foreignIDsAreRefused() async throws {
        // P-07 / P-22: `MediaID` carries its server, and `PlexProvider` never
        // looks at it. Playing a queue that belongs to server A after the
        // active server became B asks B for A's rating keys.
        let foreign = MediaID(server: ServerID(), rawValue: "701")

        let streaming = Recorder()
        await withKnownIssue("P-22: PlexProvider.streamRequest accepts another server's MediaID") {
            await #expect(throws: ProviderError.notFound) {
                _ = try await provider(streaming).streamRequest(for: foreign, options: .original)
            }
        }

        let converting = Recorder()
        await withKnownIssue("P-22: PlexProvider.streamRequest (transcode) accepts another server's MediaID") {
            await #expect(throws: ProviderError.notFound) {
                _ = try await provider(converting).streamRequest(
                    for: foreign, options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus)
                )
            }
        }

        let reporting = Recorder()
        await withKnownIssue("P-22: PlexProvider.report sends another server's MediaID to the timeline") {
            _ = try? await provider(reporting).report(
                PlaybackReport(id: foreign, state: .playing, position: 5, duration: 200)
            )
            #expect(reporting.urls.isEmpty, "a timeline update for server A's item went to server B")
        }

        let scrobbling = Recorder()
        await withKnownIssue("P-22: PlexProvider.scrobble counts a play on another server's item") {
            _ = try? await provider(scrobbling).scrobble(id: foreign, at: Date(), submission: true)
            #expect(scrobbling.urls.isEmpty, "a play for server A's item was counted on server B")
        }
    }

    @Test("Its own ids are of course accepted")
    func ownIDsWork() async throws {
        let recorder = Recorder()
        let request = try await provider(recorder).streamRequest(
            for: MediaID(server: server, rawValue: "701"), options: .original
        )
        #expect(request.url?.path == "/library/parts/9/file.flac")
    }

    // MARK: Conversion requests

    @Test("A non-positive bit rate is left out of the conversion request rather than sent as 0")
    func nonPositiveBitRates() async throws {
        for rate in [0, -1, -128] {
            let recorder = Recorder()
            let request = try await provider(recorder).streamRequest(
                for: MediaID(server: server, rawValue: "701"),
                options: StreamOptions(maxBitRateKbps: rate, transcodeTo: .opus)
            )
            let query = items(request.url)
            #expect(query["musicBitrate"] == nil, "rate \(rate)")
            #expect(query["maxAudioBitrate"] == nil, "rate \(rate)")
            #expect(query["X-Plex-Client-Profile-Extra"]?.contains("add-limitation") == false, "rate \(rate)")
        }
        let recorder = Recorder()
        let request = try await provider(recorder).streamRequest(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus)
        )
        #expect(items(request.url)["musicBitrate"] == "128")
    }

    @Test("A stored AAC choice is delivered as Opus over an ogg container, never as a dead .m4a request")
    func aacIsClamped() async throws {
        let recorder = Recorder()
        let request = try await provider(recorder).streamRequest(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: 192, transcodeTo: .aac)
        )
        let url = try #require(request.url)
        #expect(url.path.hasSuffix("/start.ogg"), "\(url.path)")
        #expect(items(url)["X-Plex-Client-Profile-Extra"]?.contains("audioCodec=opus") == true)
    }

    @Test("A start offset is rounded to whole seconds and defaults to zero")
    func offsets() async throws {
        let recorder = Recorder()
        let plex = provider(recorder)
        let id = MediaID(server: server, rawValue: "701")
        let none = try await plex.streamRequest(for: id, options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus))
        #expect(items(none.url)["offset"] == "0")
        let some = try await plex.streamRequest(
            for: id, options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus, startOffset: 61.6)
        )
        #expect(items(some.url)["offset"] == "62")
    }

    // MARK: Timeline

    @Test("Positions that are not sensible seconds become zero milliseconds, not a crash or a negative")
    func hostilePositions() async throws {
        for (position, expected) in [
            (Double.nan, "0"), (-5, "0"), (0, "0"), (Double.infinity, "0"), (-Double.infinity, "0"),
            (12.3456, "12345"), (3600, "3600000"), (1e12, "1000000000000000"),
        ] {
            let recorder = Recorder()
            try await provider(recorder).report(
                PlaybackReport(id: MediaID(server: server, rawValue: "701"), state: .playing, position: position, duration: position)
            )
            let query = items(recorder.urls.first)
            #expect(query["time"] == expected, "position \(position)")
            #expect(query["duration"] == expected, "duration \(position)")
        }
    }

    @Test("Stopping a conversion uses the same session name the conversion was started under")
    func stopMatchesStart() async throws {
        let recorder = Recorder()
        let plex = provider(recorder)
        let id = MediaID(server: server, rawValue: "701")
        let request = try await plex.streamRequest(
            for: id, options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus)
        )
        await plex.endPlayback(for: id)
        let started = items(request.url)["session"]
        let stopped = recorder.urls.last.flatMap { items($0)["session"] }
        #expect(started != nil)
        #expect(started == stopped, "started \(String(describing: started)), stopped \(String(describing: stopped))")
        #expect(recorder.urls.last?.path == "/video/:/transcode/universal/stop")
    }
}
