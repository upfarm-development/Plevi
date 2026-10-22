import Foundation
import PleviDomain
import PleviTransport

/// The plex.tv and server calls the setup flow needs: claim a sign-in, list the Home users, list
/// the servers, list their music libraries.
public actor PlexClient {
    private let identity: PlexIdentity
    private let transport: any HTTPTransport
    /// How long each address waits before the next one is tried, as `connectionHeadStart`
    /// describes.
    private let headStart: Duration

    /// Short on purpose: a Plex server advertises addresses that may not be
    /// reachable from here, and each one has to fail fast enough that trying
    /// the next still happens while the user is looking at the screen.
    public static let setupTimeout: TimeInterval = 8

    public init(
        identity: PlexIdentity,
        transport: any HTTPTransport = PlainHTTPTransport(timeout: PlexClient.setupTimeout),
        headStart: Duration = PlexClient.connectionHeadStart
    ) {
        self.identity = identity
        self.transport = transport
        self.headStart = headStart
    }

    // MARK: Signing in

    /// Asks plex.tv for a PIN. The user approves it on Plex's own page, and
    /// `claimedToken` then returns the token — the app never sees the
    /// password, and there is nothing for it to store but the result.
    public func createPin() async throws -> PlexPin {
        var request = URLRequest(url: PlexAuth.apiBase.appending(path: "pins"))
        request.httpMethod = "POST"
        // A "strong" PIN is the long-lived kind; the short numeric ones are
        // for TVs typing on a remote.
        request.url = request.url?.appending(queryItems: [URLQueryItem(name: "strong", value: "true")])
        apply(headers: identity.headers(), to: &request)

        let dto: PlexPinDTO = try await decode(request)
        return PlexPin(id: dto.id, code: dto.code, expiresAt: Self.date(from: dto.expiresAt))
    }

    /// The token once the user has approved the PIN, or nil while they have
    /// not. Polled by the caller.
    public func claimedToken(for pin: PlexPin) async throws -> String? {
        var request = URLRequest(url: PlexAuth.apiBase.appending(path: "pins/\(pin.id)"))
        apply(headers: identity.headers(), to: &request)
        let dto: PlexPinDTO = try await decode(request)
        guard let token = dto.authToken, !token.isEmpty else { return nil }
        return token
    }

    // MARK: Home users

    /// The profiles on this Plex Home. A single-user account returns just
    /// the one, which the caller can skip past rather than asking.
    public func homeUsers(token: String) async throws -> [PlexHomeUser] {
        var request = URLRequest(url: PlexAuth.apiBase.appending(path: "home/users"))
        apply(headers: identity.headers(token: token), to: &request)
        let dto: PlexHomeUsersDTO = try await decode(request)
        return dto.users.map(\.domain)
    }

    /// Switches to a Home user and returns *that user's* token, which is the
    /// one everything afterwards must use — their library and their ratings
    /// are not the admin's.
    public func switchToHomeUser(
        id: Int,
        pin: String? = nil,
        token: String
    ) async throws -> String {
        var url = PlexAuth.legacyAPIBase.appending(path: "home/users/\(id)/switch")
        if let pin, !pin.isEmpty {
            url = url.appending(queryItems: [URLQueryItem(name: "pin", value: pin)])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        apply(headers: identity.headers(token: token), to: &request)

        let (data, response) = try await transport.perform(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            // Plex answers a wrong Home PIN with a plain refusal.
            throw ProviderError.notAuthenticated(.wrongCredentials)
        }
        try Self.check(response, data: data)
        let dto = try Self.decoder.decode(PlexSwitchResponse.self, from: data)
        guard let switched = dto.authToken, !switched.isEmpty else {
            throw ProviderError.malformedResponse(details: "switching Home user returned no token")
        }
        return switched
    }

    /// The signed-in Plex user's stable identifier, for Remote Control's iCloud check.
    public func currentUser(token: String) async throws -> PlexUser {
        var request = URLRequest(url: PlexAuth.apiBase.appending(path: "user"))
        apply(headers: identity.headers(token: token), to: &request)
        let dto: PlexUserDTO = try await decode(request)
        return dto.domain
    }

    // MARK: Servers and libraries

    /// The media servers this account can reach.
    public func servers(token: String) async throws -> [PlexResource] {
        let url = PlexAuth.apiBase
            .appending(path: "resources")
            .appending(queryItems: [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1"),
            ])
        var request = URLRequest(url: url)
        apply(headers: identity.headers(token: token), to: &request)

        let dtos: [PlexResourceDTO] = try await decode(request)
        return dtos.filter(\.isMediaServer).map(\.domain)
    }

    /// The music libraries on one server. Other section types are filtered
    /// out here rather than being offered and then rejected.
    public func musicSections(
        server: URL,
        token: String,
        transport: (any HTTPTransport)? = nil
    ) async throws -> [PlexLibrarySection] {
        var request = URLRequest(url: server.appending(path: "library/sections"))
        apply(headers: identity.headers(token: token), to: &request)

        let (data, response) = try await (transport ?? self.transport).perform(request)
        try Self.check(response, data: data)
        let decoded = try Self.decoder.decode(PlexSectionsResponse.self, from: data)
        return decoded.sections.filter(\.isMusic)
    }

    /// The first of a server's addresses that actually answers, with its libraries.
    public static let connectionHeadStart = Duration.milliseconds(400)

    /// The first address that answers, with its music libraries.
    public func firstReachableLibrary(
        among connections: [PlexResource.Connection],
        token: String,
        transport: (any HTTPTransport)? = nil,
        onAttempt: (@Sendable (PlexResource.Connection) -> Void)? = nil
    ) async throws -> (url: URL, sections: [PlexLibrarySection]) {
        guard !connections.isEmpty else { throw ProviderError.notFound }

        let headStart = self.headStart
        return try await withThrowingTaskGroup(
            of: (url: URL, sections: [PlexLibrarySection])?.self
        ) { group in
            for (position, connection) in connections.enumerated() {
                group.addTask {
                    if position > 0 {
                        let wait = headStart * position
                        guard (try? await Task.sleep(for: wait)) != nil else { return nil }
                    }
                    onAttempt?(connection)
                    guard let sections = try? await self.musicSections(
                        server: connection.uri,
                        token: token,
                        transport: transport
                    ) else { return nil }
                    return (connection.uri, sections)
                }
            }

            for try await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            throw ProviderError.notFound
        }
    }

    // MARK: Plumbing

    private func apply(headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await transport.perform(request)
        try Self.check(response, data: data)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ProviderError.malformedResponse(details: "unexpected response from plex.tv")
        }
    }

    static let decoder = JSONDecoder()

    static func check(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw ProviderError.notAuthenticated(.wrongCredentials)
        case 403:
            throw ProviderError.notAuthorized
        case 404:
            // Says which request answered 404. The *path* only — a Plex URL
            // carries the token in its query, and an error message is not a
            // place to put one.
            throw ProviderError.serverError(
                code: 404,
                message: "Plex answered 404 for \(response.url?.path ?? "the request"). The item may have been removed, or its id is from before a rescan.",
                helpURL: nil
            )
        default:
            throw ProviderError.serverError(
                code: response.statusCode,
                message: "Plex returned HTTP \(response.statusCode) for "
                    + (response.url?.path ?? "the request")
                    + explanation(from: data),
                helpURL: nil
            )
        }
    }

    /// What the server said about it, if it said anything worth repeating.
    static func explanation(from data: Data) -> String {
        guard let body = String(data: data.prefix(400), encoding: .utf8) else { return "" }
        let text = body
            .replacingOccurrences(
                of: #"(?i)(token["'=:\s]{1,3})[^&"'\s<>]+"#,
                with: "$1…",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : " — \(text)"
    }

    static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
}

