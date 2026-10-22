import Foundation

/// How this server authenticates.
public enum SubsonicCredentials: Hashable, Sendable, Codable {
    /// Classic salted-token auth: each request sends `u`, `t` = MD5(password
    /// + salt), and a fresh random `s`.
    case usernamePassword(username: String, password: String)
    /// OpenSubsonic `apiKeyAuthentication` extension: requests send `apiKey`
    /// and must not send `u`.
    case apiKey(String)

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SubsonicCredentials {
        try JSONDecoder().decode(SubsonicCredentials.self, from: data)
    }
}
