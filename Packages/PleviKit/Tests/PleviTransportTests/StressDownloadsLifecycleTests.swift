import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

/// The downloader's lifetime against its readers (D-01) and its policy against edits to the server
/// (D-13).
@Suite("Stress: downloader lifecycle", .serialized)
struct StressDownloadsLifecycleTests {

    private func event(_ id: String, _ kind: BackgroundDownloadEvent.Kind) -> BackgroundDownloadEvent {
        BackgroundDownloadEvent(id: id, kind: kind)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [BackgroundDownloadEvent] = []
        init(_ stream: AsyncStream<BackgroundDownloadEvent>) {
            Task { [weak self] in
                for await event in stream { self?.lock.withLock { self?.all.append(event) } }
            }
        }
        var events: [BackgroundDownloadEvent] { lock.withLock { all } }
    }

    /// What a reader of `stream` has heard, once `count` events are in or
    /// `timeout` has passed.
    private func read(_ stream: AsyncStream<BackgroundDownloadEvent>, count: Int, timeout: Double = 2) async -> [BackgroundDownloadEvent] {
        let collector = Collector(stream)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, collector.events.count < count {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return collector.events
    }

    // MARK: D-01

    @Test("D-01: cancelling a reader does not end the stream for the next one")
    func cancellingAReaderLeavesTheSourceAlive() async {
        let relay = EventRelay()
        let first = Task { for await _ in relay.attach() {} }
        try? await Task.sleep(for: .milliseconds(50))
        first.cancel()
        _ = await first.value
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!relay.hasReader, "a cancelled reader must be detached")

        let stream = relay.attach()
        relay.emit(event("a", .finished(URL(fileURLWithPath: "/tmp/a"))))
        let got = await read(stream, count: 1)
        #expect(got.map(\.id) == ["a"])
    }

    @Test("D-01: events that arrive between one reader stopping and the next attaching are delivered")
    func eventsBetweenStopAndAttachAreKept() async {
        let relay = EventRelay()
        let first = Task { for await _ in relay.attach() {} }
        try? await Task.sleep(for: .milliseconds(50))
        first.cancel()
        _ = await first.value
        try? await Task.sleep(for: .milliseconds(50))

        // Nobody is listening: a transfer finishes, another fails, a third
        // is still moving.
        relay.emit(event("done", .finished(URL(fileURLWithPath: "/tmp/done"))))
        relay.emit(event("bad", .failed(.storage("disk"))))
        relay.emit(event("moving", .progress(received: 10, expected: 100)))
        relay.emit(event("moving", .progress(received: 60, expected: 100)))

        let got = await read(relay.attach(), count: 3)
        #expect(got.count == 3)
        // The newest progress replaced the older; endings keep their order.
        let moving = got.filter { $0.id == "moving" }
        #expect(moving.count == 1)
        if case .progress(let received, _)? = moving.first?.kind { #expect(received == 60) }
        #expect(got.filter { $0.id != "moving" }.map(\.id) == ["done", "bad"])
    }

    @Test("D-01: attaching finishes the previous reader's stream and hands over to the new one")
    func attachingFinishesThePreviousReader() async {
        let relay = EventRelay()
        let old = relay.attach()
        let new = relay.attach()

        var oldEnded = false
        for await _ in old { break }
        oldEnded = true
        #expect(oldEnded, "the replaced reader's loop must end rather than sit in for-await for ever")

        relay.emit(event("x", .finished(URL(fileURLWithPath: "/tmp/x"))))
        let got = await read(new, count: 1)
        #expect(got.map(\.id) == ["x"])
    }

    @Test("D-01: a replaced reader ending does not detach its successor")
    func replacedReaderDoesNotDetachSuccessor() async {
        let relay = EventRelay()
        let oldTask = Task { for await _ in relay.attach() {} }
        try? await Task.sleep(for: .milliseconds(50))
        let new = relay.attach()          // finishes the old stream
        _ = await oldTask.value           // its termination handler has run
        #expect(relay.hasReader)
        relay.emit(event("y", .finished(URL(fileURLWithPath: "/tmp/y"))))
        let got = await read(new, count: 1)
        #expect(got.map(\.id) == ["y"])
    }

    @Test("D-01: a transfer's ending removes its buffered progress")
    func endingDropsBufferedProgress() async {
        let relay = EventRelay()
        relay.emit(event("t", .progress(received: 5, expected: 10)))
        relay.emit(event("t", .finished(URL(fileURLWithPath: "/tmp/t"))))
        let got = await read(relay.attach(), count: 2, timeout: 0.5)
        #expect(got.count == 1)
        if case .finished? = got.first?.kind {} else { Issue.record("expected the ending only") }
    }

    @Test("D-01: a reader that is dropped without being cancelled is detached too")
    func droppedReaderIsDetached() async {
        let relay = EventRelay()
        do {
            let stream = relay.attach()
            _ = stream
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!relay.hasReader)
        relay.emit(event("z", .finished(URL(fileURLWithPath: "/tmp/z"))))
        let got = await read(relay.attach(), count: 1)
        #expect(got.map(\.id) == ["z"])
    }

    // MARK: D-13

    @Test("D-13: asking again for a library's downloader hands back the first session with the newest policy")
    func registryUpdatesThePolicy() async throws {
        let server = try StressLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let origin = URLOrigin(url: server.base)!
        let identifier = "com.example.plevi.tests.stress.\(UUID().uuidString)"
        let before = BackgroundDownloader.shared(
            identifier: identifier, pins: [], allowedOrigins: [origin]
        )
        #expect(before.securityPolicyPins.isEmpty)
        let pin = PinnedCertificate(origin: origin, sha256: Data(repeating: 7, count: 32))
        let after = BackgroundDownloader.shared(
            identifier: identifier, pins: [pin], allowedOrigins: []
        )
        #expect(before === after)
        #expect(after.securityPolicyPins == [pin])
        #expect(after.securityPolicyOrigins.isEmpty)
    }

    @Test("D-13: a redirect that was allowed under the old origins is refused under the new ones, and the other way round")
    func redirectPolicyFollowsTheUpdate() {
        let home = URL(string: "https://home.example:4533/")!
        let away = URL(string: "https://away.example:4533/")!
        let delegate = ServerSessionDelegate(pins: [], allowedOrigins: [URLOrigin(url: home)!])

        func decide(to destination: URL) -> Bool {
            let task = URLSession.shared.dataTask(with: URLRequest(url: home))
            let response = HTTPURLResponse(url: home, statusCode: 302, httpVersion: nil, headerFields: nil)!
            var followed: Bool?
            delegate.urlSession(
                URLSession.shared, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: destination)
            ) { followed = ($0 != nil) }
            return followed ?? false
        }

        #expect(decide(to: home))
        #expect(!decide(to: away))
        delegate.update(pins: [], allowedOrigins: [URLOrigin(url: away)!], identityProvider: NoClientIdentity())
        #expect(!decide(to: home))
        #expect(decide(to: away))
    }

    @Test("D-13: changing the pin clears a stale trust rejection")
    func repinningClearsTheOldTrustFailure() {
        let origin = URLOrigin(url: URL(string: "https://home.example:4533/")!)!
        let delegate = ServerSessionDelegate(pins: [], allowedOrigins: [origin])
        delegate.update(
            pins: [PinnedCertificate(origin: origin, sha256: Data(repeating: 1, count: 32))],
            allowedOrigins: [origin],
            identityProvider: NoClientIdentity()
        )
        #expect(delegate.currentPins.count == 1)
        #expect(delegate.lastTrustFailure == nil)
    }
}
