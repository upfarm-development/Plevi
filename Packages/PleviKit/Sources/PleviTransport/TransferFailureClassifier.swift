import Foundation
import PleviDomain

/// What to do about a transfer or a preparation that did not work.
public enum FailureDisposition: Sendable, Equatable {
    /// Nothing about asking again will help. The song is failed, and says why.
    case terminal
    /// The server or the link had a moment. Try again, after a pause, and
    /// count the attempt.
    case retryable
    /// There is no usable network right now. The song stays where it is, waits
    /// for one, and is not charged an attempt: it did nothing wrong.
    case waitForNetwork
    /// The phone or watch is out of room. Every other song would fail the same
    /// way, so the queue stops, once, with one message.
    case storageFull
    /// A sign-in page is in the way. Every other song would hit it too, so the
    /// queue stops and the user is asked to sign in, once.
    case proxyWall
}

public enum TransferFailureClassifier {
    /// A transfer that the system reported as failed.
    public static func disposition(
        for failure: BackgroundDownloadFailure,
        isConversion: Bool
    ) -> FailureDisposition {
        switch failure {
        case .outOfSpace:
            return .storageFull
        case .storage:
            return .terminal
        case .foreignHost:
            return .proxyWall
        case .notAudio(let reason):
            if reason.looksLikeAWebPage { return .proxyWall }
            // A conversion the server did not finish is worth another go; an
            // original that arrived as an error or empty is the server's answer.
            return isConversion ? .retryable : .terminal
        case .server(let error):
            return disposition(for: error, isConversion: isConversion, preparing: false)
        }
    }

    /// The error from asking the server how to fetch a song, before any
    /// transfer exists.
    public static func disposition(
        forPreparation error: any Error,
        isConversion: Bool = false
    ) -> FailureDisposition {
        if let urlError = error as? URLError {
            return disposition(forURLError: urlError, preparing: true)
        }
        if let provider = error as? ProviderError {
            return disposition(for: provider, isConversion: isConversion, preparing: true)
        }
        // Cancellation is somebody else's decision; anything unrecognised is
        // treated as the server having a moment, which is bounded by the
        // attempt count.
        return .retryable
    }

    private static func disposition(
        for error: ProviderError,
        isConversion: Bool,
        preparing: Bool
    ) -> FailureDisposition {
        switch error {
        case .network(let underlying):
            return disposition(forURLError: underlying, preparing: preparing)
        case .tls:
            return .terminal
        case .proxySignInRequired:
            return .proxyWall
        case .notAuthenticated, .notAuthorized, .missingParameter, .incompatibleServer,
             .unsupportedOperation:
            return .terminal
        case .notFound:
            return isConversion ? .retryable : .terminal
        case .malformedResponse, .conflict:
            return isConversion ? .retryable : .terminal
        case .serverError(let code, _, _):
            guard let code else { return .retryable }
            switch code {
            case 401:
                return .terminal
            case 403, 404:
                return isConversion ? .retryable : .terminal
            case 408, 425, 429, 500...599:
                return .retryable
            case 400..<500:
                return isConversion ? .retryable : .terminal
            default:
                return .retryable
            }
        }
    }

    private static func disposition(forURLError error: URLError, preparing: Bool) -> FailureDisposition {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .waitForNetwork
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed:
            // Asked before any transfer exists, these say the same thing as
            // "no network": nothing was wrong with the song, and charging an
            // attempt for it lets a bad ten seconds fail a queue.
            return preparing ? .waitForNetwork : .retryable
        case .cannotWriteToFile, .cannotCreateFile, .cannotMoveFile, .cannotRemoveFile:
            return .storageFull
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .terminal
        case .userAuthenticationRequired:
            return .terminal
        case .cancelled:
            return .terminal
        default:
            return .retryable
        }
    }

    /// Whether an error is the phone being out of room, however it is spelled.
    public static func isOutOfSpace(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            // NSFileWriteOutOfSpaceError
            if nsError.code == 640 { return true }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if let urlError = error as? URLError,
           urlError.code == .cannotWriteToFile || urlError.code == .cannotCreateFile {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpace(underlying)
        }
        return false
    }
}
