import Foundation

/// Why authentication failed, mapped from provider-native error codes.
public enum AuthFailure: Hashable, Sendable {
    case wrongCredentials
    case tokenAuthUnsupported
    case methodUnsupported
    case conflictingMethods
    case invalidAPIKey
}

/// Why TLS trust could not be established. Fingerprints are lowercase hex
/// SHA-256 of the certificate's DER encoding, colon-separated, suitable for
/// showing to the user.
public enum TLSFailure: Hashable, Sendable {
    case certificateNotTrusted(fingerprintSHA256: String?)
    case pinMismatch(expected: String, actual: String?)
    case clientCertificateRejected
}

/// The typed error surface of every provider. View models translate these to
/// actionable user-facing messages; raw server errors never reach the UI.
public enum ProviderError: Error, Hashable, Sendable {
    case notAuthenticated(AuthFailure)
    case notAuthorized
    case notFound
    case missingParameter(name: String)
    case incompatibleServer(details: String?)
    case serverError(code: Int?, message: String?, helpURL: URL?)
    case malformedResponse(details: String)
    /// A login page or an auth wall answered instead of the API: an SSO proxy
    /// in front of the server wants a browser session before it will let the
    /// request through. Carries the URL whose login page should be opened.
    case proxySignInRequired(url: URL)
    case network(underlying: URLError)
    case tls(TLSFailure)
    /// The operation needs capabilities this server does not have.
    case unsupportedOperation(needs: ServerCapabilities)
    /// Server-side state changed underneath a mutation (e.g. a playlist was
    /// edited elsewhere between fetch and update). Safe to retry after
    /// refetching.
    case conflict(details: String)
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated(let failure):
            switch failure {
            case .wrongCredentials:
                return String(localized: "Wrong username or password.")
            case .tokenAuthUnsupported:
                return String(localized: "This server does not accept token authentication for your account. Check the server's LDAP settings.")
            case .methodUnsupported, .conflictingMethods:
                return String(localized: "The server rejected the sign-in method. Try updating the server or re-adding it here.")
            case .invalidAPIKey:
                return String(localized: "The API key was rejected. Generate a new key on the server and update this connection.")
            }
        case .proxySignInRequired:
            return "This server sits behind a sign-in page. Sign in to continue."
        case .notAuthorized:
            return String(localized: "Your account is not allowed to do that on this server.")
        case .notFound:
            return String(localized: "The server could not find the requested item. It may have been removed from the library.")
        case .missingParameter(let name):
            return String(localized: "The server rejected the request (\(name)).")
        case .incompatibleServer(let details):
            return String(localized: "The server version is not compatible.\(details.map { " \($0)" } ?? "")")
        case .serverError(_, let message, _):
            return message ?? String(localized: "The server reported an error.")
        case .malformedResponse(let details):
            // The details are shown, not hidden: an unreadable response is a
            // bug report waiting to happen, and the reader is the only one who
            // can pass it on.
            return String(localized: "The server sent a response this app could not read. Check that the URL points at a music server, not a login page.\(details.isEmpty ? "" : " (\(details))")")
        case .network(let underlying):
            return underlying.localizedDescription
        case .tls(let failure):
            switch failure {
            case .certificateNotTrusted:
                return String(localized: "The server's certificate is not trusted — tap to view its fingerprint.")
            case .pinMismatch:
                return String(localized: "The server's certificate changed since you approved it. Verify the new fingerprint before continuing.")
            case .clientCertificateRejected:
                return String(localized: "The server rejected this device's client certificate.")
            }
        case .unsupportedOperation:
            return String(localized: "This server does not support that feature.")
        case .conflict:
            return String(localized: "This item changed on the server. Refresh and try again.")
        }
    }
}

public extension ProviderError {
    /// The same sentence, with the number that names it.
    var diagnosticDescription: String {
        let said = errorDescription ?? String(localized: "Something went wrong.")
        guard case .network(let underlying) = self else { return said }
        return "\(said) (\(underlying.code.rawValue))"
    }

    /// Whether the connection itself failed, as opposed to the server answering something
    /// unwelcome.
    var isTransportFailure: Bool {
        switch self {
        case .network, .tls: true
        default: false
        }
    }

    /// Whether this is the network flinching rather than an answer.
    var isWorthRetrying: Bool {
        // A gateway that could not reach the server, or gave up waiting for it (nginx, Cloudflare,
        // a Plex relay restarting): the server has not said anything yet, so this is a blip like a
        // dropped connection.
        if case let .serverError(code, _, _) = self {
            return code == 502 || code == 503 || code == 504
        }
        guard case let .network(underlying) = self else { return false }
        return switch underlying.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
             .resourceUnavailable, .secureConnectionFailed:
            true
        default:
            false
        }
    }

    /// Whether this means the thing asked for is not there any more, as opposed to the server being
    /// unreachable or unhappy.
    var meansNotFound: Bool {
        switch self {
        case .notFound:
            true
        case .serverError(let code, _, _):
            code == 404
        default:
            false
        }
    }
}
