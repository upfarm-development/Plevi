import Foundation
import Testing
@testable import PleviPlexProvider

@Suite struct PlexIdentityTests {
    private let identity = PlexIdentity(
        clientIdentifier: "1111-2222",
        version: "0.1.0",
        platformVersion: "26.0",
        deviceName: "Alice's iPhone"
    )

    @Test func sendsTheHeadersPlexIdentifiesADeviceBy() {
        let headers = identity.headers()
        #expect(headers["X-Plex-Client-Identifier"] == "1111-2222")
        #expect(headers["X-Plex-Product"] == "Plevi")
        #expect(headers["X-Plex-Device-Name"] == "Alice's iPhone")
        #expect(headers["Accept"] == "application/json")
    }

    /// The token belongs in a header, not the query string, so it stays out
    /// of proxy access logs.
    @Test func carriesTheTokenAsAHeaderOnlyWhenThereIsOne() {
        #expect(identity.headers()["X-Plex-Token"] == nil)
        #expect(identity.headers(token: "")["X-Plex-Token"] == nil)
        #expect(identity.headers(token: "abc")["X-Plex-Token"] == "abc")
    }

    /// Plex reads the sign-in parameters from the fragment, not the query.
    @Test func buildsTheSignInURLWithItsParametersInTheFragment() throws {
        let pin = PlexPin(id: 42, code: "ABCD")
        let url = try #require(PlexAuth.signInURL(pin: pin, identity: identity))
        #expect(url.absoluteString.hasPrefix("https://app.plex.tv/auth#?"))
        let fragment = try #require(url.fragment(percentEncoded: false))
        #expect(fragment.contains("code=ABCD"))
        #expect(fragment.contains("clientID=1111-2222"))
        #expect(url.query() == nil)
    }

    @Test func aPinWithNoStatedExpiryNeverLooksExpired() {
        #expect(!PlexPin(id: 1, code: "A").isExpired())
    }

    @Test func anExpiredPinIsRecognised() {
        let pin = PlexPin(id: 1, code: "A", expiresAt: Date(timeIntervalSinceNow: -1))
        #expect(pin.isExpired())
    }
}

@Suite struct PlexDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Plex writes booleans as 0/1 more often than as booleans.
    @Test func readsPlexBooleansHoweverTheyAreWritten() throws {
        struct Box: Decodable { @PlexBool var flag: Bool }
        #expect(try decode(Box.self, #"{"flag": 1}"#).flag)
        #expect(try !decode(Box.self, #"{"flag": 0}"#).flag)
        #expect(try decode(Box.self, #"{"flag": true}"#).flag)
        #expect(try decode(Box.self, #"{"flag": "1"}"#).flag)
        #expect(try !decode(Box.self, #"{"flag": "no"}"#).flag)
    }

    @Test func readsAPinBeforeAndAfterItIsClaimed() throws {
        let pending = try decode(PlexPinDTO.self, #"{"id": 7, "code": "WXYZ", "authToken": null}"#)
        #expect(pending.id == 7)
        #expect(pending.authToken == nil)

        let claimed = try decode(PlexPinDTO.self, #"{"id": 7, "code": "WXYZ", "authToken": "tok"}"#)
        #expect(claimed.authToken == "tok")
    }

    @Test func readsTheHomeUserPicker() throws {
        let json = """
        {"users": [
          {"id": 1, "title": "Alice", "username": "alice", "admin": 1, "protected": 0, "restricted": 0},
          {"id": 2, "title": "Kids", "username": "", "admin": 0, "protected": 1, "restricted": 1,
           "thumb": "https://plex.tv/users/abc/avatar"}
        ]}
        """
        let users = try decode(PlexHomeUsersDTO.self, json).users.map(\.domain)
        #expect(users.count == 2)
        #expect(users[0].title == "Alice")
        #expect(users[0].isAdmin)
        #expect(!users[0].isProtected)
        // An empty username is not a username.
        #expect(users[1].username == nil)
        #expect(users[1].isProtected)
        #expect(users[1].isRestricted)
        #expect(users[1].thumb != nil)
    }

    @Test func keepsOnlyMediaServersFromTheResourceList() throws {
        let json = """
        [
          {"name": "Tower", "clientIdentifier": "aaa", "provides": "server", "owned": 1, "connections": []},
          {"name": "Phone", "clientIdentifier": "bbb", "provides": "client,player", "owned": 1, "connections": []}
        ]
        """
        let resources = try decode([PlexResourceDTO].self, json)
        #expect(resources.filter(\.isMediaServer).map(\.name) == ["Tower"])
    }

    /// Local first, then a direct remote address, and Plex's relay last —
    /// the relay reaches anywhere but is bandwidth-limited.
    @Test func ordersConnectionsLocalThenDirectThenRelay() throws {
        let json = """
        {"name": "Tower", "clientIdentifier": "aaa", "provides": "server", "owned": 1, "connections": [
          {"uri": "https://relay.plex.direct", "local": 0, "relay": 1, "IPv6": 0},
          {"uri": "https://remote.plex.direct", "local": 0, "relay": 0, "IPv6": 0},
          {"uri": "https://192-168-1-9.plex.direct:32400", "local": 1, "relay": 0, "IPv6": 0}
        ]}
        """
        let resource = try decode(PlexResourceDTO.self, json).domain
        let hosts = resource.connectionsInPreferenceOrder.map { $0.uri.host() ?? "" }
        #expect(hosts.first?.contains("192-168-1-9") == true)
        #expect(hosts.last?.contains("relay") == true)
        #expect(resource.localURL?.absoluteString.contains("192-168-1-9") == true)
        #expect(resource.remoteURL?.absoluteString.contains("remote") == true)
    }

    @Test func aServerWithNoLocalAddressStillOffersARemoteOne() throws {
        let json = """
        {"name": "Tower", "clientIdentifier": "aaa", "provides": "server", "owned": 1, "connections": [
          {"uri": "https://remote.plex.direct", "local": 0, "relay": 0, "IPv6": 0}
        ]}
        """
        let resource = try decode(PlexResourceDTO.self, json).domain
        #expect(resource.localURL == nil)
        #expect(resource.remoteURL != nil)
    }

    @Test func readsLibrarySectionsAndTellsMusicFromTheRest() throws {
        let json = """
        {"MediaContainer": {"size": 3, "Directory": [
          {"key": "1", "title": "Movies", "type": "movie", "uuid": "u1"},
          {"key": "2", "title": "Music", "type": "artist", "uuid": "u2"},
          {"key": "3", "title": "Test Folder", "type": "artist", "uuid": "u3"}
        ]}}
        """
        let sections = try decode(PlexSectionsResponse.self, json).sections
        #expect(sections.count == 3)
        let music = sections.filter(\.isMusic)
        #expect(music.map(\.title) == ["Music", "Test Folder"])
        #expect(music.first?.key == "2")
    }

    @Test func survivesAServerWithNoLibrariesAtAll() throws {
        let sections = try decode(PlexSectionsResponse.self, #"{"MediaContainer": {"size": 0}}"#).sections
        #expect(sections.isEmpty)
    }
}
