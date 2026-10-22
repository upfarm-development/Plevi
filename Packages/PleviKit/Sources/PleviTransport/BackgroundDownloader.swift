import Foundation
import Synchronization
import PleviDomain

/// Why a transfer stopped short.
public enum BackgroundDownloadFailure: Error, Sendable {
    case server(ProviderError)
    case storage(String)
    /// The phone has no room for the file. Its own case because the answer to
    /// it is different from every other failure: nothing is wrong with the
    /// song or the server, and every song after it will fail the same way.
    case outOfSpace(String)
    /// The server said 200 and sent something that is not a song.
    case notAudio(NotAudioReason)
    /// The transfer ended somewhere other than the server: a redirect took it
    /// to another host, which is how an SSO proxy sends a request to its
    /// identity provider.
    case foreignHost(URL)

    public var message: String {
        switch self {
        case .server(let error):
            // With the code, for a network failure — see
            // `diagnosticDescription`. A failed transfer is one of the few
            // places in the app whose only job is saying what went wrong.
            return error.diagnosticDescription
        case .storage(let details), .outOfSpace(let details):
            return details
        case .notAudio(let reason):
            return reason.message
        case .foreignHost(let url):
            // The host alone: the rest of the URL can carry credentials.
            return "The download was sent to another site (\(url.host() ?? "unknown")), which is what a sign-in page does."
        }
    }
}

/// What a background transfer reports back.
public struct BackgroundDownloadEvent: Sendable {
    public enum Kind: Sendable {
        /// The first bytes of this transfer have arrived. Until they do, silence
        /// means nothing: the system may be holding it in a queue, or waiting
        /// for a network it is allowed to use.
        case started
        /// The system is holding this transfer until it has a connection it is
        /// allowed to use.
        case waiting
        case progress(received: Int64, expected: Int64?)
        case finished(URL)
        case failed(BackgroundDownloadFailure)
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// File transfers that outlive the app.
public final class BackgroundDownloader: NSObject, @unchecked Sendable {
    /// Implicitly unwrapped because the session's delegate is this object:
    /// neither can be made before the other, so the session is built as soon
    /// as `super.init` has run.
    private var session: URLSession!
    private let security: ServerSessionDelegate
    private let relay = EventRelay()

    /// The events from here on, for one reader at a time.
    public func attach() -> AsyncStream<BackgroundDownloadEvent> {
        relay.attach()
    }

    /// What the session currently holds connections to. For tests.
    var securityPolicyPins: [PinnedCertificate] { security.currentPins }
    var securityPolicyOrigins: Set<URLOrigin> { security.currentAllowedOrigins }

    /// Tells the relay directly. For tests that drive a reader or a manager
    /// without a network in between.
    func emit(_ event: BackgroundDownloadEvent) { relay.emit(event) }

    /// When each transfer last reported, so it reports at a rate somebody could read rather than
    /// the rate the network happens to deliver at.
    private var lastProgress: [String: Date] = [:]
    /// Tasks that have reported their first bytes.
    private var startedTasks: Set<Int> = []

    /// When each task was handed over, in a count of this object's own.
    private struct Serials {
        var next = 0
        var byTask: [Int: Int] = [:]
    }
    private let serials = Mutex(Serials())

    /// Whether transfers are being held for something that needs the
    /// connection more, so that a transfer queued meanwhile waits too.
    private let paused = Mutex(false)

    /// Holds every running transfer, or lets them go again.
    public func setPaused(_ isPaused: Bool) {
        paused.withLock { $0 = isPaused }
        session.getAllTasks { tasks in
            for task in tasks {
                if isPaused {
                    if task.state == .running { task.suspend() }
                } else if task.state == .suspended {
                    task.resume()
                }
            }
        }
    }

    private func stampNow() -> Int { serials.withLock { $0.next } }

    private func register(_ task: URLSessionTask) {
        serials.withLock {
            $0.next += 1
            $0.byTask[task.taskIdentifier] = $0.next
        }
    }

    private func forget(_ task: URLSessionTask) {
        serials.withLock { _ = $0.byTask.removeValue(forKey: task.taskIdentifier) }
    }

    private func isOlder(_ task: URLSessionTask, than stamp: Int) -> Bool {
        (serials.withLock { $0.byTask[task.taskIdentifier] } ?? 0) <= stamp
    }
    private static let progressInterval: TimeInterval = 0.2

    /// One live session per identifier, for the lifetime of the process.
    private static let registry = Mutex<[String: BackgroundDownloader]>([:])

    /// The hand-over this session's launch events are announced through.
    /// See `LaunchHandover`, which is where the care lives.
    private let handover = LaunchHandover()

