import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

/// A loopback listener that answers every request with one canned reply and
/// records the request line it was asked.
private final class CannedSocket: @unchecked Sendable {
    let port: UInt16
    private let handle: Int32
    private let lines = NSLock()
    private var requestLines: [String] = []

    var requests: [String] {
        lines.lock(); defer { lines.unlock() }
        return requestLines
    }

    init?(status: Int = 200, contentType: String = "application/json", body: String) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else { close(descriptor); return nil }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { close(descriptor); return nil }
        handle = descriptor
        port = UInt16(bigEndian: assigned.sin_port)

        let reply = "HTTP/1.1 \(status) X\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        Thread.detachNewThread { [weak self, descriptor] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = recv(client, &buffer, buffer.count, 0)
                if count > 0, let self {
                    let text = String(decoding: buffer.prefix(count), as: UTF8.self)
                    let first = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
                    self.lines.lock(); self.requestLines.append(first); self.lines.unlock()
                }
                _ = reply.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    deinit { close(handle) }
}

private let remote = URL(string: "http://127.0.0.1:9")!

private func plex(machineIdentifier: String, local: URL) -> ServerConfig {
    ServerConfig(
        name: "Plex",
        addresses: ServerAddresses(local: local, remote: remote)!,
        kind: .plex,
        library: LibrarySelection(key: "1", title: "Music", machineIdentifier: machineIdentifier)
    )
}

private func subsonic(local: URL) -> ServerConfig {
    ServerConfig(name: "Navidrome", addresses: ServerAddresses(local: local, remote: remote)!)
}

/// What an address has to say for itself to be taken for the server.
@Suite("Home address identity")
struct EndpointIdentityTests {
    private static let plexJSON = #"{"MediaContainer":{"size":0,"machineIdentifier":"abc123","version":"1.40"}}"#
    private static let plexXML = #"<?xml version="1.0"?><MediaContainer size="0" machineIdentifier="abc123" version="1.40"/>"#

    @Test("Plex: the server's own identifier is verified, in JSON and in XML")
    func plexVerified() {
        let identity = EndpointIdentity.plex(machineIdentifier: "abc123")
        #expect(identity.judge(status: 200, body: Data(Self.plexJSON.utf8)) == .verified)
        #expect(identity.judge(status: 200, body: Data(Self.plexXML.utf8)) == .verified)
    }

    @Test("Plex: another server, a portal page and any refusal are not it")
    func plexRejected() {
        let identity = EndpointIdentity.plex(machineIdentifier: "other")
        #expect(identity.judge(status: 200, body: Data(Self.plexJSON.utf8)) == .notThisServer)
        let expected = EndpointIdentity.plex(machineIdentifier: "abc123")
        #expect(expected.judge(status: 200, body: Data("<html>Router login</html>".utf8)) == .notThisServer)
        #expect(expected.judge(status: 401, body: Data()) == .notThisServer)
        #expect(expected.judge(status: 404, body: Data()) == .notThisServer)
    }

    @Test("Plex with no stored identifier has nothing to compare and accepts any answer")
    func plexWithoutIdentifier() {
        let config = ServerConfig(
            name: "Plex", addresses: .remote(remote), kind: .plex,
            library: LibrarySelection(key: "1", title: "Music", machineIdentifier: "")
        )
        let identity = EndpointIdentity(config: config)
        #expect(identity == .anyAnswer)
        #expect(identity.judge(status: 404, body: Data()) == .verified)
    }

    private static let envelope = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":10,"message":"Required parameter is missing."}}}"#

    @Test("Subsonic: the JSON envelope is the server, even when it is refusing for want of credentials")
    func subsonicVerified() {
        #expect(EndpointIdentity.subsonic.judge(status: 200, body: Data(Self.envelope.utf8)) == .verified)
    }

    @Test("Subsonic: a 2xx page that is not the API is some other web server")
    func subsonicRejected() {
        #expect(EndpointIdentity.subsonic.judge(status: 200, body: Data("<html>Portal</html>".utf8)) == .notThisServer)
        #expect(EndpointIdentity.subsonic.judge(status: 200, body: Data()) == .notThisServer)
    }

    /// Setups that work today stay working: an authenticating proxy in front
    /// of Navidrome answers with its own status.
    @Test("Subsonic: an auth proxy's 401 or redirect is unverified, not refused", arguments: [401, 403, 302, 502])
    func subsonicUnverified(status: Int) {
        let verdict = EndpointIdentity.subsonic.judge(status: status, body: Data("<html>Sign in</html>".utf8))
        #expect(verdict == .unverified)
        #expect(verdict.isUsable)
    }

