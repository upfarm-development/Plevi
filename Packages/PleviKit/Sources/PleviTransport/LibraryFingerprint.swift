import Foundation
import CryptoKit
import PleviDomain

/// A name for "this library" that survives a reinstall.
public enum LibraryFingerprint {
    public static func of(config: ServerConfig, username: String?) -> String? {
        switch config.kind {
        case .plex:
            guard let library = config.library, !library.key.isEmpty else { return nil }
            // Older entries carry no machine identifier; the address says
            // which server it was, as it does for Subsonic.
            let server = library.machineIdentifier.isEmpty ? origin(of: config) : library.machineIdentifier
            guard let server else { return nil }
            return hash("plex", server, library.key)
        case .subsonic:
            guard let origin = origin(of: config) else { return nil }
            return hash("subsonic", origin, username ?? "")
        }
    }

    private static func origin(of config: ServerConfig) -> String? {
        // The address reachable from anywhere is the one that stays the
        // same between a home network and away from it.
        let url = config.addresses.remote ?? config.addresses.preferred
        guard let origin = URLOrigin(url: url) else { return nil }
        return "\(origin.scheme)://\(origin.host):\(origin.port)"
    }

    private static func hash(_ parts: String...) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
