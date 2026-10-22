import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

/// What `BackgroundDownloader` does with the responses a music server gives when it is under
/// stress, driven through the real `URLSession` against a loopback server.
@Suite("Stress: background downloader against a misbehaving server", .serialized)
struct StressDownloadsBackgroundDownloaderTests {

    // MARK: Harness

    /// One long-lived consumer of a downloader's event stream, the way
    /// `DownloadManager.listenForEvents()` is. Never cancelled by a test that
    /// still needs the stream — cancelling it ends the stream for good.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [BackgroundDownloadEvent] = []
        private var consumer: Task<Void, Never>?

        init(_ downloader: BackgroundDownloader) {
            let stream = downloader.attach()
            consumer = Task { [weak self] in
                for await event in stream {
                    self?.lock.withLock { self?.all.append(event) }
                }
            }
        }

        func events(for id: String) -> [BackgroundDownloadEvent] {
            lock.withLock { all.filter { $0.id == id } }
        }

        func terminals(for id: String) -> [BackgroundDownloadEvent.Kind] {
            events(for: id).compactMap { event -> BackgroundDownloadEvent.Kind? in
                switch event.kind {
                case .progress, .started, .waiting: nil
                default: event.kind
                }
            }
        }

        /// Polls until the transfer reports an end, or `timeout` passes.
        func waitForEnd(of id: String, timeout: TimeInterval) async -> BackgroundDownloadEvent.Kind? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let first = terminals(for: id).first { return first }
                try? await Task.sleep(for: .milliseconds(40))
            }
            return terminals(for: id).first
        }

        func stop() { consumer?.cancel() }
    }

    private struct Rig {
        let server: StressLoopbackServer
        let downloader: BackgroundDownloader
        let recorder: Recorder
        let directory: URL

        @discardableResult
        func fetch(_ path: String, id: String = "stress-\(UUID().uuidString)", file: String = "song.audio") -> (id: String, destination: URL) {
            let destination = directory.appending(path: file)
            downloader.enqueue(
                id: id,
                request: URLRequest(url: server.base.appending(path: path)),
                to: destination,
                allowsCellular: true
            )
            return (id, destination)
        }

        func teardown() {
            recorder.stop()
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeRig() async throws -> Rig {
        let server = try StressLoopbackServer()
        try await server.start()
        let downloader = BackgroundDownloader.shared(
            identifier: "com.example.plevi.tests.stress.\(UUID().uuidString)",
            pins: [],
            allowedOrigins: [URLOrigin(url: server.base)!]
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StressDownloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        return Rig(server: server, downloader: downloader, recorder: Recorder(downloader), directory: directory)
    }

    private func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }

    private static let subsonicNotFound = Data(
        #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"data not found"}}}"#.utf8
    )

    // MARK: Sound behaviour

    @Test("An ordinary audio response is delivered and moved into place")
    func ordinaryAudio() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/audio", .full(status: 200, contentType: "audio/mpeg", body: Data(repeating: 0x42, count: 20_000)))

        let (id, destination) = rig.fetch("/audio")
        let end = await rig.recorder.waitForEnd(of: id, timeout: 20)
        guard case .finished(let url)? = end else {
            Issue.record("expected .finished, got \(String(describing: end))")
            return
        }
        #expect(url == destination)
        #expect(size(of: destination) == 20_000)
    }

    @Test("An HTTP error status is a failure, not a file", arguments: [401, 403, 404, 500, 503])
    func httpErrorStatus(status: Int) async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/err", .full(status: status, contentType: "text/plain", body: Data("nope".utf8)))

        let (id, destination) = rig.fetch("/err")
        let end = await rig.recorder.waitForEnd(of: id, timeout: 20)
        guard case .failed(let failure)? = end else {
            Issue.record("expected .failed for HTTP \(status), got \(String(describing: end))")
            return
        }
        #expect(failure.message.contains("\(status)"))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("D-08: a redirect off the configured origin must be refused, and must not carry the token with it")
    func crossOriginRedirectIsFollowedWithHeaders() async throws {
        let home = try StressLoopbackServer()
        let elsewhere = try StressLoopbackServer()
        try await home.start()
        try await elsewhere.start()
        defer { home.stop(); elsewhere.stop() }
        elsewhere.route("/audio", .full(status: 200, contentType: "audio/mpeg", body: Data(repeating: 0x42, count: 4_000)))
        home.route("/away", .redirect(location: "http://127.0.0.1:\(elsewhere.port)/audio"))

        // Only `home` is one of the server's origins.
        let downloader = BackgroundDownloader.shared(
            identifier: "com.example.plevi.tests.stress.\(UUID().uuidString)",
            pins: [], allowedOrigins: [URLOrigin(url: home.base)!]
        )
        let recorder = Recorder(downloader)
        defer { recorder.stop() }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StressDownloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        var request = URLRequest(url: home.base.appending(path: "away"))
        request.setValue("SECRET-PLEX-TOKEN", forHTTPHeaderField: "X-Plex-Token")
        let id = "stress-\(UUID().uuidString)"
        downloader.enqueue(id: id, request: request, to: directory.appending(path: "song.audio"), allowsCellular: true)
        let end = await recorder.waitForEnd(of: id, timeout: 20)

        let followed = elsewhere.hitCount("/audio") > 0
        let leaked = elsewhere.lastRequestHead("/audio")?.contains("SECRET-PLEX-TOKEN") == true
        print("STRESS-D08 redirect to a foreign origin: followed=\(followed) tokenHeaderForwarded=\(leaked) outcome=\(String(describing: end))")

        // What can be done, and is: the end of the transfer is judged by where
        // it came from, the file is thrown away, and the failure says so. A
        // sign-in page reached this way used to arrive as a finished song.
        guard case .failed(.foreignHost(let final))? = end else {
            Issue.record("expected .failed(.foreignHost), got \(String(describing: end))")
            return
        }
        #expect(final.port == Int(elsewhere.port))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "song.audio").path))

        // What cannot: preventing it.
        withKnownIssue("D-08: background-session transfers follow cross-origin redirects; only the outcome can be judged") {
            #expect(!followed)
            #expect(!leaked)
        }
    }

    @Test("A destination that cannot be created is a storage failure, and nothing is left behind")
    func unwritableDestination() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/audio", .full(status: 200, contentType: "audio/mpeg", body: Data(repeating: 0x42, count: 5_000)))
        // A regular file where the directory should be: the disk-full and
        // permission-denied cases both arrive at the same `catch`.
        try FileManager.default.createDirectory(at: rig.directory, withIntermediateDirectories: true)
        let blocker = rig.directory.appending(path: "blocker")
        try Data("x".utf8).write(to: blocker)
        let id = "stress-\(UUID().uuidString)"
        rig.downloader.enqueue(
            id: id,
            request: URLRequest(url: rig.server.base.appending(path: "audio")),
            to: blocker.appending(path: "inside/song.audio"),
            allowsCellular: true
        )
        let end = await rig.recorder.waitForEnd(of: id, timeout: 20)
        guard case .failed(.storage)? = end else {
            Issue.record("expected .failed(.storage), got \(String(describing: end))")
            return
        }
    }

    @Test("A body cut short of its Content-Length is never reported as finished")
    func truncatedBodyIsNeverFinished() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/short", .truncated(contentType: "audio/mpeg", advertised: 10_000, sent: 100))

        let (id, _) = rig.fetch("/short")
        let end = await rig.recorder.waitForEnd(of: id, timeout: 8)
        // Observed: the system keeps the transfer alive and retries on its own, so within eight
        // seconds it reports neither success nor failure.
        if case .finished? = end { Issue.record("a truncated body was reported as finished") }
    }

    @Test("A body with no length is accepted as complete — only the manager can judge it, against the song's duration")
    func closeDelimitedBodyIsAccepted() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/closedelim", .closeDelimited(contentType: "audio/ogg", body: Data(repeating: 0x42, count: 3_000)))

        let (id, destination) = rig.fetch("/closedelim")
        let end = await rig.recorder.waitForEnd(of: id, timeout: 10)
        // Legal HTTP: the body ends when the socket does.
        guard case .finished? = end else {
            Issue.record("expected .finished, got \(String(describing: end))")
            return
        }
        #expect(size(of: destination) == 3_000)
    }

    @Test("Cancelling a transfer reports nothing at all")
    func cancelIsSilent() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/hold", .hold)

        let (id, _) = rig.fetch("/hold")
        try await Task.sleep(for: .milliseconds(600))
        rig.downloader.cancel(id: id)
        let end = await rig.recorder.waitForEnd(of: id, timeout: 3)
        // The manager relies on this: a cancelled song produces no `.failed`
        // event, so every code path that cancels has to do its own
        // bookkeeping (`discard`, `rescue`, `yieldToPlayback`).
        #expect(end == nil)
    }

    // MARK: Reproduced defects

    @Test("D-03: a Subsonic error answered with HTTP 200 must not become a downloaded song")
    func subsonicErrorBodyWith200() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/rest/download", .full(status: 200, contentType: "application/json", body: Self.subsonicNotFound))

        let (id, destination) = rig.fetch("/rest/download")
        let end = await rig.recorder.waitForEnd(of: id, timeout: 20)
        guard case .failed(.notAudio(let reason))? = end else {
            Issue.record("expected .failed(.notAudio), got \(String(describing: end))")
            return
        }
        #expect(reason == .textual(contentType: "application/json"))
        #expect(!FileManager.default.fileExists(atPath: destination.path), "the error page must not be left under the song's name")
    }

    @Test("D-03: a login or captive-portal page answered with HTTP 200 must not become a downloaded song")
    func htmlPageWith200() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/portal", .full(status: 200, contentType: "text/html; charset=utf-8", body: Data("<html><body>Sign in to Wi-Fi</body></html>".utf8)))

        let (id, destination) = rig.fetch("/portal")
        let end = await rig.recorder.waitForEnd(of: id, timeout: 20)
        guard case .failed(.notAudio(let reason))? = end else {
            Issue.record("expected .failed(.notAudio), got \(String(describing: end))")
            return
        }
        // A web page in the way is what a sign-in wall looks like, and the
        // queue treats it differently from a damaged transfer.
        #expect(reason.looksLikeAWebPage)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("D-03: a chunked body cut off before its terminator cannot be told from a whole one at this layer")
    func chunkedBodyCutOff() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/chunkcut", .chunkedCut(contentType: "audio/ogg", body: Data(repeating: 0x42, count: 3_000)))

        let (id, destination) = rig.fetch("/chunkcut")
        let end = await rig.recorder.waitForEnd(of: id, timeout: 10)
        guard case .finished? = end else {
            Issue.record("expected .finished (the daemon reports the cut body as complete), got \(String(describing: end))")
            return
        }
        // RFC 9112 §6.3: a chunked message with no terminating chunk is incomplete, and the
        // background session reports it as a success with no length announced to compare the file
        // against.
        #expect(size(of: destination) == 3_000)
    }

    @Test("D-03: an empty 200 must not become a downloaded song")
    func emptyBodyWith200() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/empty", .full(status: 200, contentType: "audio/mpeg", body: Data()))

        let (id, destination) = rig.fetch("/empty")
        let end = await rig.recorder.waitForEnd(of: id, timeout: 20)
        guard case .failed(.notAudio(.empty))? = end else {
            Issue.record("expected .failed(.notAudio(.empty)), got \(String(describing: end))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("D-01: a second reader still hears events after the first was cancelled")
    func eventsSurviveAConsumerBeingCancelled() async throws {
        let rig = try await makeRig()
        rig.server.route("/audio", .full(status: 200, contentType: "audio/mpeg", body: Data(repeating: 0x42, count: 20_000)))
        defer { rig.server.stop(); try? FileManager.default.removeItem(at: rig.directory) }

        // `DownloadManager.stop()` is `events?.cancel()` on exactly this kind of task, and
        // `AppModel.connectActive()` calls it every time it builds a new manager — the next manager
        // for the same library then iterates the same, shared…
        rig.recorder.stop()
        try await Task.sleep(for: .milliseconds(150))

        let successor = Recorder(rig.downloader)
        defer { successor.stop() }
        let (id, destination) = rig.fetch("/audio")
        let end = await successor.waitForEnd(of: id, timeout: 6)

        // The bytes do arrive: the delegate moves the file into place.
        for _ in 0..<50 where size(of: destination) == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(size(of: destination) == 20_000)

        guard case .finished? = end else {
            Issue.record("the successor never heard the transfer end (got \(String(describing: end)))")
            return
        }
    }

    @Test("D-13: asking again for a library's downloader hands back the same session")
    func registryKeepsTheFirstInstance() async throws {
        let server = try StressLoopbackServer()
        try await server.start()
        defer { server.stop() }
        // `AppModel.connectActive()` asks for the library's downloader every time it reconnects,
        // passing the server's *current* pins and origins — after an edit to the server, a
        // re-pinned certificate.
        let identifier = "com.example.plevi.tests.stress.\(UUID().uuidString)"
        let before = BackgroundDownloader.shared(
            identifier: identifier, pins: [], allowedOrigins: [URLOrigin(url: server.base)!]
        )
        let after = BackgroundDownloader.shared(
            identifier: identifier,
            pins: [PinnedCertificate(origin: URLOrigin(url: server.base)!, sha256: Data(repeating: 7, count: 32))],
            allowedOrigins: []
        )
        // One session per identifier for the life of the process, as ever; the
        // policy it enforces is the newest one (see StressDownloadsLifecycleTests).
        #expect(before === after)
    }

    // MARK: Behaviour that shapes the manager's watchdog

    @Test("Handing over more transfers than the system runs at once leaves the rest silent")
    func excessTransfersReportNothing() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/hold", .hold)

        let ids = (0..<30).map { _ in rig.fetch("/hold").id }
        try await Task.sleep(for: .seconds(4))

        let reached = rig.server.hitCount("/hold")
        let heardFrom = ids.filter { !rig.recorder.events(for: $0).isEmpty }.count
        print("STRESS-D02 handed over 30 transfers; the server saw \(reached) connections; \(heardFrom) of 30 reported anything")
        // Whatever the platform's limit is, it is lower than "all of them": the rest sit inside the
        // system with nothing to report, which is exactly what `DownloadManager.sweepStuck` reads
        // as "no sign of life for 180 seconds" (D-02).
        #expect(reached < 30, "every transfer started at once, so the system-queue premise of D-02 does not hold on this platform")
        for id in ids { rig.downloader.cancel(id: id) }
    }

    @Test("A cancel followed at once by a fresh transfer under the same id must not take the new one down")
    func cancelThenEnqueueSameId() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/audio", .slow(delay: 1.0, contentType: "audio/mpeg", body: Data(repeating: 0x42, count: 8_000)))
        try FileManager.default.createDirectory(at: rig.directory, withIntermediateDirectories: true)

        // What `rescue` and `discard` followed by a quick re-request do:
        // `cancel(id:)` is asynchronous (`getAllTasks`) and matches by id, so
        // it can meet the replacement.
        let attempts = 12
        for attempt in 0..<attempts {
            let id = "same-id-\(attempt)"
            rig.downloader.enqueue(id: id, request: URLRequest(url: rig.server.base.appending(path: "audio")), to: rig.directory.appending(path: "a-\(attempt)"), allowsCellular: true)
            rig.downloader.cancel(id: id)
            rig.downloader.enqueue(id: id, request: URLRequest(url: rig.server.base.appending(path: "audio")), to: rig.directory.appending(path: "b-\(attempt)"), allowsCellular: true)
        }
        // Polled rather than slept: twelve one-second responses through the
        // system's six-at-a-time queue take longer than eight seconds when the
        // machine is busy, and a slow arrival is not a lost one.
        let deadline = Date().addingTimeInterval(45)
        var lost = attempts
        while Date() < deadline {
            lost = (0..<attempts).filter {
                !FileManager.default.fileExists(atPath: rig.directory.appending(path: "b-\($0)").path)
            }.count
            if lost == 0 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        print("STRESS-cancel-then-enqueue on the same id: replacement lost in \(lost) of \(attempts) attempts")
        // Suspected while reading (`cancel` is asynchronous and matches by
        // id), not reproduced: `getAllTasks` answers with the tasks that
        // existed when it was called.
        #expect(lost == 0)
    }
}
