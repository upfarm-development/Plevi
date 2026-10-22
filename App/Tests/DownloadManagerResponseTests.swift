import Foundation
import Testing
import PleviAudio
import PleviDomain
import PleviTransport
import PleviLibraryIndex
@testable import Plevi

/// What the queue does with a response that is not a song, and with a server
/// behind a sign-in proxy (D-03, D-08, D-09).
@MainActor
@Suite("Stress: bad responses and the sign-in proxy", .serialized)
struct DownloadManagerResponseTests {

    private func reason(_ track: Track) -> DownloadReason { .track(track.id) }

    private func failed(_ rig: DownloadRig, _ track: Track) -> Bool {
        if case .failed = rig.manager.state(for: track.id) { return true }
        return false
    }

    // MARK: D-09

    @Test("D-09: every transfer leaves with the proxy's cookie, first time and on a rescue")
    func cookieIsStamped() async throws {
        let rig = try await DownloadRig(proxySessions: FixedProxySession(cookie: "abc"))
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        #expect(rig.downloader.handed.last?.request.value(forHTTPHeaderField: "Cookie") == "session=abc")

        // A rescue re-requests through the same door.
        rig.downloader.lose(track.id.rawValue)
        await rig.manager.sweepStuck()
        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 2 })
        #expect(rig.downloader.handed.last?.request.value(forHTTPHeaderField: "Cookie") == "session=abc")
    }

    @Test("D-09: with no proxy session nothing is added")
    func noCookieWithoutASession() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        #expect(rig.downloader.handed.last?.request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("D-09: a sign-in page stops the queue, asks once, and fails no song")
    func wallStopsTheQueue() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        var asked: [URL?] = []
        rig.manager.onProxyWall = { asked.append($0) }
        let batch = Array(rig.tracks.prefix(3))
        await rig.manager.start()
        await rig.manager.download(batch, reason: .playlist(MediaID(server: rig.server, rawValue: "pl")))
        let login = URL(string: "https://idp.example/login")!

        for track in batch.prefix(2) {
            rig.downloader.emit(track.id.rawValue, .failed(.foreignHost(login)))
        }
        #expect(await rig.waitUntil { !asked.isEmpty })
        // Let the second song's wall be heard too before counting prompts.
        try await Task.sleep(for: .milliseconds(300))

        #expect(asked.count == 1)
        #expect(asked.first == login)
        for track in batch.prefix(2) {
            #expect(!failed(rig, track), "a song met a wall, it did not fail")
            #expect(try rig.index.download(forTrack: track.id)?.state == .queued)
        }

        // Nothing more is handed over until the user has signed in.
        let before = rig.downloader.handed.count
        let later = rig.tracks[5]
        await rig.manager.download([later], reason: reason(later))
        #expect(rig.downloader.handed.count == before)
        #expect(rig.manager.state(for: later.id) == .queued)
    }

    @Test("D-09: a sign-in page saved as a 200 is a wall too")
    func htmlBodyIsAWall() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        var asked = 0
        rig.manager.onProxyWall = { _ in asked += 1 }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))

        rig.downloader.emit(track.id.rawValue, .failed(.notAudio(.textual(contentType: "text/html"))))

        #expect(await rig.waitUntil { asked == 1 })
        #expect(!failed(rig, track))
    }

    @Test("D-09: after signing in, the next manager starts what the wall held")
    func signingInResumesTheHeldSongs() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        rig.downloader.emit(track.id.rawValue, .failed(.notAudio(.markup)))
        #expect(await rig.waitUntil { rig.manager.state(for: track.id) == .queued })
        rig.downloader.lose(track.id.rawValue)

        // Signing in reconnects: a new manager on the same library.
        let next = rig.replaceManager(proxySessions: FixedProxySession(cookie: "fresh"))
        await next.start()

        #expect(await rig.waitUntil { rig.downloader.handedCount(of: track.id.rawValue) == 2 })
        #expect(rig.downloader.handed.last?.request.value(forHTTPHeaderField: "Cookie") == "session=fresh")
    }

    // MARK: D-03

    @Test("D-03: something that is not a song is final for an original")
    func notAudioOriginalIsFinal() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        let track = rig.tracks[0]
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))

        rig.downloader.emit(track.id.rawValue, .failed(.notAudio(.textual(contentType: "application/json"))))

        #expect(await rig.waitUntil { failed(rig, track) })
    }

    @Test("D-03: a conversion cut short of what it should come to is thrown away and asked for again")
    func shortConversionIsRetried() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        rig.settings.downloadTranscode = TranscodePolicy(threshold: .always, codec: "opus", targetBitRateKbps: 128)
        guard let track = rig.tracks.first(where: { ($0.duration ?? 0) > 30 }) else {
            Issue.record("the mock library has no song long enough to estimate")
            return
        }
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        let handed = try #require(rig.downloader.handed.last)
        let expected = try #require(estimatedConversionBytes(kbps: 128, duration: track.duration))

        // Ten per cent of the song: the server dropped the connection.
        rig.land(handed.destination.lastPathComponent, bytes: Int(expected / 10))
        rig.downloader.emit(track.id.rawValue, .finished(handed.destination))

        #expect(await rig.waitUntil { !FileManager.default.fileExists(atPath: handed.destination.path) })
        #expect(rig.manager.state(for: track.id) != .done)
        #expect(!failed(rig, track), "the first short file costs an attempt, not the song")
        #expect(await rig.waitUntil(timeout: 4) { rig.downloader.handedCount(of: track.id.rawValue) == 2 })
    }

    @Test("D-03: a conversion near its estimate is a song")
    func plausibleConversionIsKept() async throws {
        let rig = try await DownloadRig()
        defer { rig.finish() }
        rig.settings.downloadTranscode = TranscodePolicy(threshold: .always, codec: "opus", targetBitRateKbps: 128)
        guard let track = rig.tracks.first(where: { ($0.duration ?? 0) > 30 }) else {
            Issue.record("the mock library has no song long enough to estimate")
            return
        }
        await rig.manager.start()
        await rig.manager.download([track], reason: reason(track))
        let handed = try #require(rig.downloader.handed.last)
        let expected = try #require(estimatedConversionBytes(kbps: 128, duration: track.duration))

        // A quiet, variable-rate encode can come in well under the target.
        rig.land(handed.destination.lastPathComponent, bytes: Int(Double(expected) * 0.4))
        rig.downloader.emit(track.id.rawValue, .finished(handed.destination))

        #expect(await rig.waitUntil { rig.manager.state(for: track.id) == .done })
    }
}
