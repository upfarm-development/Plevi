import Foundation
import Synchronization
import PleviDomain

/// How providers and caches talk HTTP.
public final class NetworkSuspension: Sendable {
    private let flag = Mutex<Bool>(false)

    public init(isSuspended: Bool = false) {
        flag.withLock { $0 = isSuspended }
    }

    public var isSuspended: Bool {
        get { flag.withLock { $0 } }
        set { flag.withLock { $0 = newValue } }
    }
}

/// Lets a `URLSession` go without ever handing a request to one that has.
final class SessionGate: Sendable {
    private struct State {
        var active = 0
        var closing = false
        var invalidated = false
    }
    private let state = Mutex(State())

    /// Whether a request may start. Every `true` must be matched by `leave`.
    func enter() -> Bool {
        state.withLock { state in
            guard !state.closing else { return false }
            state.active += 1
            return true
        }
    }

    func leave(_ session: URLSession) {
        let invalidate = state.withLock { state -> Bool in
            state.active -= 1
            guard state.closing, state.active == 0, !state.invalidated else { return false }
            state.invalidated = true
            return true
        }
        if invalidate { session.finishTasksAndInvalidate() }
    }

    /// Refuses new requests from now on, and lets the session go when the ones
    /// running have finished.
    func close(_ session: URLSession) {
        let invalidate = state.withLock { state -> Bool in
            state.closing = true
            guard state.active == 0, !state.invalidated else { return false }
            state.invalidated = true
            return true
        }
        if invalidate { session.finishTasksAndInvalidate() }
    }

    var isClosed: Bool { state.withLock { $0.closing } }
}

public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Whether `request` would leave with no proxy session cookie attached — the "direct" case, the other half of which (whether the caller itself added a custom header)
    /// only the caller knows.
    func isDirect(_ request: URLRequest) -> Bool

    /// Streams a response to a file, reporting bytes as they arrive.
    func download(
        _ request: URLRequest,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws
}

public extension HTTPTransport {
    func isDirect(_ request: URLRequest) -> Bool { true }

    /// Buffered fallback for transports with nothing better. Correct, but
    /// holds the whole response, so real transports override it.
    func download(
        _ request: URLRequest,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws {
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.serverError(
                code: response.statusCode,
                message: "HTTP \(response.statusCode)",
                helpURL: nil
            )
        }
        try data.write(to: destination, options: .atomic)
        onProgress?(Int64(data.count), Int64(data.count))
    }
}

/// The real transport for one configured server: an isolated URLSession wired to
/// `ServerSessionDelegate` (per-origin trust, mTLS, redirect refusal), with URLErrors translated
/// into typed `ProviderError`s — including turning the generic failure…
public struct ServerHTTPTransport: HTTPTransport {
    private let session: URLSession
    private let delegate: ServerSessionDelegate
    private let gate = SessionGate()

    /// Supplies the SSO cookie for a proxy sitting in front of the server, if
    /// one has been captured. Read per request, since it is captured long
    /// after this transport was built and replaced whenever it lapses.
    private let proxySessions: (any ProxySessionSource)?
    /// Set while the app is offline by choice; every request is refused
    /// before it is made.
    private let suspension: NetworkSuspension?

    /// `timeout` is the per-request deadline.
    public init(
        config: ServerConfig,
        identityProvider: any ClientIdentityProviding = NoClientIdentity(),
        timeout: TimeInterval = 30,
        resourceTimeout: TimeInterval? = nil,
        proxySessions: (any ProxySessionSource)? = nil,
        suspension: NetworkSuspension? = nil
    ) {
        self.proxySessions = proxySessions
        self.suspension = suspension
        self.delegate = ServerSessionDelegate(
            pins: config.pinnedCertificates,
            allowedOrigins: config.allowedOrigins,
            identityProvider: identityProvider
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout ?? timeout
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if suspension?.isSuspended == true {
            throw ProviderError.network(underlying: URLError(.notConnectedToInternet))
        }
        guard gate.enter() else { throw ProviderError.network(underlying: URLError(.cancelled)) }
        defer { gate.leave(session) }
        delegate.clearTrustFailure()
        do {
            let (data, response) = try await session.data(for: authenticatingProxy(request))
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.malformedResponse(details: "non-HTTP response")
            }
            // A redirect off the host that we declined to follow: an SSO proxy sending the request
            // to an identity provider.
            if ServerSessionDelegate.crossHostRedirect(in: http, for: request.url) != nil,
               let url = request.url {
                throw ProviderError.proxySignInRequired(url: url)
            }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError {
            if let record = delegate.lastTrustFailure {
                throw ProviderError.tls(record.failure)
            }
            throw ProviderError.network(underlying: error)
        }
    }

    /// Lets the session go once the requests already in flight have finished.
    public func close() {
        gate.close(session)
    }

    /// Whether `authenticatingProxy(_:)` would find a session to attach —
    /// the same lookup `perform` makes when it builds the request, exposed
    /// so a caller that already has the plain request can ask in advance.
    public func isDirect(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return true }
        return proxySessions?.session(for: url) == nil
    }
}

