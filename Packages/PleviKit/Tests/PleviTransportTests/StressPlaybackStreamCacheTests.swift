import Foundation
import Synchronization
import Testing
import PleviDomain
@testable import PleviTransport

/// P-08 (playback-34) and playback-16: what the play cache's transport makes
/// of a 200 that is not a song, and in what steps a body of unknown length
/// reports its progress.
@Suite("Stress: the play cache's download boundary", .serialized)
struct StressPlaybackStreamCacheTests {
    private func rig() async throws -> (StressLoopbackServer, ServerHTTPTransport, URL) {
        let server = try StressLoopbackServer()
        try await server.start()
        let config = ServerConfig(name: "Home", addresses: .local(server.base))
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "stream-cache-\(UUID().uuidString).partial")
        return (server, ServerHTTPTransport(config: config), destination)
    }

    private func fetch(_ transport: ServerHTTPTransport, _ server: StressLoopbackServer, _ path: String, to destination: URL) async -> (any Error)? {
        do {
            try await transport.download(URLRequest(url: server.base.appending(path: path)), to: destination)
            return nil
        } catch {
            return error
        }
    }

    // MARK: P-08

    @Test("P-08: a Navidrome error envelope sent as a 200 is refused and not left on disk")
    func jsonEnvelopeIsRefused() async throws {
        let (server, transport, destination) = try await rig()
        defer { server.stop(); try? FileManager.default.removeItem(at: destination) }
        server.route("/gone", .full(
            status: 200, contentType: "application/json",
            body: Data(#"{"subsonic-response":{"status":"failed","error":{"code":70}}}"#.utf8)
        ))
        let error = await fetch(transport, server, "gone", to: destination)
        guard case ProviderError.malformedResponse? = error else {
            Issue.record("expected a refusal, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("P-08: a login page sent as a 200 is the sign-in wall")
    func htmlIsTheWall() async throws {
        let (server, transport, destination) = try await rig()
        defer { server.stop(); try? FileManager.default.removeItem(at: destination) }
        server.route("/login", .full(status: 200, contentType: "text/html; charset=utf-8", body: Data("<html>Sign in</html>".utf8)))
        let error = await fetch(transport, server, "login", to: destination)
        guard case ProviderError.proxySignInRequired? = error else {
            Issue.record("expected proxySignInRequired, got \(String(describing: error))")
            return
        }
    }

    @Test("P-08: an envelope labelled as a binary download is caught by its first bytes")
    func mislabelledEnvelope() async throws {
        let (server, transport, destination) = try await rig()
        defer { server.stop(); try? FileManager.default.removeItem(at: destination) }
        server.route("/odd", .full(
            status: 200, contentType: "application/octet-stream",
            body: Data(#"{"subsonic-response":{"status":"failed"}}"#.utf8)
        ))
        let error = await fetch(transport, server, "odd", to: destination)
        #expect(error != nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path), "nothing is left to be filed as the song")
    }

    @Test("P-08: an empty 200 is refused")
    func emptyBody() async throws {
        let (server, transport, destination) = try await rig()
        defer { server.stop(); try? FileManager.default.removeItem(at: destination) }
        server.route("/nothing", .full(status: 200, contentType: "audio/mpeg", body: Data()))
        #expect(await fetch(transport, server, "nothing", to: destination) != nil)
    }

    @Test("P-08: real audio passes, and so does an undecodable file labelled as audio")
    func leniencyForAudio() async throws {
        let (server, transport, destination) = try await rig()
        defer { server.stop(); try? FileManager.default.removeItem(at: destination) }
        let mp3 = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]) + Data(repeating: 0x11, count: 4_000)
        server.route("/song", .full(status: 200, contentType: "audio/mpeg", body: mp3))
        #expect(await fetch(transport, server, "song", to: destination) == nil)
        #expect(try Data(contentsOf: destination) == mp3)

        // Bytes no decoder will open, but which are not a web page or an
        // envelope: the player has its own message for those, and a refusal
        // here would only replace it.
        let odd = Data((0..<90_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }) // starts 0x00
        server.route("/odd", .full(status: 200, contentType: "application/octet-stream", body: odd))
        #expect(await fetch(transport, server, "odd", to: destination) == nil)
        server.route("/unlabelled", .closeDelimited(contentType: "audio/ogg", body: odd))
        #expect(await fetch(transport, server, "unlabelled", to: destination) == nil)
    }

    // MARK: playback-16

    @Test("playback-16: a body with no length reports progress in small steps")
    func unknownLengthReportsSmallSteps() async throws {
        let (server, transport, destination) = try await rig()
        defer { server.stop(); try? FileManager.default.removeItem(at: destination) }
        let body = Data([0x49, 0x44, 0x33, 0x04]) + Data(repeating: 0x22, count: 200_000)
        server.route("/convert", .closeDelimited(contentType: "audio/mpeg", body: body))
        let reports = Mutex<[Int64]>([])
        try await transport.download(URLRequest(url: server.base.appending(path: "convert")), to: destination) { written, total in
            reports.withLock { $0.append(written) }
            #expect(total == nil)
        }
        let seen = reports.withLock { $0 }
        #expect(seen.first == Int64(32 * 1024), "first report after 32 KB, not a quarter of a megabyte: \(seen.prefix(3))")
        #expect(seen.last == Int64(body.count))
    }

    @Test("a body with a length still reports in large steps")
    func knownLengthKeepsLargeSteps() async throws {
        let (server, transport, destination) = try await rig()
        defer { server.stop(); try? FileManager.default.removeItem(at: destination) }
        let body = Data([0x49, 0x44, 0x33, 0x04]) + Data(repeating: 0x22, count: 600_000)
        server.route("/original", .full(status: 200, contentType: "audio/mpeg", body: body))
        let reports = Mutex<[Int64]>([])
        try await transport.download(URLRequest(url: server.base.appending(path: "original")), to: destination) { written, _ in
            reports.withLock { $0.append(written) }
        }
        #expect(reports.withLock { $0 }.first == Int64(256 * 1024))
    }

    // MARK: The rule the store applies to a finished file

    @Test("A file no decoder opens is refused only when it is smaller than any song")
    func smallAndUnopenable() {
        let junk = Data(repeating: 0x00, count: 100)
        let small = AudioResponseCheck.verdictForCachedStream(size: 1_000, head: junk, canOpen: false)
        #expect(small == .tooSmall(bytes: 1_000))
        #expect(small?.looksLikeAWebPage == false)
        #expect(AudioResponseCheck.verdictForCachedStream(size: 1_000, head: junk, canOpen: true) == nil)
        #expect(AudioResponseCheck.verdictForCachedStream(size: 5_000_000, head: junk, canOpen: false) == nil,
                "an undecodable format is left for the player's own message")
    }

    @Test("Markup and an empty file are refused whether or not they can be opened")
    func definiteNonAudio() {
        let page = Data("<html>".utf8)
        #expect(AudioResponseCheck.verdictForCachedStream(size: 6, head: page, canOpen: false) == .markup)
        #expect(AudioResponseCheck.verdictForCachedStream(size: 6, head: page, canOpen: true) == .markup)
        #expect(AudioResponseCheck.verdictForCachedStream(size: 0, head: Data(), canOpen: false) == .empty)
    }

    @Test("Files on disk are sized and sniffed fresh")
    func fileHelpers() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sniff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"error\":1}".utf8).write(to: url)
        #expect(AudioResponseCheck.size(ofFileAt: url) == 11)
        #expect(AudioResponseCheck.startsLikeMarkup(AudioResponseCheck.head(ofFileAt: url)))
        #expect(AudioResponseCheck.head(ofFileAt: url.appending(path: "missing")).isEmpty)
    }
}
