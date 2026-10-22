import Foundation
import PleviDomain
import PleviKeychain

/// Where a server's secrets live in the Keychain.
enum ServerSecretKeys {
    static func credentials(_ id: ServerID) -> SecretKey {
        SecretKey(account: "\(id.rawValue.uuidString)/subsonic-credentials")
    }

    static func header(_ id: ServerID, name: String) -> SecretKey {
        SecretKey(account: "\(id.rawValue.uuidString)/header.\(name)")
    }

    static func plexToken(_ id: ServerID) -> SecretKey {
        SecretKey(account: "\(id.rawValue.uuidString)/plex-token")
    }

    static func proxySession(_ id: ServerID) -> SecretKey {
        SecretKey(account: "\(id.rawValue.uuidString)/proxy-session")
    }

    /// One JSON blob of `PleviRemote.PeerPin`s for this server config.
    /// Removing the server wipes it for free,
    /// the same as every other key here.
    static func remotePeers(_ id: ServerID) -> SecretKey {
        SecretKey(account: "\(id.rawValue.uuidString)/remote-peers")
    }

    /// One JSON blob of `PleviRemote.CredentialHealth` for this server config:
    /// whether, and when, this device's
    /// credentials for it were last accepted directly.
    static func remoteCredentialHealth(_ id: ServerID) -> SecretKey {
        SecretKey(account: "\(id.rawValue.uuidString)/remote-credential-health")
    }

    /// Everything belonging to one server, for wiping it.
    static func prefix(_ id: ServerID) -> String {
        "\(id.rawValue.uuidString)/"
    }
}
