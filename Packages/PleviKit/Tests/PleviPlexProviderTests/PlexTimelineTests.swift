import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// What Plex is told about a song while it is playing.
@Suite("Telling Plex what is playing")
struct PlexTimelineTests {
    private final class Recorder: HTTPTransport, @unchecked Sendable {
        var urls: [URL] = []

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if let url = request.url { urls.append(url) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            // Nothing, which is what Plex answers a timeline with.
            return (Data(), response)
        }

        func download(
            _ request: URLRequest,
            to destination: URL,
            onProgress: @Sendable (Int64, Int64?) -> Void
        ) async throws {}
    }

    private let server = ServerID()

    private func provider(_ transport: any HTTPTransport, device: String = "iPhone") -> PlexProvider {
        PlexProvider(
            serverID: server,
            config: PlexServerConfig(
                baseURL: URL(string: "http://plex.example:32400")!,
                token: "secret",
                sectionKey: "6",
                sectionTitle: "Music"
            ),
            identity: PlexIdentity(clientIdentifier: "client-1", platform: "iOS", device: device),
            transport: transport
        )
    }

    private func items(_ url: URL) -> [String: String] {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(
            (parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @Test("A playing song goes to the timeline, in milliseconds")
    func playingIsReported() async throws {
        let recorder = Recorder()
        try await provider(recorder).report(
            PlaybackReport(
                id: MediaID(server: server, rawValue: "701"),
                state: .playing,
                position: 12.5,
                duration: 200
            )
        )
        let url = try #require(recorder.urls.first)
        #expect(url.path == "/:/timeline")
        let query = items(url)
        #expect(query["ratingKey"] == "701")
        #expect(query["key"] == "/library/metadata/701")
        #expect(query["identifier"] == "com.plexapp.plugins.library")
        #expect(query["state"] == "playing")
        // Plex counts in milliseconds, not seconds.
        #expect(query["time"] == "12500")
        #expect(query["duration"] == "200000")
    }

    @Test("Pausing and stopping say so")
    func statesAreNamed() async throws {
        for state in [PlaybackReport.State.paused, .stopped] {
            let recorder = Recorder()
            try await provider(recorder).report(
                PlaybackReport(
                    id: MediaID(server: server, rawValue: "701"), state: state, position: 1
                )
            )
            let url = try #require(recorder.urls.first)
            #expect(items(url)["state"] == state.rawValue)
        }
    }

    /// A length is not known the instant a stream opens, and a report is
    /// worth sending before it is.
    @Test("An unknown length is left out rather than sent as nothing")
    func unknownDurationIsOmitted() async throws {
        let recorder = Recorder()
        try await provider(recorder).report(
            PlaybackReport(
                id: MediaID(server: server, rawValue: "701"), state: .playing, position: 3
            )
        )
        let url = try #require(recorder.urls.first)
        #expect(items(url)["duration"] == nil)
    }

    /// Negative or non-finite positions come out of a player that has not
    /// settled yet; Plex will not have them.
    @Test("A position before the beginning is reported as the beginning")
    func oddPositionsAreClamped() async throws {
        let recorder = Recorder()
        try await provider(recorder).report(
            PlaybackReport(
                id: MediaID(server: server, rawValue: "701"), state: .playing, position: -4
            )
        )
        let url = try #require(recorder.urls.first)
        #expect(items(url)["time"] == "0")
    }

    /// The phone and the watch present the same Plex client identifier — the
    /// watch has to, to use the phone's token — so without this they would
    /// be one session on the dashboard rather than two devices.
    @Test("The watch and the phone are told apart")
    func devicesAreDistinct() async throws {
        let phone = Recorder()
        let watch = Recorder()
        let report = PlaybackReport(
            id: MediaID(server: server, rawValue: "701"), state: .playing, position: 1
        )
        try await provider(phone, device: "iPhone").report(report)
        try await provider(watch, device: "Apple Watch").report(report)

        let phoneSession = items(try #require(phone.urls.first))["X-Plex-Session-Identifier"]
        let watchSession = items(try #require(watch.urls.first))["X-Plex-Session-Identifier"]
        #expect(phoneSession != watchSession)
    }
}
