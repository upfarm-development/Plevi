import Foundation
import PleviDomain
import PleviTransport
import PleviLibraryIndex
import PleviMockProvider
import PleviAudio
@testable import Plevi

/// A downloader that reports what a test says it reports.
final class FakeDownloader: BackgroundDownloading, @unchecked Sendable {
    struct Handed {
        let id: String
        let request: URLRequest
        let destination: URL
        let allowsCellular: Bool
    }

    private let lock = NSLock()
    private var handedOver: [Handed] = []
    private var batches: [Set<String>] = []
    private var singles: [String] = []
    private var reissues: [(ids: Set<String>, allowsCellular: Bool)] = []
    private var carried: Set<String> = []
    private var continuation: AsyncStream<BackgroundDownloadEvent>.Continuation?
    private var token = 0
    private var waiting: [BackgroundDownloadEvent] = []
    private(set) var attachCount = 0

    /// Every transfer handed over, in order.
    var handed: [Handed] { lock.withLock { handedOver } }
    /// Each `cancel(ids:)` call, as the set it was given.
    var cancelBatches: [Set<String>] { lock.withLock { batches } }
    /// Each `cancel(id:)` call.
    var singleCancels: [String] { lock.withLock { singles } }
    var reissued: [(ids: Set<String>, allowsCellular: Bool)] { lock.withLock { reissues } }

    func handedCount(of id: String) -> Int { handed.filter { $0.id == id }.count }

    /// Pretends the system is carrying these across, as after a relaunch.
    func carry(_ ids: Set<String>) { lock.withLock { carried.formUnion(ids) } }
    /// The system loses track of a transfer without saying so.
    func lose(_ id: String) { lock.withLock { _ = carried.remove(id) } }

    func attach() -> AsyncStream<BackgroundDownloadEvent> {
        let (stream, made) = AsyncStream<BackgroundDownloadEvent>.makeStream(bufferingPolicy: .unbounded)
        let (previous, mine): (AsyncStream<BackgroundDownloadEvent>.Continuation?, Int) = lock.withLock {
            attachCount += 1
            let previous = continuation
            token += 1
            continuation = made
            for event in waiting { made.yield(event) }
            waiting = []
            return (previous, token)
        }
        // A reader that goes away detaches itself and nobody else, as the
        // real downloader's does.
        made.onTermination = { [weak self] _ in
            self?.lock.withLock { if self?.token == mine { self?.continuation = nil } }
        }
        previous?.finish()
        return stream
    }

    /// An event from the system. Held if nobody is listening.
    func emit(_ id: String, _ kind: BackgroundDownloadEvent.Kind) {
        let event = BackgroundDownloadEvent(id: id, kind: kind)
        lock.withLock {
            if let continuation { continuation.yield(event) } else { waiting.append(event) }
        }
    }

    func enqueue(id: String, request: URLRequest, to destination: URL, allowsCellular: Bool) {
        lock.withLock {
            handedOver.append(Handed(id: id, request: request, destination: destination, allowsCellular: allowsCellular))
            carried.insert(id)
        }
    }

    func cancel(id: String) {
        lock.withLock {
            singles.append(id)
            carried.remove(id)
        }
    }

    func cancel(ids: Set<String>) {
        lock.withLock {
            batches.append(ids)
            carried.subtract(ids)
        }
    }

    func cancelAll() {
        lock.withLock { carried = [] }
    }

    func reissue(ids: Set<String>, allowsCellular: Bool) async -> Set<String> {
        lock.withLock { reissues.append((ids, allowsCellular)) }
        return []
    }

    func running() async -> [String] { lock.withLock { Array(carried) } }

    private var pauses: [Bool] = []
    /// Each `setPaused` call, in order.
    var pauseCalls: [Bool] { lock.withLock { pauses } }
    /// Whether the last call left the downloader held.
    var isHeld: Bool { pauseCalls.last ?? false }
    func setPaused(_ paused: Bool) { lock.withLock { pauses.append(paused) } }
}

/// A transport that has nothing to say. The download queue only holds one for
/// the segmented conversions it no longer fetches itself.
struct SilentTransport: HTTPTransport {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// A proxy session source that hands out a fixed cookie.
struct FixedProxySession: ProxySessionSource {
    let cookie: String
    func session(for url: URL) -> ProxySession? {
        guard let origin = URLOrigin(url: url) else { return nil }
        return ProxySession(origin: origin, cookies: [.init(name: "session", value: cookie)])
    }
}

/// One `DownloadManager` on an in-memory index, a mock provider and a fake
/// downloader, with the songs the mock library holds.
@MainActor
final class DownloadRig {
    let server = ServerID()
    let index: LibraryIndex
    let provider: MockProvider
    let downloader = FakeDownloader()
    let settings: AppSettings
    let network = NetworkPathMonitor()
    let store: DownloadStore
    private(set) var manager: DownloadManager
    /// The songs the index holds.
    let tracks: [Track]
    /// Songs the server has that the index does not, as a playlist can hold.
    let unindexed: [Track]
    private let suite: String

    init(proxySessions: (any ProxySessionSource)? = nil) async throws {
        index = try LibraryIndex(inMemoryFor: server)
        provider = MockProvider(serverID: server)
        suite = "DownloadRig-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        settings = AppSettings(defaults: defaults)
        store = DownloadStore(serverID: server)
        let found = try await provider.search("", limit: 50, offset: 0).tracks
        tracks = Array(found.prefix(12))
        unindexed = Array(found.dropFirst(12))
        try index.upsertTracks(tracks, generation: 1)
        try index.finishSync(generation: 1)
        manager = DownloadRig.makeManager(
            server: server, index: index, provider: provider, downloader: downloader,
            settings: settings, network: network, proxySessions: proxySessions
        )
    }

    private static func makeManager(
        server: ServerID, index: LibraryIndex, provider: MockProvider, downloader: FakeDownloader,
        settings: AppSettings, network: NetworkPathMonitor, proxySessions: (any ProxySessionSource)?
    ) -> DownloadManager {
        DownloadManager(
            serverID: server,
            index: index,
            provider: provider,
            downloader: downloader,
            transport: SilentTransport(),
            settings: settings,
            network: network,
            proxySessions: proxySessions
        )
    }

    /// Retires the current manager and builds another on the same library,
    /// the way `connectActive()` does.
    @discardableResult
    func replaceManager(proxySessions: (any ProxySessionSource)? = nil) -> DownloadManager {
        manager.stop()
        manager = Self.makeManager(
            server: server, index: index, provider: provider, downloader: downloader,
            settings: settings, network: network, proxySessions: proxySessions
        )
        return manager
    }

    func id(_ track: Track) -> MediaID { track.id }

    /// Puts a file where a finished transfer would have left it.
    @discardableResult
    func land(_ name: String, bytes: Int = 4096) -> URL {
        let url = store.url(named: name)
        try? Data(repeating: 0x42, count: bytes).write(to: url)
        return url
    }

    /// Waits for a condition on the main actor, up to `timeout` seconds.
    func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func finish() {
        manager.stop()
        try? FileManager.default.removeItem(at: store.directory)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
