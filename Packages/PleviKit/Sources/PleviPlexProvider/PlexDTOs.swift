import Foundation

// Plex's JSON is what it is: `Int` where a `Bool` is meant, strings for numbers in places, and keys
// that differ between plex.tv and a server.

/// Plex writes booleans as 0/1, and occasionally as real booleans.
@propertyWrapper
public struct PlexBool: Hashable, Sendable, Decodable {
    public var wrappedValue: Bool

    public init(wrappedValue: Bool) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            wrappedValue = value
        } else if let value = try? container.decode(Int.self) {
            wrappedValue = value != 0
        } else if let value = try? container.decode(String.self) {
            wrappedValue = value == "1" || value.lowercased() == "true"
        } else {
            wrappedValue = false
        }
    }
}

/// Plex writes numbers as numbers, and sometimes as quoted strings.
@propertyWrapper
public struct PlexNumber<Value: LosslessStringConvertible & Decodable>: Decodable, Sendable
where Value: Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Value.self) {
            wrappedValue = value
        } else if let text = try? container.decode(String.self) {
            wrappedValue = Value(text)
        } else {
            wrappedValue = nil
        }
    }
}

extension KeyedDecodingContainer {
    /// Absent keys are absent values, not errors — the synthesised decoder
    /// asks for the wrapper itself, which is never optional.
    func decode<Value>(
        _ type: PlexNumber<Value>.Type,
        forKey key: Key
    ) throws -> PlexNumber<Value> {
        try decodeIfPresent(type, forKey: key) ?? PlexNumber<Value>(wrappedValue: nil)
    }

    func decode(_ type: PlexBool.Type, forKey key: Key) throws -> PlexBool {
        try decodeIfPresent(type, forKey: key) ?? PlexBool(wrappedValue: false)
    }
}

public struct PlexPinDTO: Decodable, Sendable {
    public let id: Int
    public let code: String
    public let authToken: String?
    public let expiresAt: String?
}

/// One account on the Plex Home — the profile picker at sign-in.
public struct PlexHomeUser: Hashable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let username: String?
    public let thumb: URL?
    /// Needs a PIN before it can be switched to.
    public let isProtected: Bool
    public let isAdmin: Bool
    public let isRestricted: Bool

    public init(
        id: Int,
        title: String,
        username: String? = nil,
        thumb: URL? = nil,
        isProtected: Bool = false,
        isAdmin: Bool = false,
        isRestricted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.thumb = thumb
        self.isProtected = isProtected
        self.isAdmin = isAdmin
        self.isRestricted = isRestricted
    }
}

struct PlexHomeUsersDTO: Decodable {
    let users: [UserDTO]

    struct UserDTO: Decodable {
        let id: Int
        let title: String
        let username: String?
        let thumb: String?
        @PlexBool var protected: Bool
        @PlexBool var admin: Bool
        @PlexBool var restricted: Bool

        var domain: PlexHomeUser {
            PlexHomeUser(
                id: id,
                title: title,
                username: username.flatMap { $0.isEmpty ? nil : $0 },
                thumb: thumb.flatMap(URL.init(string:)),
                isProtected: protected,
                isAdmin: admin,
                isRestricted: restricted
            )
        }
    }
}

/// The signed-in Plex user, from `/api/v2/user` — Remote Control's iCloud check needs a stable
/// per-profile identifier for its scope, and `uuid` is the answer for
/// that: the same…
public struct PlexUser: Hashable, Sendable {
    public let uuid: String

    public init(uuid: String) {
        self.uuid = uuid
    }
}

struct PlexUserDTO: Decodable {
    let uuid: String

    var domain: PlexUser { PlexUser(uuid: uuid) }
}

/// A server the account can reach, with the addresses to try in order.
public struct PlexResource: Hashable, Sendable, Identifiable {
    public var id: String { clientIdentifier }
    public let name: String
    public let clientIdentifier: String
    public let accessToken: String?
    public let owned: Bool
    public let connections: [Connection]

    public struct Connection: Hashable, Sendable {
        public let uri: URL
        public let isLocal: Bool
        public let isRelay: Bool

        public init(uri: URL, isLocal: Bool, isRelay: Bool) {
            self.uri = uri
            self.isLocal = isLocal
            self.isRelay = isRelay
        }

        /// What to call this address while waiting on it.
        public var label: String {
            if isLocal { return "local network" }
            return isRelay ? "Plex relay" : "remote address"
        }
    }

    public init(
        name: String,
        clientIdentifier: String,
        accessToken: String? = nil,
        owned: Bool = true,
        connections: [Connection] = []
    ) {
        self.name = name
        self.clientIdentifier = clientIdentifier
        self.accessToken = accessToken
        self.owned = owned
        self.connections = connections
    }

    /// Local addresses first, then direct remote ones, and Plex's relay last:
    /// the relay works from anywhere but is bandwidth-limited, so it is a
    /// fallback rather than a choice.
    public var connectionsInPreferenceOrder: [Connection] {
        connections.sorted { first, second in
            func rank(_ connection: Connection) -> Int {
                if connection.isLocal { return 0 }
                return connection.isRelay ? 2 : 1
            }
            return rank(first) < rank(second)
        }
    }

    public var localURL: URL? {
        connectionsInPreferenceOrder.first { $0.isLocal }?.uri
    }

    public var remoteURL: URL? {
        connectionsInPreferenceOrder.first { !$0.isLocal }?.uri
    }
}

struct PlexResourceDTO: Decodable {
    let name: String
    let clientIdentifier: String
    let accessToken: String?
    let provides: String?
    @PlexBool var owned: Bool
    let connections: [ConnectionDTO]?

    struct ConnectionDTO: Decodable {
        let uri: String
        let address: String?
        let port: Int?
        let protocolName: String?
        @PlexBool var local: Bool
        @PlexBool var relay: Bool
        @PlexBool var IPv6: Bool

        enum CodingKeys: String, CodingKey {
            case uri, address, port, local, relay, IPv6
            case protocolName = "protocol"
        }
    }

    /// Only servers, not players or controllers.
    var isMediaServer: Bool {
        provides?.split(separator: ",").contains("server") ?? false
    }

    var domain: PlexResource {
        PlexResource(
            name: name,
            clientIdentifier: clientIdentifier,
            accessToken: accessToken,
            owned: owned,
            connections: (connections ?? []).compactMap { connection in
                guard let url = URL(string: connection.uri) else { return nil }
                return PlexResource.Connection(
                    uri: url,
                    isLocal: connection.local,
                    isRelay: connection.relay
                )
            }
        )
    }
}

/// One library on a server. Only the music ones are offered.
public struct PlexLibrarySection: Hashable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String
    /// Plex's own word: "artist" is a music library, "movie" and "show" are not.
    public let type: String
    public let uuid: String?

    public init(key: String, title: String, type: String, uuid: String? = nil) {
        self.key = key
        self.title = title
        self.type = type
        self.uuid = uuid
    }

    public var isMusic: Bool { type == "artist" }
}

struct PlexSectionsResponse: Decodable {
    let mediaContainer: MediaContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }

    struct MediaContainer: Decodable {
        let directory: [DirectoryDTO]?

        enum CodingKeys: String, CodingKey {
            case directory = "Directory"
        }
    }

    struct DirectoryDTO: Decodable {
        let key: String
        let title: String
        let type: String
        let uuid: String?

        var domain: PlexLibrarySection {
            PlexLibrarySection(key: key, title: title, type: type, uuid: uuid)
        }
    }

    var sections: [PlexLibrarySection] {
        (mediaContainer.directory ?? []).map(\.domain)
    }
}