    public static func shared(
        identifier: String,
        pins: [PinnedCertificate],
        allowedOrigins: Set<URLOrigin>,
        identityProvider: any ClientIdentityProviding = NoClientIdentity()
    ) -> BackgroundDownloader {
        registry.withLock { registry in
            if let existing = registry[identifier] {
                // The session is the first one's, the policy is the latest:
                // a re-pinned certificate or a new address reaches the
                // transfers already running, not only the next launch.
                existing.security.update(
                    pins: pins,
                    allowedOrigins: allowedOrigins,
                    identityProvider: identityProvider
                )
                return existing
            }
            let made = BackgroundDownloader(
                identifier: identifier,
                pins: pins,
                allowedOrigins: allowedOrigins,
                identityProvider: identityProvider
            )
            registry[identifier] = made
            return made
        }
    }

    private init(
        identifier: String,
        pins: [PinnedCertificate],
        allowedOrigins: Set<URLOrigin>,
        identityProvider: any ClientIdentityProviding
    ) {
        self.security = ServerSessionDelegate(
            pins: pins,
            allowedOrigins: allowedOrigins,
            identityProvider: identityProvider
        )
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        // Ours to schedule, not the system's: the user asked for these files,
        // and a download that waits for a charger is a download that is not
        // there on the train.
        configuration.isDiscretionary = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        // Nothing here says how many run at once, and nothing here can.
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        // Nothing is being held at the start of a process, so any transfer
        // found suspended was held by one that ended before it let go.
        session.getAllTasks { tasks in
            for task in tasks where task.state == .suspended { task.resume() }
        }
    }

    /// Whether a transfer may use mobile data. Set per transfer rather than on
    /// the session, so changing the setting affects what is queued next
    /// without disturbing what is already running.
    public func enqueue(id: String, request: URLRequest, to destination: URL, allowsCellular: Bool) {
        // There is something to be told about again.
        handover.expectMore()
        var request = request
        request.allowsCellularAccess = allowsCellular
        // The same question, asked of a Personal Hotspot: it is Wi-Fi to the phone and mobile data
        // to the bill.
        request.allowsExpensiveNetworkAccess = allowsCellular
        let task = session.downloadTask(with: request)
        // Stamped before it can be found by id: a task is visible to `getAllTasks` as soon as it
        // exists, but is only matched once it has a description, and a cancel that met it in
        // between would find no stamp and take it for an old one.
        register(task)
        task.taskDescription = Self.describe(id: id, destination: destination)
        if !paused.withLock({ $0 }) { task.resume() }
    }

    public func cancel(id: String) {
        let stamp = stampNow()
        session.getAllTasks { [self] tasks in
            for task in tasks where Self.identifier(of: task) == id && isOlder(task, than: stamp) {
                task.cancel()
            }
        }
    }

    /// Cancels several transfers in one pass over the session's tasks.
    public func cancel(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let stamp = stampNow()
        session.getAllTasks { [self] tasks in
            for task in tasks {
                guard let id = Self.identifier(of: task), ids.contains(id),
                      isOlder(task, than: stamp)
                else { continue }
                task.cancel()
            }
        }
    }

    /// Starts again, under a changed cellular policy, the transfers whose policy no longer matches.
    public func reissue(ids: Set<String>, allowsCellular: Bool) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            session.getAllTasks { [self] tasks in
                var replaced: Set<String> = []
                for task in tasks {
                    guard let id = Self.identifier(of: task), ids.contains(id),
                          task is URLSessionDownloadTask,
                          let original = task.originalRequest,
                          original.allowsCellularAccess != allowsCellular
                    else { continue }
                    let expected = task.countOfBytesExpectedToReceive
                    if expected > 0,
                       Double(task.countOfBytesReceived) / Double(expected) > Self.reissueCutoff {
                        continue
                    }
                    var request = original
                    request.allowsCellularAccess = allowsCellular
                    request.allowsExpensiveNetworkAccess = allowsCellular
                    let replacement = session.downloadTask(with: request)
                    register(replacement)
                    replacement.taskDescription = task.taskDescription
                    task.cancel()
                    if !paused.withLock({ $0 }) { replacement.resume() }
                    replaced.insert(id)
                }
                continuation.resume(returning: replaced)
            }
        }
    }

    /// Past this fraction a transfer is left alone by `reissue`.
    static let reissueCutoff = 0.9

    public func cancelAll() {
        let stamp = stampNow()
        session.getAllTasks { [self] tasks in
            for task in tasks where isOlder(task, than: stamp) { task.cancel() }
        }
    }

