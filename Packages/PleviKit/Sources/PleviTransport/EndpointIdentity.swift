import Foundation

/// What the probe of a home address asks, and what counts as the server answering it.
public enum EndpointIdentity: Sendable, Equatable {
    /// Any answer at all. For a Plex entry that has no machine identifier
    /// stored, where there is nothing to compare.
    case anyAnswer
    /// A Subsonic-family server: its API answers, in its JSON envelope, even
    /// to a request with no credentials.
    case subsonic
    /// A Plex Media Server, by the identifier it gives at `/identity`.
    case plex(machineIdentifier: String)

    public enum Verdict: Sendable, Equatable {
        /// It is the server.
        case verified
        /// Something answered, in a way that neither confirms nor rules out
        /// the server: a proxy's sign-in wall, an authentication challenge.
        case unverified
        /// Something answered, and it is not the server.
        case notThisServer

        /// Whether the address may be used.
        public var isUsable: Bool { self != .notThisServer }
    }

    public init(config: ServerConfig) {
        switch config.kind {
        case .subsonic:
            self = .subsonic
        case .plex:
            let id = config.library?.machineIdentifier ?? ""
            self = id.isEmpty ? .anyAnswer : .plex(machineIdentifier: id)
        }
    }

    /// The request that asks an address who it is. Never carries credentials.
    func probeRequest(base: URL) -> URLRequest {
        var request: URLRequest
        switch self {
        case .anyAnswer:
            request = URLRequest(url: base)
        case .subsonic:
            request = URLRequest(
                url: base.appending(path: "rest/ping").appending(queryItems: [
                    URLQueryItem(name: "v", value: "1.16.1"),
                    URLQueryItem(name: "c", value: "Plevi"),
                    URLQueryItem(name: "f", value: "json"),
                ])
            )
        case .plex:
            request = URLRequest(url: base.appending(path: "identity"))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        // An answer from a cache is not an answer from the address.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// Judges an answer to `probeRequest`.
    func judge(status: Int, body: Data) -> Verdict {
        switch self {
        case .anyAnswer:
            return .verified
        case .subsonic:
            // The API answers 200 with its envelope even when it is refusing the request for want
            // of credentials — which is what this request is.
            guard (200..<300).contains(status) else { return .unverified }
            return Self.contains("subsonic-response", in: body) ? .verified : .notThisServer
        case .plex(let expected):
            guard status == 200 else { return .notThisServer }
            guard let found = Self.plexMachineIdentifier(in: body) else { return .notThisServer }
            return found == expected ? .verified : .notThisServer
        }
    }

    private static func contains(_ needle: String, in body: Data) -> Bool {
        // The envelope is the first thing in the body; a page that mentions
        // it far down is not one.
        String(decoding: body.prefix(2048), as: UTF8.self).contains(needle)
    }

    /// The machine identifier in Plex's `/identity` answer, asked for as JSON
    /// and read from XML as well, since a server or proxy that ignores the
    /// header sends the latter.
    static func plexMachineIdentifier(in body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let container = object["MediaContainer"] as? [String: Any],
           let id = container["machineIdentifier"] as? String, !id.isEmpty {
            return id
        }
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        guard let range = text.range(
            of: #"machineIdentifier=["']([^"']+)["']"#,
            options: .regularExpression
        ) else { return nil }
        let match = text[range]
        guard let open = match.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let value = match[match.index(after: open)...].dropLast()
        return value.isEmpty ? nil : String(value)
    }
}