extension ServerHTTPTransport {
    /// Written straight to disk as the bytes arrive, so a large file never
    /// sits in memory in its entirety.
    public func download(
        _ request: URLRequest,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws {
        if suspension?.isSuspended == true {
            throw ProviderError.network(underlying: URLError(.notConnectedToInternet))
        }
        guard gate.enter() else { throw ProviderError.network(underlying: URLError(.cancelled)) }
        defer { gate.leave(session) }
        delegate.clearTrustFailure()
        delegate.clearRefusedRedirect()
        do {
            let (bytes, response) = try await session.bytes(for: authenticatingProxy(request))
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.malformedResponse(details: "non-HTTP response")
            }
            // The same reading `perform` gives a redirect off the host that was declined: an SSO
            // proxy sending the request to its identity provider.
            if (300..<400).contains(http.statusCode), delegate.lastCrossHostRedirect != nil,
               let url = request.url {
                throw ProviderError.proxySignInRequired(url: url)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ProviderError.serverError(
                    code: http.statusCode,
                    message: "HTTP \(http.statusCode)",
                    helpURL: nil
                )
            }
            let expected: Int64? = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            // A 2xx is not yet a song. A label that can never be audio is
            // refused before a byte is written; what the body turns out to be
            // is checked once it is all here, below.
            if AudioResponseCheck.isTextualContentType(http.value(forHTTPHeaderField: "Content-Type")),
               let url = request.url {
                throw Self.notAudio(
                    .textual(contentType: http.value(forHTTPHeaderField: "Content-Type") ?? ""),
                    at: url
                )
            }
            // Small steps when nothing says how long the body is: that is a conversion being made
            // as it goes, whose bytes arrive at the pace of its bit rate, and a quarter of a
            // megabyte is most of a minute of a 128 kbps stream — a start gate sized in…
            let chunk = expected == nil ? Self.unknownLengthChunk : Self.writeChunk

            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(chunk)
            var written: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= chunk {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress?(written, expected)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            onProgress?(written, expected)
            try? handle.close()
            // What arrived, against what it was said to be: an error envelope
            // or a sign-in page sent as a 200, or nothing at all.
            if let reason = AudioResponseCheck.verdict(forFileAt: destination, response: http),
               let url = request.url {
                try? FileManager.default.removeItem(at: destination)
                throw Self.notAudio(reason, at: url)
            }
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError {
            if let record = delegate.lastTrustFailure {
                throw ProviderError.tls(record.failure)
            }
            throw ProviderError.network(underlying: error)
        }
    }

    private static let writeChunk = 256 * 1024
    private static let unknownLengthChunk = 32 * 1024

    /// How a response that is not a song is reported: a page in the way is the
    /// sign-in wall the rest of the app already knows how to show, anything
    /// else is an answer that is not what was asked for.
    static func notAudio(_ reason: NotAudioReason, at url: URL) -> ProviderError {
        reason.looksLikeAWebPage
            ? .proxySignInRequired(url: url)
            : .malformedResponse(details: reason.message)
    }

    /// `httpShouldSetCookies` stays off and the session's own cookie storage
    /// stays unused: `ProxySessionSource.authenticating` is the single place
    /// a cookie is ever attached, and it is one origin wide.
    private func authenticatingProxy(_ request: URLRequest) -> URLRequest {
        proxySessions?.authenticating(request) ?? request
    }
}
