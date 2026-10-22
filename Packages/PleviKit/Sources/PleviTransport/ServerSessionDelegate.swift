import Foundation
import Security
import CryptoKit
import Synchronization
import PleviDomain

/// Supplies the mTLS client identity for servers that require one.
/// The real implementation (PKCS#12 import, Keychain-backed) arrives with the
/// server setup flow; previews and tests use `NoClientIdentity`.
public protocol ClientIdentityProviding: Sendable {
    func clientIdentity() throws -> SecIdentity?
}

public struct NoClientIdentity: ClientIdentityProviding {
    public init() {}
    public func clientIdentity() throws -> SecIdentity? { nil }
}

/// What the delegate saw when it last rejected a server certificate. The
/// leaf hash lets the setup flow offer "pin exactly this certificate" after
/// showing the user its fingerprint.
public struct TrustFailureRecord: Sendable {
    public let failure: TLSFailure
    public let leafSHA256: Data?
}

/// URLSession delegate enforcing the per-server security policy.
public final class ServerSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// What the delegate holds a connection to.
    private struct Policy: Sendable {
        var pins: [PinnedCertificate]
        var allowedOrigins: Set<URLOrigin>
        var identityProvider: any ClientIdentityProviding
    }

    private let policy: Mutex<Policy>
    private let failureRecord = Mutex<TrustFailureRecord?>(nil)
    private let refusedRedirect = Mutex<URL?>(nil)

    public init(
        pins: [PinnedCertificate],
        allowedOrigins: Set<URLOrigin>,
        identityProvider: any ClientIdentityProviding = NoClientIdentity()
    ) {
        self.policy = Mutex(Policy(
            pins: pins,
            allowedOrigins: allowedOrigins,
            identityProvider: identityProvider
        ))
    }

    /// Replaces the policy for challenges and redirects from now on.
    public func update(
        pins: [PinnedCertificate],
        allowedOrigins: Set<URLOrigin>,
        identityProvider: any ClientIdentityProviding
    ) {
        let pinsChanged = policy.withLock { policy -> Bool in
            let changed = policy.pins != pins
            policy = Policy(pins: pins, allowedOrigins: allowedOrigins, identityProvider: identityProvider)
            return changed
        }
        if pinsChanged { clearTrustFailure() }
    }

    /// The origins a redirect may land on.
    var currentAllowedOrigins: Set<URLOrigin> { policy.withLock { $0.allowedOrigins } }
    var currentPins: [PinnedCertificate] { policy.withLock { $0.pins } }

    /// The most recent trust rejection, so transport errors (which surface as
    /// a generic `URLError`) can be translated into a typed `ProviderError.tls`.
    public var lastTrustFailure: TrustFailureRecord? {
        failureRecord.withLock { $0 }
    }

    /// Where the last refused redirect was pointing, when it left the host entirely.
    public var lastCrossHostRedirect: URL? {
        refusedRedirect.withLock { $0 }
    }

    public func clearRefusedRedirect() {
        refusedRedirect.withLock { $0 = nil }
    }

    /// Where a response that redirected off the host was pointing, judged from the response alone.
    public static func crossHostRedirect(in response: HTTPURLResponse, for requestURL: URL?) -> URL? {
        guard (300..<400).contains(response.statusCode),
              let requestURL,
              let location = response.value(forHTTPHeaderField: "Location"),
              let destination = URL(string: location, relativeTo: response.url ?? requestURL)?.absoluteURL,
              let destinationHost = destination.host()?.lowercased(),
              let sourceHost = requestURL.host()?.lowercased(),
              destinationHost != sourceHost
        else { return nil }
        return destination
    }

    private func recordRefusedRedirect(to destination: URL?, from source: URL?) {
        guard let destination,
              let destinationHost = destination.host()?.lowercased(),
              let sourceHost = source?.host()?.lowercased(),
              destinationHost != sourceHost
        else { return }
        refusedRedirect.withLock { $0 = destination }
    }

    public func clearTrustFailure() {
        failureRecord.withLock { $0 = nil }
    }

    // MARK: Trust and client-certificate challenges

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let host = space.host.lowercased()
            let pin = policy.withLock { policy in
                policy.pins.first { $0.origin.host == host && $0.origin.port == space.port }?.sha256
            }
            switch ServerTrustEvaluator.evaluate(trust, pin: pin) {
            case .accept:
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .reject(let failure):
                let leaf = ServerTrustEvaluator.leafCertificateDER(of: trust)
                let record = TrustFailureRecord(
                    failure: failure,
                    leafSHA256: leaf.map { Data(SHA256.hash(data: $0)) }
                )
                failureRecord.withLock { $0 = record }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        case NSURLAuthenticationMethodClientCertificate:
            let provider = policy.withLock { $0.identityProvider }
            if let identity = try? provider.clientIdentity() {
                completionHandler(.useCredential, URLCredential(
                    identity: identity,
                    certificates: nil,
                    persistence: .forSession
                ))
            } else {
                // No identity configured: continue without one and let the
                // server decide, producing a clear HTTP-level error.
                completionHandler(.performDefaultHandling, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: Redirect policy

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = policy.withLock { $0.allowedOrigins }
        if let url = request.url,
           let origin = URLOrigin(url: url),
           allowed.contains(origin) {
            completionHandler(request)
        } else {
            // Refuse cross-origin redirects: the redirect response is delivered as the result
            // instead, and no credentials leave the configured origins.
            recordRefusedRedirect(to: request.url, from: task.originalRequest?.url)
            completionHandler(nil)
        }
    }
}
