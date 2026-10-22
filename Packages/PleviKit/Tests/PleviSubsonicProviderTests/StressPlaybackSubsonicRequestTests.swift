import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviSubsonicProvider

/// What a Subsonic/Navidrome server is asked for when the player switches transcoding on and off,
/// changes bit rate, seeks a converted stream, or plays a song whose id has awkward characters in
/// it.
@Suite("Subsonic stream requests under stress")
struct StressPlaybackSubsonicRequestTests {
    private func makeProvider() -> SubsonicProvider {
        let config = ServerConfig(name: "Fake", addresses: .remote(URL(string: "https://fake.example")!))
        return SubsonicProvider(
            config: config,
            credentials: .usernamePassword(username: "demo", password: "sesame"),
            transport: FakeSubsonicServer()
        )
    }

    private func query(_ request: URLRequest) -> [String: String] {
        FakeSubsonicServer.parameters(of: request).compactMapValues(\.first)
    }

    @Test("The setting-to-request table: which combinations send format, maxBitRate, both or neither")
    func optionTable() async throws {
        let provider = makeProvider()
        _ = try await provider.testConnection()
        let id = MediaID(server: provider.serverID, rawValue: "t1")

        // (options, format, maxBitRate)
        let table: [(StreamOptions, String?, String?)] = [
            (.original, "raw", nil),
            (StreamOptions(transcodeTo: .opus), "opus", nil),
            (StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus), "opus", "128"),
            (StreamOptions(maxBitRateKbps: 320, transcodeTo: .mp3), "mp3", "320"),
            // A cap with no codec: no `format` at all, so the server picks the
            // codec from its own profile. The app never builds this (its
            // policy always pairs a cap with a codec), pinned so nobody does.
            (StreamOptions(maxBitRateKbps: 192), nil, "192"),
        ]
        for (options, format, rate) in table {
            let request = try await provider.streamRequest(for: id, options: options)
            let sent = query(request)
            #expect(sent["format"] == format, "options \(options): format \(String(describing: sent["format"]))")
            #expect(sent["maxBitRate"] == rate, "options \(options): maxBitRate \(String(describing: sent["maxBitRate"]))")
            #expect(sent["id"] == "t1")
            #expect(sent["timeOffset"] == nil && sent["estimateContentLength"] == nil)
        }
    }

    @Test("A start offset is sent only once the server has said it can honour one")
    func offsetIsCapabilityGated() async throws {
        let unprobed = makeProvider()
        let id = MediaID(server: unprobed.serverID, rawValue: "t1")
        let options = StreamOptions(maxBitRateKbps: 128, transcodeTo: .opus, startOffset: 61.9)
        let before = try await unprobed.streamRequest(for: id, options: options)
        #expect(query(before)["timeOffset"] == nil)

        let probed = makeProvider()
        _ = try await probed.testConnection()
        let after = try await probed.streamRequest(
            for: MediaID(server: probed.serverID, rawValue: "t1"), options: options
        )
        // Truncated, not rounded (Plex's provider rounds).
        #expect(query(after)["timeOffset"] == "61")

        let estimated = try await probed.streamRequest(
            for: MediaID(server: probed.serverID, rawValue: "t1"),
            options: StreamOptions(transcodeTo: .opus, estimateContentLength: true)
        )
        #expect(query(estimated)["estimateContentLength"] == "true")
    }

    @Test("Downloads: the original is byte-exact through `download`, anything converted goes through `stream`")
    func downloadVerbs() async throws {
        let provider = makeProvider()
        let id = MediaID(server: provider.serverID, rawValue: "t1")
        let original = try await provider.downloadRequest(for: id, options: .original)
        #expect(original.url?.path.hasSuffix("/rest/download") == true)
        let converted = try await provider.downloadRequest(
            for: id, options: StreamOptions(maxBitRateKbps: 160, transcodeTo: .opus)
        )
        #expect(converted.url?.path.hasSuffix("/rest/stream") == true)
        #expect(query(converted)["format"] == "opus" && query(converted)["maxBitRate"] == "160")
    }

    @Test("Ids with characters that mean something in a query survive the round trip")
    func awkwardIDs() async throws {
        let provider = makeProvider()
        let ids = [
            "a&b=c", "plus+sign", "space in it", "hash#tag", "slash/and?question", "100%25", "émile-ü",
            "日本語", "=", "&", "+", " ", "../../etc/passwd", "a\nb", "😀",
        ]
        for raw in ids {
            let request = try await provider.streamRequest(
                for: MediaID(server: provider.serverID, rawValue: raw), options: .original
            )
            #expect(query(request)["id"] == raw, "id \(raw.debugDescription) came back as \(String(describing: query(request)["id"]))")
        }
    }

    @Test("Another server's id is refused everywhere the id is used")
    func foreignIDsAreRefusedEverywhere() async throws {
        let provider = makeProvider()
        let foreign = MediaID(server: ServerID(), rawValue: "t1")
        await #expect(throws: ProviderError.notFound) {
            _ = try await provider.streamRequest(for: foreign, options: .original)
        }
        await #expect(throws: ProviderError.notFound) {
            _ = try await provider.downloadRequest(for: foreign, options: .original)
        }
        await #expect(throws: ProviderError.notFound) {
            try await provider.scrobble(id: foreign, at: Date(), submission: true)
        }
    }

    @Test("A scrobble carries the time in milliseconds and the submission flag as given")
    func scrobbleShape() async throws {
        let fake = FakeSubsonicServer()
        let config = ServerConfig(name: "Fake", addresses: .remote(URL(string: "https://fake.example")!))
        let provider = SubsonicProvider(
            config: config,
            credentials: .usernamePassword(username: "demo", password: "sesame"),
            transport: fake
        )
        let when = Date(timeIntervalSince1970: 1_700_000_000.123)
        for submission in [true, false] {
            try await provider.scrobble(id: MediaID(server: provider.serverID, rawValue: "t1"), at: when, submission: submission)
            let last = try #require(await fake.recordedRequests().last)
            let sent = query(last)
            #expect(sent["id"] == "t1")
            #expect(sent["time"] == "1700000000123")
            #expect(sent["submission"] == (submission ? "true" : "false"))
        }
    }
}
