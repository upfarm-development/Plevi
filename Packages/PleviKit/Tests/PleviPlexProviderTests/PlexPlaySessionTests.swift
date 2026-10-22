import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// Which name a song's conversion runs under while it plays.
@Suite("The name a playing song is converted under")
struct PlexPlaySessionTests {
    private final class Stub: HTTPTransport, @unchecked Sendable {
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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

        static let metadata = """
        {"MediaContainer": {"size": 1, "Metadata": [
          {"ratingKey": "701", "type": "track", "title": "Song One",
           "Media": [{"id": 1, "Part": [{"id": 9, "key": "/library/parts/9/file.flac",
             "container": "flac"}]}]}
        ]}}
        """
    }

    private let server = ServerID()

    /// Keeps every URL asked for, so a call that answers nothing — stopping
    /// a conversion — can still be checked.
    private final class Recorder: HTTPTransport, @unchecked Sendable {
        var urls: [URL] = []

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            urls.append(request.url!)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(Stub.metadata.utf8), response)
        }

        func download(
            _ request: URLRequest,
            to destination: URL,
            onProgress: @Sendable (Int64, Int64?) -> Void
        ) async throws {
            throw ProviderError.notFound
        }
    }

    private func provider(_ transport: any HTTPTransport = Stub()) -> PlexProvider {
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

    private func query(_ url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    @Test("Two songs playing back to back convert under two different names")
    func readingAheadDoesNotTearDownWhatIsPlaying() async throws {
        let plex = provider()
        let options = StreamOptions(maxBitRateKbps: 256, transcodeTo: .mp3)
        let playing = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "701"), options: options
        )
        let readAhead = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "702"), options: options
        )
        let first = query(playing.url)["session"]
        let second = query(readAhead.url)["session"]
        #expect(first != nil)
        #expect(first != second)
    }

    @Test("Both of them still belong to this device's one playback session")
    func theyReportUnderOnePlaybackSession() async throws {
        let plex = provider()
        let options = StreamOptions(maxBitRateKbps: 256, transcodeTo: .mp3)
        let playing = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "701"), options: options
        )
        let readAhead = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "702"), options: options
        )
        // The conversions are the songs'; the playback session is the
        // device's, and it is what the timeline reports under. Splitting that
        // too would show a fresh session on the dashboard for every song.
        let first = query(playing.url)["X-Plex-Session-Identifier"]
        #expect(first == query(readAhead.url)["X-Plex-Session-Identifier"])
        // Named for the device, and for nothing else: no song's id in it.
        #expect(first?.contains("client-1") == true)
        #expect(first?.contains("701") == false)
    }

    @Test("The session a song played through is the one that gets stopped")
    func endingPlaybackNamesTheSongsOwnSession() async throws {
        // Per-song names only pay for themselves if somebody ends them.
        let recorder = Recorder()
        let plex = provider(recorder)
        let id = MediaID(server: server, rawValue: "701")
        let playing = try await plex.streamRequest(
            for: id, options: StreamOptions(maxBitRateKbps: 256, transcodeTo: .mp3)
        )
        await plex.endPlayback(for: id)
        let stop = recorder.urls.first { $0.path.hasSuffix("/transcode/universal/stop") }
        #expect(stop != nil)
        #expect(query(stop)["session"] == query(playing.url)["session"])
    }

    @Test("Ending a play does not end the download of the same song")
    func endingPlaybackLeavesTheDownloadAlone() async throws {
        let recorder = Recorder()
        let plex = provider(recorder)
        let id = MediaID(server: server, rawValue: "701")
        let download = try await plex.downloadRequest(
            for: id, options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .mp3)
        )
        await plex.endPlayback(for: id)
        let stop = recorder.urls.first { $0.path.hasSuffix("/transcode/universal/stop") }
        #expect(query(stop)["session"] != query(download.url)["session"])
    }

    @Test("The chosen bitrate is asked for, not merely capped")
    func theBitrateIsATargetNotACeiling() async throws {
        // `maxAudioBitrate` alone is a ceiling, and Plex under a ceiling
        // picks its own figure: 320 was asked for and 210 arrived.
        let plex = provider()
        let request = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: 320, transcodeTo: .mp3)
        )
        let sent = query(request.url)
        #expect(sent["musicBitrate"] == "320")
        #expect(sent["maxAudioBitrate"] == "320")
    }

    @Test("Nothing is asked for when nothing was chosen")
    func noBitrateMeansNoParameters() async throws {
        let plex = provider()
        let request = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: nil, transcodeTo: .mp3)
        )
        #expect(query(request.url)["musicBitrate"] == nil)
    }

    @Test("A conversion is one progressive stream, never a playlist",
          arguments: TranscodeCodec.allCases)
    func everyConversionIsProgressive(codec: TranscodeCodec) async throws {
        let plex = provider()
        let source = try await plex.streamSource(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: 128, transcodeTo: codec)
        )
        #expect(source.kind == StreamSource.Kind.file)
        let sent = query(source.request.url)
        #expect(sent["protocol"] == "http")
        #expect(sent["directPlay"] == "0")
        #expect(sent["directStream"] == "0")
        #expect(source.request.url?.absoluteString.contains("start.m3u8") == false)
    }

    @Test("The profile directive says replace, or Plex quietly keeps its own")
    func theDirectiveReplaces() async throws {
        // Without this word the iOS profile's MP3 target wins and the ask is
        // dropped in silence — which is the whole of what looked for years
        // like "Plex will not give better than MP3 over HTTP".
        let plex = provider()
        let request = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus)
        )
        let profile = query(request.url)["X-Plex-Client-Profile-Extra"] ?? ""
        #expect(profile.contains("replace=true"))
        #expect(profile.contains("container=ogg"))
        #expect(profile.contains("audioCodec=opus"))
        // The bit rate said a third way, scoped to the codec asked for.
        #expect(profile.contains("add-limitation"))
        #expect(profile.contains("scopeName=opus"))
        #expect(profile.contains("value=128"))
        // The undocumented verb goes: it never appeared in Plex's own docs
        // and did nothing the target above does not.
        #expect(!profile.contains("add-transcode-target-audio-codec"))
    }

    @Test("Opus is asked for by its container, because that is what a reader reads")
    func opusIsAskedForAsOgg() async throws {
        let plex = provider()
        let request = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus)
        )
        #expect(request.url?.path.hasSuffix("/start.ogg") == true)
    }

    @Test("A seek past what has arrived can start the conversion further in")
    func theConversionCanStartLater() async throws {
        let plex = provider()
        let request = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(
                maxBitRateKbps: 128, transcodeTo: .opus, startOffset: 480
            )
        )
        #expect(query(request.url)["offset"] == "480")
    }

    @Test("Plex offers Opus and MP3, and no longer claims AAC")
    func theCodecsOffered() {
        // AAC over plain HTTP answers with nothing at all on a real server: the decision endpoint
        // says it would send it and `start.m4a` delivers zero bytes.
        #expect(provider().supportedTranscodeCodecs == [.opus, .mp3])
    }

    @Test("A setting that outlived its codec still plays something")
    func aStoredAACChoiceStillWorks() async throws {
        // Everyone who had chosen AAC still has "aac" in their preferences,
        // and AAC over this path sends nothing at all. Left alone, the first
        // lossless track after updating would fetch zero bytes.
        let plex = provider()
        let request = try await plex.streamRequest(
            for: MediaID(server: server, rawValue: "701"),
            options: StreamOptions(maxBitRateKbps: 256, transcodeTo: .aac)
        )
        let profile = query(request.url)["X-Plex-Client-Profile-Extra"] ?? ""
        #expect(profile.contains("audioCodec=opus"))
        #expect(!profile.contains("audioCodec=aac"))
        #expect(request.url?.path.hasSuffix("/start.ogg") == true)
    }

    @Test("A download is nobody's playback session")
    func downloadsStayOutOfIt() async throws {
        let plex = provider()
        let id = MediaID(server: server, rawValue: "701")
        let options = StreamOptions(maxBitRateKbps: 128, transcodeTo: .mp3)
        let download = try await plex.downloadRequest(for: id, options: options)
        let playing = try await plex.streamRequest(for: id, options: options)
        // The same song, playing and being kept at once: two conversions, and
        // neither may be allowed to end the other.
        #expect(query(download.url)["session"] != query(playing.url)["session"])
        #expect(
            query(download.url)["X-Plex-Session-Identifier"]
                != query(playing.url)["X-Plex-Session-Identifier"]
        )
    }
}
