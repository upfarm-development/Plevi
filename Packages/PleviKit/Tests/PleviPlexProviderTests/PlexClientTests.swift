import Foundation
import Synchronization
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

/// Answers canned responses and records what was asked, so the client's
/// requests can be checked without touching plex.tv.
private actor FakePlexTransport: HTTPTransport {
    struct Reply {
        var status: Int = 200
        var json: String
        /// Stands in for an address that is listed but not reachable from
        /// here: it does not refuse, it simply takes forever.
        var delay: Duration = .zero
    }

    private var replies: [String: Reply]
    private(set) var requests: [URLRequest] = []

    /// Which replies were still being served when each one was asked for.
    private var outstanding: [String: Int] = [:]
    private var overlaps: [String: Set<String>] = [:]

    init(replies: [String: Reply]) {
        self.replies = replies
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url?.absoluteString ?? ""
        let path = request.url?.path() ?? ""
        guard let match = replies.first(where: { path.hasSuffix($0.key) || url.contains($0.key) }) else {
            throw ProviderError.notFound
        }
        let (key, reply) = (match.key, match.value)
        overlaps[key] = Set(outstanding.keys)
        outstanding[key, default: 0] += 1
        defer {
            let remaining = (outstanding[key] ?? 1) - 1
            outstanding[key] = remaining > 0 ? remaining : nil
        }
        if reply.delay > .zero {
            try await Task.sleep(for: reply.delay)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(reply.json.utf8), response)
    }

    func recorded() -> [URLRequest] { requests }

    /// Whether `other` was still being served at the moment `key` was asked
    /// for — that is, whether the two overlapped rather than queued.
    func wasOutstanding(_ other: String, whenAsked key: String) -> Bool {
        overlaps[key]?.contains(other) ?? false
    }
}

@Suite struct PlexClientTests {
    private let identity = PlexIdentity(clientIdentifier: "client-1", deviceName: "Test iPhone")

    private func client(_ replies: [String: FakePlexTransport.Reply]) -> (PlexClient, FakePlexTransport) {
        let transport = FakePlexTransport(replies: replies)
        return (PlexClient(identity: identity, transport: transport), transport)
    }

    // MARK: Sign-in

