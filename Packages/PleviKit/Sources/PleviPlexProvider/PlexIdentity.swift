import Foundation

/// How this installation identifies itself to plex.tv.
public struct PlexIdentity: Hashable, Sendable, Codable {
    public let clientIdentifier: String
    public var product: String
    public var version: String
    public var platform: String
    public var platformVersion: String
    public var device: String
    public var deviceName: String

    public init(
        clientIdentifier: String,
        product: String = "Plevi",
        version: String = "1.0",
        platform: String = "iOS",
        platformVersion: String = "",
        device: String = "iPhone",
        deviceName: String = "Plevi"
    ) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.platform = platform
        self.platformVersion = platformVersion
        self.device = device
        self.deviceName = deviceName
    }

    /// The `X-Plex-*` headers every request carries. Plex accepts these as
    /// query parameters too, but headers keep the token out of proxy access
    /// logs — the same reasoning as `formPost` on the Subsonic side.
    public func headers(token: String? = nil) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Platform": platform,
            "X-Plex-Device": device,
            "X-Plex-Device-Name": deviceName,
        ]
        if !platformVersion.isEmpty {
            headers["X-Plex-Platform-Version"] = platformVersion
        }
        if let token, !token.isEmpty {
            headers["X-Plex-Token"] = token
        }
        return headers
    }
}

/// A sign-in in progress: plex.tv issues a PIN, the user approves it in a
/// browser, and the app polls until a token comes back.
public struct PlexPin: Hashable, Sendable {
    public let id: Int
    public let code: String
    public let expiresAt: Date?

    public init(id: Int, code: String, expiresAt: Date? = nil) {
        self.id = id
        self.code = code
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }
}

public enum PlexAuth {
    public static let apiBase = URL(string: "https://plex.tv/api/v2")!

    /// Switching Home user still lives on the original API. The v2 path
    /// answers 404, which surfaced as "the server could not find the
    /// requested item" — the app blaming the library for a wrong URL.
    public static let legacyAPIBase = URL(string: "https://plex.tv/api")!

    /// The page the user signs in on. Opened in a web view; plex.tv marks the
    /// PIN as claimed and the app's poll then receives the token, so no
    /// credential is ever typed into anything the app can read.
    public static func signInURL(pin: PlexPin, identity: PlexIdentity) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")
        // Plex reads these from the *fragment*, not the query string.
        let fragment = [
            URLQueryItem(name: "clientID", value: identity.clientIdentifier),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: identity.product),
            URLQueryItem(name: "context[device][deviceName]", value: identity.deviceName),
            URLQueryItem(name: "context[device][platform]", value: identity.platform),
        ]
        var fragmentComponents = URLComponents()
        fragmentComponents.queryItems = fragment
        components?.fragment = "?" + (fragmentComponents.percentEncodedQuery ?? "")
        return components?.url
    }
}
