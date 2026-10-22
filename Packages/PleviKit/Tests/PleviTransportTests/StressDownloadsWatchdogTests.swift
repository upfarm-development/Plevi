import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

/// What the download queue's watchdog is given to work with (D-02), and the
/// cellular policy a transfer carries (D-12), driven through the real
/// `URLSession` against a loopback server.
@Suite("Stress: signs of life and cellular policy", .serialized)
struct StressDownloadsWatchdogTests {

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [BackgroundDownloadEvent] = []
        init(_ stream: AsyncStream<BackgroundDownloadEvent>) {
            Task { [weak self] in
                for await event in stream { self?.lock.withLock { self?.all.append(event) } }
            }
        }
        func events(for id: String) -> [BackgroundDownloadEvent] {
            lock.withLock { all.filter { $0.id == id } }
        }
        func waitForEnd(of id: String, timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let ended = events(for: id).contains {
                    switch $0.kind {
                    case .finished, .failed: true
                    default: false
                    }
                }
                if ended { return true }
                try? await Task.sleep(for: .milliseconds(40))
            }
            return false
        }
    }

    private struct Rig {
        let server: StressLoopbackServer
        let downloader: BackgroundDownloader
        let collector: Collector
        let directory: URL

        func enqueue(_ path: String, id: String = "wd-\(UUID().uuidString)", allowsCellular: Bool = true) -> String {
            downloader.enqueue(
                id: id,
                request: URLRequest(url: server.base.appending(path: path)),
                to: directory.appending(path: "\(id).audio"),
                allowsCellular: allowsCellular
            )
            return id
        }

        func teardown() {
            downloader.cancelAll()
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
            .appending(path: "StressWatchdog-\(UUID().uuidString)", directoryHint: .isDirectory)
        return Rig(server: server, downloader: downloader, collector: Collector(downloader.attach()), directory: directory)
    }

    private func isStarted(_ event: BackgroundDownloadEvent) -> Bool {
        if case .started = event.kind { return true }
        return false
    }

    // MARK: D-02

    @Test("D-02: a transfer that is moving says so before it says anything else")
    func startedComesFirst() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/audio", .full(status: 200, contentType: "audio/mpeg", body: Data(repeating: 0x42, count: 30_000)))

        let id = rig.enqueue("/audio")
        #expect(await rig.collector.waitForEnd(of: id, timeout: 60))
        let events = rig.collector.events(for: id)
        #expect(events.first.map(isStarted) == true, "the first thing heard from a transfer is that it started")
        #expect(events.filter(isStarted).count == 1)
    }

    @Test("D-02: a transfer the server has not answered stays silent, and so cannot be called stalled")
    func heldTransferNeverStarts() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/hold", .hold)

        let id = rig.enqueue("/hold")
        try await Task.sleep(for: .seconds(2))
        #expect(rig.collector.events(for: id).filter(isStarted).isEmpty)
        // And it is still carried by the session: silence is not loss.
        #expect(await rig.downloader.running().contains(id))
    }

    @Test("D-02: a transfer restarted under the same id announces its own start")
    func restartAnnouncesAgain() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/audio", .full(status: 200, contentType: "audio/mpeg", body: Data(repeating: 0x42, count: 30_000)))
        let id = "wd-\(UUID().uuidString)"
        _ = rig.enqueue("/audio", id: id)
        #expect(await rig.collector.waitForEnd(of: id, timeout: 60))
        _ = rig.enqueue("/audio", id: id)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, rig.collector.events(for: id).filter(isStarted).count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rig.collector.events(for: id).filter(isStarted).count == 2)
    }

    // MARK: O-05

    @Test("O-05: several transfers are cancelled in one call, and the rest carry on")
    func cancelManyAtOnce() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/hold", .hold)
        let ids = (0..<8).map { _ in rig.enqueue("/hold") }
        let doomed = Set(ids.prefix(5))
        let kept = Set(ids.suffix(3))

        rig.downloader.cancel(ids: doomed)

        let deadline = Date().addingTimeInterval(10)
        var left = Set(await rig.downloader.running())
        while Date() < deadline, !left.isDisjoint(with: doomed) {
            try await Task.sleep(for: .milliseconds(100))
            left = Set(await rig.downloader.running())
        }
        #expect(left.isDisjoint(with: doomed))
        #expect(kept.isSubset(of: left))
    }

    @Test("O-05: cancelling an id that is a prefix of another does not take the longer one with it")
    func cancelIsExactOnIds() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/hold", .hold)
        let short = rig.enqueue("/hold", id: "song-1")
        let long = rig.enqueue("/hold", id: "song-10")
        rig.downloader.cancel(ids: [short])
        try await Task.sleep(for: .milliseconds(800))
        let left = Set(await rig.downloader.running())
        #expect(left.contains(long))
        #expect(!left.contains(short))
    }

    // MARK: D-12

    @Test("D-12: a transfer that may not use mobile data also may not use an expensive network")
    func expensiveFollowsCellular() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/hold", .hold)
        let off = rig.enqueue("/hold", allowsCellular: false)
        let on = rig.enqueue("/hold", allowsCellular: true)
        let requests = await rig.downloader.originalRequests()
        #expect(requests[off]?.allowsCellularAccess == false)
        #expect(requests[off]?.allowsExpensiveNetworkAccess == false)
        #expect(requests[on]?.allowsCellularAccess == true)
        #expect(requests[on]?.allowsExpensiveNetworkAccess == true)
        // Low Data Mode is a separate switch and Wi-Fi can be in it: it must
        // not follow the cellular setting or a default install would never
        // download on such a network.
        #expect(requests[off]?.allowsConstrainedNetworkAccess == true)
    }

    @Test("D-12: reissue replaces only the transfers whose policy no longer matches, and says which")
    func reissueOnlyWhatDiffers() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        rig.server.route("/hold", .hold)
        let wifiOnly = rig.enqueue("/hold", allowsCellular: false)
        let anywhere = rig.enqueue("/hold", allowsCellular: true)

        // The listener says yes to mobile data.
        let replaced = await rig.downloader.reissue(ids: [wifiOnly, anywhere], allowsCellular: true)
        #expect(replaced == [wifiOnly])
        try await Task.sleep(for: .milliseconds(500))
        let requests = await rig.downloader.originalRequests()
        #expect(requests[wifiOnly]?.allowsCellularAccess == true)
        #expect(requests[wifiOnly]?.allowsExpensiveNetworkAccess == true)
        #expect(Set(await rig.downloader.running()).isSuperset(of: [wifiOnly, anywhere]))

        // Nothing differs any more, so nothing is touched.
        #expect(await rig.downloader.reissue(ids: [wifiOnly, anywhere], allowsCellular: true).isEmpty)
    }

    @Test("D-12: reissue reports nothing for a transfer it does not carry")
    func reissueUnknownId() async throws {
        let rig = try await makeRig()
        defer { rig.teardown() }
        #expect(await rig.downloader.reissue(ids: ["nobody"], allowsCellular: false).isEmpty)
        #expect(await rig.downloader.reissue(ids: [], allowsCellular: false).isEmpty)
    }
}
