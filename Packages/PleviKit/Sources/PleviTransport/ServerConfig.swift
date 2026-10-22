import Foundation
import PleviDomain

/// The scheme+host+port identity of an endpoint. Requests and redirects are
/// only ever allowed to origins derived from the user's configured URLs.
public struct URLOrigin: Hashable, Sendable, Codable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    public func matches(_ url: URL) -> Bool {
        URLOrigin(url: url) == self
    }
}

/// A server's addresses. Modelled as an enum so "at least one address" is a
/// type-level guarantee rather than a runtime check, and so `preferred` needs
/// no optional handling.
public enum ServerAddresses: Hashable, Sendable, Codable {
    /// Reachable only on the user's own network.
    case local(URL)
    /// Reachable from anywhere (reverse proxy, tunnel, VPN hostname).
    case remote(URL)
    case both(local: URL, remote: URL)

    public init?(local: URL?, remote: URL?) {
        switch (local, remote) {
        case let (localURL?, remoteURL?):
            self = .both(local: localURL, remote: remoteURL)
        case let (localURL?, nil):
            self = .local(localURL)
        case let (nil, remoteURL?):
            self = .remote(remoteURL)
        case (nil, nil):
            return nil
        }
    }

    public var local: URL? {
        switch self {
        case .local(let url), .both(let url, _): url
        case .remote: nil
        }
    }

    public var remote: URL? {
        switch self {
        case .remote(let url), .both(_, let url): url
        case .local: nil
        }
    }

    /// The address to try first. Local is preferred whenever configured: it
    /// is faster, avoids hairpin NAT, and keeps traffic off the internet.
    public var preferred: URL {
        switch self {
        case .local(let url), .remote(let url), .both(let url, _): url
        }
    }

    /// Every configured address, in the order they should be attempted.
    public var inPreferenceOrder: [URL] {
        switch self {
        case .local(let url), .remote(let url): [url]
        case .both(let local, let remote): [local, remote]
        }
    }

    /// The two addresses in the order they are worth *probing*, judged by what they are rather than
    /// by which slot they landed in.
    public func replacingLocal(with url: URL) -> ServerAddresses {
        // What is being displaced, if it is worth keeping: an address that can be reached from
        // anywhere.
        let displaced = local.flatMap {
            ServerAddressKind(host: $0.host() ?? "") == .fromAnywhere ? $0 : nil
        }
        // Never the same address in both slots: it would be probed, fail or
        // answer, and then be tried again as its own fallback.
        let kept = (remote == url ? nil : remote) ?? displaced
        return ServerAddresses(local: url, remote: kept == url ? nil : kept) ?? .local(url)
    }

    /// The same server, reached from outside on a different address.
    public func replacingRemote(with url: URL) -> ServerAddresses {
        // Never the same address in both slots.
        ServerAddresses(local: local == url ? nil : local, remote: url) ?? .remote(url)
    }

    public var probeOrder: (first: URL, second: URL)? {
        guard case .both(let local, let remote) = self else { return nil }
        let localIsPrivate = ServerAddressKind(host: local.host() ?? "") == .onYourNetwork
        let remoteIsPrivate = ServerAddressKind(host: remote.host() ?? "") == .onYourNetwork
        if remoteIsPrivate, !localIsPrivate { return (remote, local) }
        return (local, remote)
    }
}

/// A certificate the user explicitly approved for one origin, identified by the SHA-256 of the leaf
/// certificate's DER encoding.
public struct PinnedCertificate: Hashable, Sendable, Codable {
    public var origin: URLOrigin
    public var sha256: Data

    public init(origin: URLOrigin, sha256: Data) {
        self.origin = origin
        self.sha256 = sha256
    }
}

/// Which backend a server speaks. The app picks the provider from this;
/// nothing else branches on it.
public enum ServerKind: String, Hashable, Sendable, Codable {
    case subsonic
    case plex
}

/// One library on a server that has several — a Plex section, and whatever
/// the equivalent turns out to be for other backends. Named generically so
/// no Plex vocabulary leaks into the transport layer.
public struct LibrarySelection: Hashable, Sendable, Codable {
    public var key: String
    public var title: String
    /// The server's own identifier, which some APIs need when referring to
    /// their own items.
    public var machineIdentifier: String

    public init(key: String, title: String = "", machineIdentifier: String = "") {
        self.key = key
        self.title = title
        self.machineIdentifier = machineIdentifier
    }
}

/// Per-server connection configuration. Contains **no secrets**: passwords,
/// API keys, tokens, custom header values, and client-certificate material
/// live in the Keychain, addressed by this config's `id`.
public struct ServerConfig: Identifiable, Hashable, Sendable, Codable {
    public var id: ServerID
    public var name: String
    public var addresses: ServerAddresses
    /// Explicitly approved certificates, keyed by origin. Origins without an
    /// entry use ordinary system trust evaluation.
    public var pinnedCertificates: [PinnedCertificate]
    /// Names of custom headers sent with every request (e.g.
    /// "CF-Access-Client-Id"). Values are fetched from the Keychain at
    /// request-build time.
    public var customHeaderNames: [String]
    public var usesClientCertificate: Bool
    public var kind: ServerKind
    /// Set when the backend has more than one library and the user chose one.
    public var library: LibrarySelection?
    /// Plex only: the signed-in Plex user's stable per-profile identifier (`/api/v2/user`'s
    /// `uuid`), for the Remote Control iCloud check's scope.
    public var accountID: String?

