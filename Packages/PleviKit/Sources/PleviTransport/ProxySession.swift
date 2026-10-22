import Foundation
import Synchronization

/// A browser session captured from an SSO login page sitting in front of a server — Pangolin,
/// Authelia, Cloudflare Access with a login form, and so on.
public struct ProxySession: Codable, Hashable, Sendable {
    public struct Cookie: Codable, Hashable, Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let origin: URLOrigin
    public let cookies: [Cookie]
    public let capturedAt: Date
    /// The earliest expiry among the captured cookies, when any of them said.
    public let expiresAt: Date?

    public init(origin: URLOrigin, cookies: [Cookie], capturedAt: Date = .now, expiresAt: Date? = nil) {
        self.origin = origin
        self.cookies = cookies
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
    }

    /// The `Cookie` header value, in the order the browser held them.
    public var headerValue: String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public var isEmpty: Bool { cookies.isEmpty }

    /// Treated as expired a little early: a request that sets off mid-flight
    /// with a cookie about to lapse comes back as an HTML login page, which
    /// costs the user a failed action to discover.
    public static let expiryMargin: TimeInterval = 60

    public func isValid(at date: Date = .now) -> Bool {
        guard !cookies.isEmpty else { return false }
        guard let expiresAt else { return true }
        return date < expiresAt.addingTimeInterval(-Self.expiryMargin)
    }

    /// Whether this session may be attached to `url` — same origin, nothing
    /// broader. Scheme and port count, so a session for `https://host` is not
    /// offered to `http://host`.
    public func applies(to url: URL) -> Bool {
        origin.matches(url)
    }
}

/// Where the transport reads the current proxy session from.
public protocol ProxySessionSource: Sendable {
    func session(for url: URL) -> ProxySession?
}

public extension ProxySessionSource {
    /// Adds the proxy's session cookie to a request, but only for the exact origin it was captured
    /// from.
    func authenticating(_ request: URLRequest) -> URLRequest {
        guard let url = request.url,
              let session = session(for: url),
              !session.isEmpty
        else { return request }
        var authenticated = request
        authenticated.setValue(session.headerValue, forHTTPHeaderField: "Cookie")
        return authenticated
    }
}

/// The app's live holder for one server's proxy session.
public final class ProxySessionHolder: ProxySessionSource {
    private let stored: Mutex<ProxySession?>

    public init(_ session: ProxySession? = nil) {
        self.stored = Mutex(session)
    }

    public var current: ProxySession? {
        stored.withLock { $0 }
    }

    public func set(_ session: ProxySession?) {
        stored.withLock { $0 = session }
    }

    public func session(for url: URL) -> ProxySession? {
        stored.withLock { session in
            guard let session, session.applies(to: url), session.isValid() else { return nil }
            return session
        }
    }
}