/// The switch response, whose shape depends on how old the endpoint is
/// feeling: a token at the top level, the older `authenticationToken`
/// spelling, or either of those nested under `user`.
struct PlexSwitchResponse: Decodable {
    let authToken: String?

    private enum CodingKeys: String, CodingKey {
        case authToken, authenticationToken, user
    }

    private struct UserBody: Decodable {
        let authToken: String?
        let authenticationToken: String?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let token = try container.decodeIfPresent(String.self, forKey: .authToken) {
            authToken = token
        } else if let token = try container.decodeIfPresent(String.self, forKey: .authenticationToken) {
            authToken = token
        } else if let user = try container.decodeIfPresent(UserBody.self, forKey: .user) {
            authToken = user.authToken ?? user.authenticationToken
        } else {
            authToken = nil
        }
    }
}

/// Polls plex.tv until the user finishes signing in.
public struct PlexSignInPoller: Sendable {
    public let interval: Duration
    public let timeout: Duration

    public init(interval: Duration = .seconds(1), timeout: Duration = .seconds(300)) {
        self.interval = interval
        self.timeout = timeout
    }

    /// How many polls in a row may fail before the failure is believed.
    public static let failuresTolerated = 5

    /// Returns the token once the PIN is claimed, or nil if it lapsed first.
    public func awaitToken(
        for pin: PlexPin,
        client: PlexClient,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> String? {
        let deadline = now().addingTimeInterval(TimeInterval(timeout.components.seconds))
        var failures = 0
        while now() < deadline {
            if pin.isExpired(at: now()) { return nil }
            do {
                if let token = try await client.claimedToken(for: pin) { return token }
                failures = 0
            } catch {
                failures += 1
                guard Self.isTransient(error), failures < Self.failuresTolerated else { throw error }
            }
            // Longer after each failure in a row, so a plex.tv that is
            // struggling is not asked harder for it.
            try await Task.sleep(for: interval * min(failures + 1, 5))
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// Whether a failed poll is worth polling again after: the network flinching, plex.tv busy or
    /// unwell, or a reply that came back garbled.
    static func isTransient(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? ProviderError else { return false }
        switch error {
        case .network(let underlying):
            return underlying.code != .cancelled
        case .serverError(let code, _, _):
            guard let code else { return true }
            return code == 429 || code == 408 || code >= 500
        case .malformedResponse:
            return true
        default:
            return false
        }
    }
}