    @Test("The probe never carries credentials and never comes from a cache")
    func probeRequests() throws {
        let base = URL(string: "https://music.example/navidrome")!
        let subsonicRequest = EndpointIdentity.subsonic.probeRequest(base: base)
        let url = try #require(subsonicRequest.url).absoluteString
        #expect(url.hasPrefix("https://music.example/navidrome/rest/ping?"))
        for secret in ["u=", "t=", "s=", "apiKey", "X-Plex-Token"] {
            #expect(!url.contains(secret))
        }
        #expect(subsonicRequest.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)

        let plexRequest = EndpointIdentity.plex(machineIdentifier: "x").probeRequest(base: base)
        #expect(plexRequest.url?.path() == "/navidrome/identity")
        #expect(plexRequest.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        #expect(plexRequest.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }
}

/// The selector, against a listener that says what a stranger would say.
@Suite("Home address selection with identity")
struct EndpointSelectorIdentityTests {
    private static let subsonicEnvelope = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":10,"message":"missing"}}}"#

    @Test("A Plex address that is another server is not used")
    func anotherPlexServer() async throws {
        let stranger = try #require(CannedSocket(
            body: #"{"MediaContainer":{"machineIdentifier":"somebody-else"}}"#
        ))
        let selector = EndpointSelector(config: plex(machineIdentifier: "mine", local: stranger.url))
        let chosen = await selector.activeBaseURL()
        #expect(chosen == remote)
        let choice = await selector.lastChoice
        #expect(choice?.isLocal == false)
        #expect(choice?.localFailure == EndpointSelector.notTheServer)
        withExtendedLifetime(stranger) {}
    }

    @Test("A Plex address that is the server is used, and asked at /identity")
    func thePlexServer() async throws {
        let mine = try #require(CannedSocket(
            body: #"{"MediaContainer":{"machineIdentifier":"mine"}}"#
        ))
        let selector = EndpointSelector(config: plex(machineIdentifier: "mine", local: mine.url))
        #expect(await selector.activeBaseURL() == mine.url)
        #expect(mine.requests.contains { $0.hasPrefix("GET /identity") }, "asked: \(mine.requests)")
        withExtendedLifetime(mine) {}
    }

    @Test("A router's portal page on the Subsonic address is not the server")
    func portalPage() async throws {
        let portal = try #require(CannedSocket(contentType: "text/html", body: "<html>Router</html>"))
        let selector = EndpointSelector(config: subsonic(local: portal.url))
        #expect(await selector.activeBaseURL() == remote)
        withExtendedLifetime(portal) {}
    }

    @Test("A Subsonic server answering its envelope is used, and nothing secret is sent")
    func subsonicServer() async throws {
        let server = try #require(CannedSocket(body: Self.subsonicEnvelope))
        let selector = EndpointSelector(config: subsonic(local: server.url))
        #expect(await selector.activeBaseURL() == server.url)
        let line = try #require(server.requests.first)
        #expect(line.contains("/rest/ping"))
        #expect(!line.contains("t=") && !line.contains("apiKey"), "probe leaked credentials: \(line)")
        withExtendedLifetime(server) {}
    }

    @Test("An authenticating proxy in front of Navidrome is still the way in")
    func authProxy() async throws {
        let proxy = try #require(CannedSocket(status: 401, contentType: "text/html", body: "<html>Sign in</html>"))
        let selector = EndpointSelector(config: subsonic(local: proxy.url))
        #expect(await selector.activeBaseURL() == proxy.url)
        withExtendedLifetime(proxy) {}
    }

    /// network-offline-32: a cacheable answer must not stand in for the
    /// address answering now. Two probes, thirty seconds apart in principle;
    /// the second has to reach the socket.
    @Test("Probes bypass the URL cache")
    func noCaching() async throws {
        let server = try #require(CannedSocket(body: Self.subsonicEnvelope))
        let selector = EndpointSelector(config: subsonic(local: server.url))
        _ = await selector.activeBaseURL()
        await selector.invalidate()
        _ = await selector.activeBaseURL()
        #expect(server.requests.count == 2, "\(server.requests)")
        withExtendedLifetime(server) {}
    }

    @Test("A selector that has been closed still answers, with the remote address")
    func closedSelectorDegrades() async throws {
        let server = try #require(CannedSocket(body: Self.subsonicEnvelope))
        let selector = EndpointSelector(config: subsonic(local: server.url))
        await selector.close()
        // Nothing may crash or hang; the probe fails and the remote address
        // is the fallback.
        #expect(await selector.activeBaseURL() == remote)
        withExtendedLifetime(server) {}
    }
}

