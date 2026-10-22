import Foundation
import PleviDomain
import PleviTransport

/// What the phone and the watch say to each other.
enum WatchLink {
    /// Bumped when a payload changes shape. A watch running an older build
    /// than the phone ignores what it cannot read rather than guessing.
    static let version = 1

    /// The single key each payload travels under.
    enum Key {
        static let provisioning = "provisioning"
        static let secrets = "secrets"
        static let played = "played"
        static let needsLibrary = "needsLibrary"
        static let serverRemoved = "serverRemoved"
        static let needsProvisioning = "needsProvisioning"
        /// File-transfer metadata.
        static let storageID = "storageID"
        static let generatedAt = "generatedAt"
        static let trackCount = "trackCount"
    }

    /// Everything the watch needs to know about *which* library it is
    /// showing, and what has been put on lately. No secrets: those travel
    /// their own way and go straight into the Keychain.
    struct Provisioning: Codable, Sendable, Hashable {
        var version: Int = WatchLink.version
        /// Absent when the phone has no server set up, which is how the
        /// watch learns to go back to its waiting screen.
        var config: ServerConfig?
        /// Sent rather than re-derived.
        var storageID: ServerID?
        /// The identifier the Plex token was granted to. A watch that
        /// invented its own would be a different client as far as Plex is
        /// concerned, and the token would not be honoured.
        var plexClientIdentifier: String?
        /// What was put on lately, newest first, as the phone knows it.
        var playLog: [PlayedEntry] = []
        /// When the phone last sent the library, so the watch can say
        /// something truthful in Settings.
        var librarySentAt: Date?
        /// Changes whenever the phone means "send this again whether or not it differs".
        var nonce: String?
    }

    /// The sign-in.
    struct Secrets: Codable, Sendable, Hashable {
        var version: Int = WatchLink.version
        var serverID: ServerID
        /// `SubsonicCredentials.encoded()` — kept as opaque bytes so this
        /// file does not have to import the Subsonic provider.
        var subsonicCredentials: Data?
        var plexToken: String?
        var headerValues: [String: String] = [:]
        /// A JSON-encoded `ProxySession`.
        var proxySession: Data?

        /// Nothing to store. Sent anyway when a server is removed, so the
        /// watch clears what it holds.
        var isEmpty: Bool {
            subsonicCredentials == nil && plexToken == nil
                && headerValues.isEmpty && proxySession == nil
        }
    }

    /// The watch saying it has been told nothing at all: no server, no sign-in.
    struct NeedsProvisioning: Codable, Sendable, Hashable {
        var version: Int = WatchLink.version
    }

    /// The watch saying it has no copy of a library it has been told about.
    struct NeedsLibrary: Codable, Sendable, Hashable {
        var version: Int = WatchLink.version
        var storageID: ServerID
    }

    /// The phone saying a server has been removed, and which libraries of it the watch may delete.
    struct ServerRemoved: Codable, Sendable, Hashable {
        var version: Int = WatchLink.version
        var serverID: ServerID
        /// Every storage identity the server ever filed libraries under.
        var storageIDs: [ServerID]
    }

    /// Something the watch put on, on its way to the phone's own shelf.
    struct Played: Codable, Sendable, Hashable {
        var version: Int = WatchLink.version
        var source: PlayedSource
        var playedAt: Date
    }

    /// Wraps a payload as the one-key dictionary the session carries.
    static func packed<Payload: Encodable>(_ payload: Payload, under key: String) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return [key: data]
    }

    /// Reads one back, or nil when this build does not understand it.
    static func unpacked<Payload: Decodable>(
        _ type: Payload.Type,
        from message: [String: Any],
        under key: String
    ) -> Payload? {
        guard let data = message[key] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