    @Test func createsAPinAndAsksForTheLongLivedKind() async throws {
        let (client, transport) = client([
            "pins": .init(json: #"{"id": 55, "code": "ABCD"}"#)
        ])
        let pin = try await client.createPin()
        #expect(pin.id == 55)
        #expect(pin.code == "ABCD")

        let request = try #require(await transport.recorded().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query()?.contains("strong=true") == true)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "client-1")
    }

    @Test func reportsNoTokenWhileTheUserHasNotApproved() async throws {
        let (client, _) = client([
            "pins/55": .init(json: #"{"id": 55, "code": "ABCD", "authToken": null}"#)
        ])
        #expect(try await client.claimedToken(for: PlexPin(id: 55, code: "ABCD")) == nil)
    }

    @Test func reportsTheTokenOnceApproved() async throws {
        let (client, _) = client([
            "pins/55": .init(json: #"{"id": 55, "code": "ABCD", "authToken": "tok-1"}"#)
        ])
        #expect(try await client.claimedToken(for: PlexPin(id: 55, code: "ABCD")) == "tok-1")
    }

    /// An empty string is not a token; treating it as one would take the
    /// setup flow forward with nothing to authenticate with.
    @Test func treatsAnEmptyTokenAsNotYetApproved() async throws {
        let (client, _) = client([
            "pins/55": .init(json: #"{"id": 55, "code": "ABCD", "authToken": ""}"#)
        ])
        #expect(try await client.claimedToken(for: PlexPin(id: 55, code: "ABCD")) == nil)
    }

    // MARK: Home users

    @Test func listsTheHomeUsersToChooseFrom() async throws {
        let (client, transport) = client([
            "home/users": .init(json: """
            {"users": [
              {"id": 1, "title": "Alice", "admin": 1, "protected": 0, "restricted": 0},
              {"id": 2, "title": "Kids", "admin": 0, "protected": 1, "restricted": 1}
            ]}
            """)
        ])
        let users = try await client.homeUsers(token: "tok-1")
        #expect(users.map(\.title) == ["Alice", "Kids"])
        #expect(users[1].isProtected)

        let request = try #require(await transport.recorded().first)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "tok-1")
    }

    /// Switching returns a *different* token — the chosen user's. Carrying
    /// on with the admin's would show the wrong library and write ratings to
    /// the wrong account.
    @Test func switchingHomeUserReturnsThatUsersOwnToken() async throws {
        let (client, transport) = client([
            "switch": .init(json: #"{"authToken": "tok-kids"}"#)
        ])
        let token = try await client.switchToHomeUser(id: 2, pin: "1234", token: "tok-admin")
        #expect(token == "tok-kids")

        let request = try #require(await transport.recorded().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path().contains("home/users/2/switch") == true)
        #expect(request.url?.query()?.contains("pin=1234") == true)
    }

    @Test func omitsThePinForAnUnprotectedUser() async throws {
        let (client, transport) = client([
            "switch": .init(json: #"{"authToken": "tok-2"}"#)
        ])
        _ = try await client.switchToHomeUser(id: 1, token: "tok-admin")
        let request = try #require(await transport.recorded().first)
        #expect(request.url?.query()?.contains("pin=") != true)
    }

    @Test func aWrongHomePinIsReportedAsWrongCredentials() async throws {
        let (client, _) = client([
            "switch": .init(status: 401, json: "{}")
        ])
        await #expect(throws: ProviderError.notAuthenticated(.wrongCredentials)) {
            try await client.switchToHomeUser(id: 2, pin: "0000", token: "tok-admin")
        }
    }

    // MARK: Servers and libraries

    @Test func listsOnlyMediaServers() async throws {
        let (client, _) = client([
            "resources": .init(json: """
            [
              {"name": "Tower", "clientIdentifier": "aaa", "provides": "server", "owned": 1,
               "connections": [{"uri": "https://192-168-1-9.plex.direct:32400", "local": 1, "relay": 0, "IPv6": 0}]},
              {"name": "Living Room TV", "clientIdentifier": "bbb", "provides": "player", "owned": 1, "connections": []}
            ]
            """)
        ])
        let servers = try await client.servers(token: "tok-1")
        #expect(servers.map(\.name) == ["Tower"])
        #expect(servers[0].localURL != nil)
    }

    /// Offering a film library and then refusing it would be worse than not
    /// offering it, so non-music sections never reach the picker.
    @Test func offersOnlyMusicLibraries() async throws {
        let (client, _) = client([
            "library/sections": .init(json: """
            {"MediaContainer": {"Directory": [
              {"key": "1", "title": "Films", "type": "movie"},
              {"key": "2", "title": "Music", "type": "artist"},
              {"key": "3", "title": "Test Folder", "type": "artist"}
            ]}}
            """)
        ])
        let sections = try await client.musicSections(
            server: URL(string: "https://tower.plex.direct:32400")!,
            token: "tok-1"
        )
        #expect(sections.map(\.title) == ["Music", "Test Folder"])
    }

    @Test func aRejectedTokenSurfacesAsWrongCredentials() async throws {
        let (client, _) = client(["resources": .init(status: 401, json: "{}")])
        await #expect(throws: ProviderError.notAuthenticated(.wrongCredentials)) {
            try await client.servers(token: "stale")
        }
    }
}

@Suite struct PlexSignInPollerTests {
    private let identity = PlexIdentity(clientIdentifier: "client-1")

    /// A user who wanders off should not leave the app polling plex.tv for
    /// the rest of the session.
    @Test func givesUpOnAPinThatHasAlreadyLapsed() async throws {
        let transport = FakePlexTransport(replies: [
            "pins/1": .init(json: #"{"id": 1, "code": "A", "authToken": null}"#)
        ])
        let poller = PlexSignInPoller(interval: .milliseconds(1), timeout: .seconds(30))
        let expired = PlexPin(id: 1, code: "A", expiresAt: Date(timeIntervalSinceNow: -1))
        let token = try await poller.awaitToken(
            for: expired,
            client: PlexClient(identity: identity, transport: transport)
        )
        #expect(token == nil)
    }

    @Test func returnsTheTokenAsSoonAsItAppears() async throws {
        let transport = FakePlexTransport(replies: [
            "pins/1": .init(json: #"{"id": 1, "code": "A", "authToken": "tok"}"#)
        ])
        let poller = PlexSignInPoller(interval: .milliseconds(1), timeout: .seconds(30))
        let token = try await poller.awaitToken(
            for: PlexPin(id: 1, code: "A"),
            client: PlexClient(identity: identity, transport: transport)
        )
        #expect(token == "tok")
    }
}

@Suite struct PlexHomeSwitchTests {
    private let identity = PlexIdentity(clientIdentifier: "client-1")

    private func client(_ replies: [String: FakePlexTransport.Reply]) -> (PlexClient, FakePlexTransport) {
        let transport = FakePlexTransport(replies: replies)
        return (PlexClient(identity: identity, transport: transport), transport)
    }

    /// Switching lives on the original API, not v2. The v2 path answers 404,
    /// which reached the user as "the server could not find the requested
    /// item" — the app blaming their library for a wrong URL.
    @Test func switchesOnTheLegacyPathRatherThanV2() async throws {
        let (client, transport) = client(["switch": .init(json: #"{"authToken": "tok"}"#)])
        _ = try await client.switchToHomeUser(id: 2, token: "admin")
        let url = try #require(await transport.recorded().first?.url)
        #expect(url.absoluteString.hasPrefix("https://plex.tv/api/home/users/2/switch"))
        #expect(!url.absoluteString.contains("/v2/"))
    }

    @Test func readsATokenAtTheTopLevel() async throws {
        let (client, _) = client(["switch": .init(json: #"{"authToken": "tok-1"}"#)])
        #expect(try await client.switchToHomeUser(id: 2, token: "admin") == "tok-1")
    }

    @Test func readsTheOlderAuthenticationTokenSpelling() async throws {
        let (client, _) = client(["switch": .init(json: #"{"authenticationToken": "tok-2"}"#)])
        #expect(try await client.switchToHomeUser(id: 2, token: "admin") == "tok-2")
    }

    @Test func readsATokenNestedUnderUser() async throws {
        let (client, _) = client(["switch": .init(json: #"{"user": {"authToken": "tok-3"}}"#)])
        #expect(try await client.switchToHomeUser(id: 2, token: "admin") == "tok-3")
    }

    @Test func aResponseWithNoTokenIsAFailureRatherThanSilentSuccess() async throws {
        let (client, _) = client(["switch": .init(json: #"{"status": "ok"}"#)])
        await #expect(throws: (any Error).self) {
            try await client.switchToHomeUser(id: 2, token: "admin")
        }
    }

    // MARK: currentUser

    @Test func currentUserDecodesACapturedResponse() async throws {
        let (client, transport) = client([
            "user": .init(json: #"""
            {"id": 12345, "uuid": "a1b2c3d4e5f6", "username": "alice", "email": "alice@example.com"}
            """#)
        ])
        let user = try await client.currentUser(token: "tok")
        #expect(user.uuid == "a1b2c3d4e5f6")
        let request = try #require(await transport.recorded().first)
        #expect(request.url?.absoluteString.hasPrefix("https://plex.tv/api/v2/user") == true)
    }

    @Test func aRejectedTokenThrowsRatherThanReturningAPlaceholder() async {
        let (client, _) = client(["user": .init(status: 401, json: "")])
        await #expect(throws: (any Error).self) {
            try await client.currentUser(token: "bad-token")
        }
    }
}


@Suite struct PlexConnectionFallbackTests {
    private let identity = PlexIdentity(clientIdentifier: "client-1")

    private let sectionsJSON = """
    {"MediaContainer": {"Directory": [{"key": "2", "title": "Music", "type": "artist"}]}}
    """

    /// Plex lists every address it *might* be reachable at, and the local one
    /// is preferred but frequently unreachable — a different network, a phone
    /// on cellular. Taking it on faith is what a setup timeout looks like.
    @Test func fallsBackToTheNextAddressWhenTheLocalOneDoesNotAnswer() async throws {
        let transport = FakePlexTransport(replies: ["remote.example.com": .init(json: sectionsJSON)])
        let client = PlexClient(identity: identity, transport: transport)
        let (url, sections) = try await client.firstReachableLibrary(
            among: [
                .init(uri: URL(string: "https://192-168-1-9.plex.direct:32400")!, isLocal: true, isRelay: false),
                .init(uri: URL(string: "https://remote.example.com")!, isLocal: false, isRelay: false),
            ],
            token: "tok"
        )
        #expect(url.host() == "remote.example.com")
        #expect(sections.map(\.title) == ["Music"])
    }

    /// The head start earning its keep: an address that answers gets to win
    /// before the next one is so much as asked.
    @Test func usesTheFirstAddressWhenItAnswers() async throws {
        let transport = FakePlexTransport(replies: ["library/sections": .init(json: sectionsJSON)])
        // A minute of head start rather than the shipping 400ms.
        let client = PlexClient(identity: identity, transport: transport, headStart: .seconds(60))
        let (url, _) = try await client.firstReachableLibrary(
            among: [
                .init(uri: URL(string: "https://192-168-1-9.plex.direct:32400")!, isLocal: true, isRelay: false),
                .init(uri: URL(string: "https://remote.example.com")!, isLocal: false, isRelay: false),
            ],
            token: "tok"
        )
        #expect(url.host()?.contains("192-168-1-9") == true)
        // The second address is never tried once the first works.
        #expect(await transport.recorded().count == 1)
    }

    /// The reason the addresses are raced rather than tried in turn: a Plex server lists an address
    /// for every interface it has, and the ones that do not apply here hang rather than refuse.
    @Test func aSlowAddressDoesNotHoldUpAFastOne() async throws {
        // Timing the call proves nothing here.
        let transport = FakePlexTransport(replies: [
            "slow.example.com": .init(status: 500, json: "{}", delay: .seconds(60)),
            "fast.example.com": .init(json: sectionsJSON),
        ])
        let client = PlexClient(identity: identity, transport: transport)

        let (url, _) = try await client.firstReachableLibrary(
            among: [
                .init(uri: URL(string: "https://slow.example.com")!, isLocal: true, isRelay: false),
                .init(uri: URL(string: "https://fast.example.com")!, isLocal: false, isRelay: false),
            ],
            token: "tok"
        )

        #expect(url.host() == "fast.example.com")
        // Tried in turn rather than raced, the fast address would not be asked
        // until the slow one had answered, and nothing would still be
        // outstanding when it was.
        #expect(
            await transport.wasOutstanding("slow.example.com", whenAsked: "fast.example.com"),
            "the fast address was asked only after the slow one had finished, which is queueing, not racing"
        )
    }

    @Test func reportsAFailureWhenNoAddressAnswers() async throws {
        let client = PlexClient(identity: identity, transport: FakePlexTransport(replies: [:]))
        await #expect(throws: (any Error).self) {
            try await client.firstReachableLibrary(
                among: [
                    .init(uri: URL(string: "https://a.example.com")!, isLocal: true, isRelay: false),
                    .init(uri: URL(string: "https://b.example.com")!, isLocal: false, isRelay: false),
                ],
                token: "tok"
            )
        }
    }
}


@Suite struct PlexConnectionLabelTests {
    private func connection(local: Bool, relay: Bool) -> PlexResource.Connection {
        .init(uri: URL(string: "https://example.com")!, isLocal: local, isRelay: relay)
    }

    /// Shown while waiting, so a slow step says which address it is on
    /// rather than leaving the user to guess whether anything is happening.
    @Test func namesEachKindOfAddress() {
        #expect(connection(local: true, relay: false).label == "local network")
        #expect(connection(local: false, relay: false).label == "remote address")
        #expect(connection(local: false, relay: true).label == "Plex relay")
    }

    @Test func reportsEveryAddressItTriesInOrder() async throws {
        let transport = FakePlexTransport(replies: [
            "b.example.com": .init(json: #"{"MediaContainer": {"Directory": []}}"#)
        ])
        let client = PlexClient(identity: PlexIdentity(clientIdentifier: "c"), transport: transport)
        let attempts = Mutex<[String]>([])
        _ = try await client.firstReachableLibrary(
            among: [
                .init(uri: URL(string: "https://a.example.com")!, isLocal: true, isRelay: false),
                .init(uri: URL(string: "https://b.example.com")!, isLocal: false, isRelay: true),
            ],
            token: "tok"
        ) { connection in
            attempts.withLock { $0.append(connection.label) }
        }
        #expect(attempts.withLock { $0 } == ["local network", "Plex relay"])
    }
}
