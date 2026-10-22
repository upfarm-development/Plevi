import Foundation

/// Result of probing one address before any pin exists for it.
public enum TrustProbeResult: Sendable {
    /// Reachable and trusted (or plain HTTP on a private host).
    case trusted
    /// Reachable, but the certificate is not system-trusted; the setup flow
    /// shows `fingerprint` to the user and pins `sha256` on approval.
    case untrusted(fingerprint: String, sha256: Data)
    case unreachable(message: String)
}

/// Connects once to capture an address's certificate identity so the setup
/// flow can show a fingerprint for approval. Never sends credentials: the
/// probe request is a bare unauthenticated GET.
public enum TrustProber {
    public static func probe(_ url: URL, timeout: TimeInterval = 8) async -> TrustProbeResult {
        let origins: Set<URLOrigin> = URLOrigin(url: url).map { [$0] } ?? []
        let delegate = ServerSessionDelegate(pins: [], allowedOrigins: origins)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            // Any HTTP status is fine — only reachability and TLS matter here.
            _ = try await session.data(for: URLRequest(url: url))
            return .trusted
        } catch {
            if let record = delegate.lastTrustFailure, let sha = record.leafSHA256 {
                return .untrusted(
                    fingerprint: ServerTrustEvaluator.formatFingerprint(sha),
                    sha256: sha
                )
            }
            let message = (error as? URLError)?.localizedDescription ?? String(describing: error)
            return .unreachable(message: message)
        }
    }
}