/// A refused redirect is recognised from the response itself, so requests
/// running side by side on one session cannot clear each other's mark.
@Suite("Cross-host redirects")
struct CrossHostRedirectTests {
    private func response(_ status: Int, location: String?, for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: location.map { ["Location": $0] }
        )!
    }

    private let request = URL(string: "https://music.example/rest/ping")!

    @Test("An SSO proxy's bounce to an identity provider is recognised")
    func bounce() {
        let found = ServerSessionDelegate.crossHostRedirect(
            in: response(302, location: "https://login.example/auth?rd=x", for: request), for: request
        )
        #expect(found?.host() == "login.example")
    }

    @Test("A relative or same-host redirect is not a hand-off")
    func sameHost() {
        #expect(ServerSessionDelegate.crossHostRedirect(
            in: response(302, location: "/login", for: request), for: request) == nil)
        #expect(ServerSessionDelegate.crossHostRedirect(
            in: response(301, location: "https://MUSIC.example/rest/ping", for: request), for: request) == nil)
    }

    @Test("Anything that is not a redirect, or has nowhere to go, is not")
    func notARedirect() {
        #expect(ServerSessionDelegate.crossHostRedirect(
            in: response(200, location: "https://login.example", for: request), for: request) == nil)
        #expect(ServerSessionDelegate.crossHostRedirect(
            in: response(302, location: nil, for: request), for: request) == nil)
        #expect(ServerSessionDelegate.crossHostRedirect(
            in: response(302, location: "https://login.example", for: request), for: nil) == nil)
    }

    /// The bug: one shared slot. Many verdicts at once, each from its own
    /// response, all come out right.
    @Test("Concurrent verdicts do not disturb each other")
    func concurrent() async {
        let request = request
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<200 {
                let bounced = index.isMultiple(of: 2)
                group.addTask {
                    let url = URL(string: "https://music.example/rest/\(index)")!
                    let reply = HTTPURLResponse(
                        url: url, statusCode: bounced ? 302 : 200, httpVersion: nil,
                        headerFields: bounced ? ["Location": "https://login.example/"] : nil
                    )!
                    return (ServerSessionDelegate.crossHostRedirect(in: reply, for: url) != nil) == bounced
                }
            }
            return await group.reduce(true) { $0 && $1 }
        }
        _ = request
        #expect(results)
    }
}

@Suite("Address slots")
struct AddressRecoveryTests {
    private let home = URL(string: "http://192.168.1.10:32400")!
    private let direct = URL(string: "https://203.0.113.5:32400")!
    private let relay = URL(string: "https://relay.plex.example:8443")!

    @Test("Replacing the remote address keeps the way home")
    func replacingRemote() {
        let both = ServerAddresses.both(local: home, remote: direct)
        let repaired = both.replacingRemote(with: relay)
        #expect(repaired.local == home)
        #expect(repaired.remote == relay)
    }

    @Test("A server with only a remote address stays a one-address entry")
    func replacingOnlyRemote() {
        let repaired = ServerAddresses.remote(direct).replacingRemote(with: relay)
        #expect(repaired.local == nil)
        #expect(repaired.remote == relay)
    }

    @Test("Never the same address in both slots")
    func neverTwice() {
        let repaired = ServerAddresses.both(local: home, remote: direct).replacingRemote(with: home)
        #expect(repaired.local == nil)
        #expect(repaired.remote == home)
    }

    @Test("Where iOS can put up its Local Network prompt")
    func localNetworkAccess() {
        #expect(ServerAddresses.local(home).mayNeedLocalNetworkAccess)
        #expect(ServerAddresses.both(local: home, remote: direct).mayNeedLocalNetworkAccess)
        #expect(ServerAddresses.remote(URL(string: "https://nas.local:4533")!).mayNeedLocalNetworkAccess)
        #expect(!ServerAddresses.remote(direct).mayNeedLocalNetworkAccess)
        #expect(!ServerAddresses.remote(URL(string: "https://music.example.com")!).mayNeedLocalNetworkAccess)
    }
}