    public init(
        id: ServerID = ServerID(),
        name: String,
        addresses: ServerAddresses,
        pinnedCertificates: [PinnedCertificate] = [],
        customHeaderNames: [String] = [],
        usesClientCertificate: Bool = false,
        kind: ServerKind = .subsonic,
        library: LibrarySelection? = nil,
        accountID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.pinnedCertificates = pinnedCertificates
        self.customHeaderNames = customHeaderNames
        self.usesClientCertificate = usesClientCertificate
        self.kind = kind
        self.library = library
        self.accountID = accountID
    }

    /// Written by hand so servers saved before `kind`, `library` and `accountID` existed still
    /// decode — a synthesised initialiser would reject them for a missing key and the user would
    /// silently lose every configured server.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ServerID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        addresses = try container.decode(ServerAddresses.self, forKey: .addresses)
        pinnedCertificates = try container.decodeIfPresent([PinnedCertificate].self, forKey: .pinnedCertificates) ?? []
        customHeaderNames = try container.decodeIfPresent([String].self, forKey: .customHeaderNames) ?? []
        usesClientCertificate = try container.decodeIfPresent(Bool.self, forKey: .usesClientCertificate) ?? false
        kind = try container.decodeIfPresent(ServerKind.self, forKey: .kind) ?? .subsonic
        library = try container.decodeIfPresent(LibrarySelection.self, forKey: .library)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    }

    /// The only origins any request or redirect may target.
    public var allowedOrigins: Set<URLOrigin> {
        Set(addresses.inPreferenceOrder.compactMap { URLOrigin(url: $0) })
    }

    /// The approved certificate for a host and port, if the user pinned one.
    public func pin(forHost host: String, port: Int) -> Data? {
        let host = host.lowercased()
        return pinnedCertificates
            .first { $0.origin.host == host && $0.origin.port == port }?
            .sha256
    }
}

public extension ServerConfig {
    /// Whether `selection` is another library of *this* server.
    func offers(_ selection: LibrarySelection) -> Bool {
        guard kind == .plex, let current = library,
              !current.machineIdentifier.isEmpty,
              !selection.key.isEmpty,
              selection.machineIdentifier == current.machineIdentifier
        else { return false }
        return true
    }

    /// The entries of the app-wide Quick Switch list that belong to this
    /// server, in the list's order. The list is a single setting shared by
    /// every server, so it is scoped here rather than trusted.
    func quickSwitchChoices(from list: [LibrarySelection]) -> [LibrarySelection] {
        list.filter { offers($0) }
    }
}

/// Validation applied to server URLs at setup time.
public enum EndpointValidation {
    public enum Issue: Hashable, Sendable {
        /// Scheme is not http/https or the host is missing.
        case notHTTPURL
        /// `user:password@host` userinfo is never accepted.
        case embedsCredentials
        /// Plain HTTP to a host that is not on a private network. Remote
        /// endpoints must use TLS — no exceptions, no override switch.
        case plainHTTPToPublicHost
    }

    /// Returns nil when the URL is acceptable. Plain HTTP is tolerated only
    /// for private-range and link-local hosts (a home LAN without TLS), and
    /// the UI still warns in that case.
    public static func validate(_ url: URL) -> Issue? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(),
              !host.isEmpty
        else { return .notHTTPURL }

        if url.user() != nil || url.password() != nil {
            return .embedsCredentials
        }

        if scheme == "http", !isPrivateHost(host) {
            return .plainHTTPToPublicHost
        }

        return nil
    }

    /// Interprets what the user typed into an address field, in preference order.
    public static func candidateURLs(forUserInput text: String) -> [URL] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains("://") {
            return URL(string: trimmed).map { [$0] } ?? []
        }
        guard let httpsURL = URL(string: "https://" + trimmed),
              let host = httpsURL.host()
        else { return [] }
        if isPrivateHost(host), let httpURL = URL(string: "http://" + trimmed) {
            return [httpsURL, httpURL]
        }
        return [httpsURL]
    }

    /// True for hosts that can only be on the local network: loopback,
    /// RFC 1918 IPv4 ranges, carrier-grade NAT, link-local, unique-local
    /// IPv6, mDNS `.local`, and `.home.arpa`.
    public static func isPrivateHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if host == "localhost" || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".internal") {
            return true
        }

        // IPv6 loopback, unique-local (fc00::/7), link-local (fe80::/10).
        if host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            return host.contains(":")
        }

        guard let parts = literalIPv4(of: host) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _): return true
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        // Carrier-grade NAT, 100.64/10 — which is also where a Tailscale
        // address lives. Not somewhere anyone outside reaches either way.
        case (100, 64...127): return true
        default: return false
        }
    }

    /// The four octets an address-shaped host stands for, whether it is written as a dotted quad or
    /// hidden in the first label of a name.
    public static func literalIPv4(of host: String) -> [UInt8]? {
        func quad(_ text: some StringProtocol) -> [UInt8]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            // Not `UInt8(part)` alone: that accepts a leading "+", and
            // "1.2.3.+4" is not an address.
            let octets = parts.compactMap { part -> UInt8? in
                part.allSatisfy(\.isNumber) ? UInt8(part) : nil
            }
            return octets.count == 4 ? octets : nil
        }
        if let direct = quad(host) { return direct }
        guard let first = host.split(separator: ".").first else { return nil }
        return quad(first.replacingOccurrences(of: "-", with: "."))
    }
}
