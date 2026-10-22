import Foundation
import Security
import CryptoKit
import PleviDomain

/// Outcome of evaluating a server's TLS certificate chain.
public enum TrustVerdict: Hashable, Sendable {
    case accept
    case reject(TLSFailure)
}

/// Pure trust-evaluation logic, kept free of URLSession so it is unit-testable
/// with fixture certificates.
public enum ServerTrustEvaluator {
    /// Lowercase colon-separated hex SHA-256 of a certificate's DER bytes —
    /// the exact string shown to the user when approving a certificate.
    public static func fingerprintSHA256(ofDER der: Data) -> String {
        formatFingerprint(Data(SHA256.hash(data: der)))
    }

    /// Formats an existing SHA-256 digest the same way.
    public static func formatFingerprint(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func leafCertificateDER(of trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// Evaluates a certificate chain against the pin for the origin being
    /// connected to. `pin` is nil when the user never approved a certificate
    /// for that origin, in which case ordinary system trust applies.
    public static func evaluate(_ trust: SecTrust, pin: Data?) -> TrustVerdict {
        guard let pin else {
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                return .accept
            }
            let fingerprint = leafCertificateDER(of: trust).map(fingerprintSHA256(ofDER:))
            return .reject(.certificateNotTrusted(fingerprintSHA256: fingerprint))
        }

        guard let der = leafCertificateDER(of: trust) else {
            return .reject(.certificateNotTrusted(fingerprintSHA256: nil))
        }
        let actual = Data(SHA256.hash(data: der))
        if actual == pin {
            // The user explicitly approved exactly this certificate for this origin; system
            // evaluation is intentionally not consulted, and any other certificate — even one the
            // system trusts — is rejected so a swapped cert can't go unnoticed.
            return .accept
        }
        return .reject(.pinMismatch(
            expected: formatFingerprint(pin),
            actual: formatFingerprint(actual)
        ))
    }
}
