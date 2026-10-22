import Foundation
import CryptoKit
import PleviDomain
import PleviTransport

/// Low-level OpenSubsonic API client: request building, authentication, extension probing, envelope
/// decoding, and error mapping.
public actor SubsonicClient {
    public static let apiVersion = "1.16.1"
    public static let clientName = "Plevi"

    /// What an authenticated call revealed about these credentials, for
    /// `PleviRemote.CredentialHealth`.
    public enum AuthOutcome: Sendable, Equatable {
        /// The server answered inside a decoded envelope with error code
        /// 40 — the one response that proves it evaluated and rejected them.
        case rejected
        /// A 2xx envelope with no error.
        case accepted(direct: Bool)
    }

    private let credentials: SubsonicCredentials
    private let transport: any HTTPTransport
    private let customHeaders: [String: String]
    private let onAuthOutcome: (@Sendable (AuthOutcome) -> Void)?
    private var baseURL: URL

    /// Where the probe for server extensions stands.
    private enum ProbeState {
        case unprobed
        /// A probe is running; whoever needs the answer waits for this one
        /// rather than assuming the defaults.
        case inFlight(Task<Bool, Never>)
        /// A definitive answer, extensions or none.
        case done
    }
    private var probeState: ProbeState = .unprobed
    /// When the probe last came back inconclusive, so a run of calls on a
    /// dead link does not pay for a probe each.
    private var lastInconclusiveProbe: Date?
    private var extensionNames: Set<String> = []
    private var useFormPost = false

    /// How long calls go without re-probing after an inconclusive answer.
    /// `testConnection` ignores it.
    static let probeCooldown: TimeInterval = 20
    /// Short: the probe is a courtesy in front of the real request, and on a
    /// dead link every call would otherwise wait out the session's timeout
    /// twice.
    static let probeTimeout: TimeInterval = 10

    public init(
        baseURL: URL,
        credentials: SubsonicCredentials,
        transport: any HTTPTransport,
        customHeaders: [String: String] = [:],
        onAuthOutcome: (@Sendable (AuthOutcome) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
        self.customHeaders = customHeaders
        self.onAuthOutcome = onAuthOutcome
    }

    /// Switch between home and remote URLs (see `EndpointSelector`).
    public func setBaseURL(_ url: URL) {
        baseURL = url
        // A different address is a fresh chance for a probe that could not be
        // answered on the last one.
        lastInconclusiveProbe = nil
    }

    /// Extension names advertised by the server, probing on first use.
    public func serverExtensions(retryingInconclusive: Bool = false) async -> Set<String> {
        await ensureProbed(ignoringCooldown: retryingInconclusive)
        return extensionNames
    }

    // MARK: API calls

    func call(_ verb: String, _ params: [URLQueryItem] = []) async throws -> SubsonicPayload {
        await ensureProbed()
        let request = try makeAPIRequest(verb: verb, params: params)
        // Read before `perform`, which builds its own copy of the request
        // with the proxy's cookie attached — this is the plain one, still
        // missing it, which is exactly what `isDirect` needs to see.
        let direct = customHeaders.isEmpty && transport.isDirect(request)
        let (data, response) = try await transport.perform(request)
        let payload = try Self.decodePayload(
            data,
            httpStatus: response.statusCode,
            mimeType: response.mimeType,
            url: request.url,
            onServerRejection: { [onAuthOutcome] in onAuthOutcome?(.rejected) }
        )
        onAuthOutcome?(.accepted(direct: direct))
        return payload
    }

    /// Authenticated GET request for media endpoints (`stream`, `download`,
    /// `getCoverArt`). GET because AVPlayer and background downloads cannot
    /// send bodies.
    func makeMediaRequest(verb: String, params: [URLQueryItem]) throws -> URLRequest {
        var request = try makeGETRequest(verb: verb, params: commonParams + authParams() + params)
        for (name, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    // MARK: Probing

    private func ensureProbed(ignoringCooldown: Bool = false) async {
        switch probeState {
        case .done:
            return
        case .inFlight(let task):
            _ = await task.value
            return
        case .unprobed:
            if !ignoringCooldown, let last = lastInconclusiveProbe,
               Date().timeIntervalSince(last) < Self.probeCooldown {
                return
            }
        }
        // Unstructured, so a caller that is cancelled — a screen closing —
        // does not cancel the probe out from under the ones waiting on it and
        // have it cached as an answer.
        let task = Task { await self.runProbe() }
        probeState = .inFlight(task)
        _ = await task.value
    }

    /// One probe.
    private func runProbe() async -> Bool {
        var definitive = false
        do {
            var request = try makeGETRequest(verb: "getOpenSubsonicExtensions", params: commonParams)
            request.timeoutInterval = Self.probeTimeout
            let (data, response) = try await transport.perform(request)
            let payload = try Self.decodePayload(
                data,
                httpStatus: response.statusCode,
                mimeType: response.mimeType,
                url: request.url
            )
            extensionNames = Set((payload.openSubsonicExtensions ?? []).map(\.name))
            useFormPost = extensionNames.contains("formPost")
            definitive = true
        } catch {
            if Self.isDefinitiveProbeFailure(error) {
                extensionNames = []
                useFormPost = false
                definitive = true
            }
        }
        if definitive {
            probeState = .done
            lastInconclusiveProbe = nil
        } else {
            probeState = .unprobed
            lastInconclusiveProbe = Date()
        }
        return definitive
    }

    /// Whether a failed probe says the server has no extensions, as opposed to saying nothing about
    /// it.
    static func isDefinitiveProbeFailure(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? ProviderError else { return false }
        switch error {
        case .network, .tls, .proxySignInRequired:
            return false
        case .serverError(let code, _, _):
            // HTTP failures carry their status; a Subsonic envelope error
            // carries its own small code, which is an answer.
            guard let code, (500..<600).contains(code) || code == 408 || code == 429 else { return true }
            return false
        case .notAuthenticated, .notAuthorized:
            // A basic-auth or SSO wall answering for the server says nothing
            // about the server behind it.
            return false
        default:
            return true
        }
    }

    // MARK: Request building

    private var commonParams: [URLQueryItem] {
        [
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    private func authParams() -> [URLQueryItem] {
        switch credentials {
        case .usernamePassword(let username, let password):
            let salt = Self.randomSalt()
            return [
                URLQueryItem(name: "u", value: username),
                URLQueryItem(name: "t", value: Self.saltedToken(password: password, salt: salt)),
                URLQueryItem(name: "s", value: salt),
            ]
        case .apiKey(let key):
            // Per spec, `u` must not accompany an API key.
            return [URLQueryItem(name: "apiKey", value: key)]
        }
    }

    private func makeAPIRequest(verb: String, params: [URLQueryItem]) throws -> URLRequest {
        let allParams = commonParams + authParams() + params
        var request: URLRequest
        if useFormPost {
            request = URLRequest(url: endpointURL(verb: verb))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(allParams)
        } else {
            request = try makeGETRequest(verb: verb, params: allParams)
        }
        for (name, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func makeGETRequest(verb: String, params: [URLQueryItem]) throws -> URLRequest {
        let endpoint = endpointURL(verb: verb)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ProviderError.malformedResponse(details: "could not compose request URL")
        }
        components.queryItems = params
        // See the same line in `PlexProvider.url(path:query:)`.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            throw ProviderError.malformedResponse(details: "could not compose request URL")
        }
        return URLRequest(url: url)
    }

    private func endpointURL(verb: String) -> URL {
        baseURL.appending(path: "rest/\(verb)")
    }

    static func formEncode(_ params: [URLQueryItem]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = params
            .map { item in
                let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
                let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(name)=\(value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    // MARK: Auth primitives

    static func saltedToken(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func randomSalt() -> String {
        let alphabet = "0123456789abcdef"
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    // MARK: Response decoding

    /// An SSO proxy answers with a web page, whatever the status code — a login form on 200, or its
    /// own branded 401/403.
    static func isInterceptedByProxy(mimeType: String?, data: Data) -> Bool {
        if let mimeType, mimeType.lowercased().hasPrefix("text/html") { return true }
        // Some proxies omit or mislabel the type; the body still gives them
        // away. Only the first bytes are examined, after whitespace.
        let prefix = data.prefix(512)
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html")
    }

    static func decodePayload(
        _ data: Data,
        httpStatus: Int,
        mimeType: String? = nil,
        url: URL? = nil,
        onServerRejection: (() -> Void)? = nil
    ) throws -> SubsonicPayload {
        // Not for a five hundred.
        if let url, !(500..<600).contains(httpStatus),
           isInterceptedByProxy(mimeType: mimeType, data: data) {
            throw ProviderError.proxySignInRequired(url: url)
        }
        // Subsonic reports its own errors inside HTTP 200; non-2xx means the
        // request never reached a healthy Subsonic endpoint (proxy auth wall,
        // wrong path, server down).
        guard (200..<300).contains(httpStatus) else {
            switch httpStatus {
            case 401:
                throw ProviderError.notAuthenticated(.wrongCredentials)
            case 403:
                throw ProviderError.notAuthorized
            case 404:
                throw ProviderError.incompatibleServer(
                    details: "HTTP 404 — the URL does not point at a Subsonic-compatible API."
                )
            default:
                throw ProviderError.serverError(
                    code: httpStatus,
                    message: "HTTP \(httpStatus)",
                    helpURL: nil
                )
            }
        }

        let payload: SubsonicPayload
        do {
            payload = try JSONDecoder().decode(SubsonicEnvelope.self, from: data).subsonicResponse
        } catch {
            throw ProviderError.malformedResponse(
                details: "response was not a Subsonic JSON envelope"
            )
        }

        if let error = payload.error {
            // Only code 40 (wrong credentials) says the server itself evaluated and rejected them —
            // 41-44 are about the auth *method*, not the password, and would misreport a healthy
            // credential as rejected.
            if error.code == 40 { onServerRejection?() }
            throw mapError(error)
        }
        guard payload.status == "ok" else {
            throw ProviderError.serverError(code: nil, message: "status \(payload.status)", helpURL: nil)
        }
        return payload
    }

    static func mapError(_ error: SubsonicErrorDTO) -> ProviderError {
        switch error.code {
        case 10:
            return .missingParameter(name: error.message ?? "unknown")
        case 20, 30:
            return .incompatibleServer(details: error.message)
        case 40:
            return .notAuthenticated(.wrongCredentials)
        case 41:
            return .notAuthenticated(.tokenAuthUnsupported)
        case 42:
            return .notAuthenticated(.methodUnsupported)
        case 43:
            return .notAuthenticated(.conflictingMethods)
        case 44:
            return .notAuthenticated(.invalidAPIKey)
        case 50:
            return .notAuthorized
        case 70:
            return .notFound
        default:
            return .serverError(
                code: error.code,
                message: error.message,
                helpURL: error.helpUrl.flatMap(URL.init(string:))
            )
        }
    }
}