    /// What the system is still working on — asked at launch, when our own
    /// idea of the queue may be a relaunch out of date.
    public func running() async -> [String] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.compactMap(Self.identifier(of:)))
            }
        }
    }

    /// The requests the session is carrying, by id. For tests.
    func originalRequests() async -> [String: URLRequest] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                var found: [String: URLRequest] = [:]
                for task in tasks {
                    if let id = Self.identifier(of: task), let request = task.originalRequest {
                        found[id] = request
                    }
                }
                continuation.resume(returning: found)
            }
        }
    }

    /// Waits until the session has delivered everything it saved up while the
    /// app was away. The caller must not return before this does, or iOS
    /// suspends us mid-hand-over and the last transfers look unfinished.
    public func waitForSavedEvents() async { await handover.wait() }

    // MARK: Task identity

    static func describe(id: String, destination: URL) -> String {
        "\(id)\n\(destination.path)"
    }

    static func identifier(inDescription description: String?) -> String? {
        guard let first = description?.components(separatedBy: "\n").first, !first.isEmpty
        else { return nil }
        return first
    }

    /// Everything after the first line, so a path is not required to be free
    /// of newlines to survive the round trip.
    static func destination(inDescription description: String?) -> URL? {
        let parts = description?.components(separatedBy: "\n") ?? []
        guard parts.count >= 2 else { return nil }
        let path = parts.dropFirst().joined(separator: "\n")
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func identifier(of task: URLSessionTask) -> String? {
        identifier(inDescription: task.taskDescription)
    }

    private static func destination(of task: URLSessionTask) -> URL? {
        destination(inDescription: task.taskDescription)
    }
}

extension BackgroundDownloader: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = Self.identifier(of: downloadTask) else { return }
        if startedTasks.insert(downloadTask.taskIdentifier).inserted {
            relay.emit(BackgroundDownloadEvent(id: id, kind: .started))
        }
        let now = Date()
        if let last = lastProgress[id], now.timeIntervalSince(last) < Self.progressInterval {
            return
        }
        lastProgress[id] = now
        relay.emit(BackgroundDownloadEvent(
            id: id,
            kind: .progress(
                received: totalBytesWritten,
                expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            )
        ))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = Self.identifier(of: downloadTask) else { return }
        lastProgress[id] = nil
        startedTasks.remove(downloadTask.taskIdentifier)
        guard let destination = Self.destination(of: downloadTask) else {
            // Nothing to move it to, so say so: a transfer that finishes in
            // silence leaves a row that says "downloading" for ever.
            relay.emit(BackgroundDownloadEvent(
                id: id,
                kind: .failed(.storage("The download finished with nowhere to put it."))
            ))
            return
        }

        // An HTTP error arrives as a perfectly good file containing the error
        // page. Keeping that as an album track is worse than failing.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            relay.emit(BackgroundDownloadEvent(
                id: id,
                kind: .failed(.server(.serverError(
                    code: http.statusCode,
                    message: "HTTP \(http.statusCode)",
                    helpURL: nil
                )))
            ))
            return
        }

        // The transfer ended somewhere other than the server.
        if let final = downloadTask.response?.url,
           let origin = URLOrigin(url: final),
           !security.currentAllowedOrigins.contains(origin) {
            relay.emit(BackgroundDownloadEvent(id: id, kind: .failed(.foreignHost(final))))
            return
        }

        // A 2xx is not yet a song. An error page, a sign-in wall and an empty
        // body all arrive this way, and kept, each is a file the player is
        // later told to play.
        if let reason = AudioResponseCheck.verdict(forFileAt: location, response: downloadTask.response) {
            relay.emit(BackgroundDownloadEvent(id: id, kind: .failed(.notAudio(reason))))
            return
        }

        do {
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            // Moved here and now: `location` is gone by the time this method
            // returns.
            try FileManager.default.moveItem(at: location, to: destination)
            relay.emit(BackgroundDownloadEvent(id: id, kind: .finished(destination)))
        } catch {
            relay.emit(BackgroundDownloadEvent(
                id: id,
                kind: .failed(Self.isOutOfSpace(error)
                    ? .outOfSpace(error.localizedDescription)
                    : .storage(error.localizedDescription))
            ))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let id = Self.identifier(of: task) else { return }
        lastProgress[id] = nil
        startedTasks.remove(task.taskIdentifier)
        forget(task)
        guard let error else { return }   // success is reported by the file hand-over
        if (error as? URLError)?.code == .cancelled { return }
        if let record = security.lastTrustFailure {
            relay.emit(BackgroundDownloadEvent(id: id, kind: .failed(.server(.tls(record.failure)))))
            return
        }
        let failure: BackgroundDownloadFailure
        if Self.isOutOfSpace(error) {
            failure = .outOfSpace(error.localizedDescription)
        } else if let urlError = error as? URLError {
            failure = .server(.network(underlying: urlError))
        } else {
            failure = .storage(error.localizedDescription)
        }
        relay.emit(BackgroundDownloadEvent(id: id, kind: .failed(failure)))
    }

    /// Held by the system until it has a network this transfer may use. Said
    /// so the app can tell "waiting for Wi-Fi" from "stuck".
    public func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let id = Self.identifier(of: task) else { return }
        relay.emit(BackgroundDownloadEvent(id: id, kind: .waiting))
    }

    private static func isOutOfSpace(_ error: any Error) -> Bool {
        TransferFailureClassifier.isOutOfSpace(error)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        handover.deliver()
    }

    // MARK: The same security policy as every other request

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        security.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        security.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        security.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }
}
