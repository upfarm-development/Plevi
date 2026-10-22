import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

/// Downloads behind an SSO proxy (D-09, network-offline-08): what the
/// foreground download path and the background one each make of a sign-in
/// wall, and that the cookie reaches the request.
@Suite("Stress: downloads behind a sign-in proxy", .serialized)
struct StressDownloadsProxyTests {

    @Test("network-offline-08: a foreground download bounced to another host is a sign-in wall, not 'HTTP 302'")
    func foregroundDownloadReportsTheWall() async throws {
        let server = try StressLoopbackServer()
        try await server.start()
        defer { server.stop() }
        // Same machine, different host name: what an SSO proxy handing the
        // request to its identity provider looks like to the delegate.
        server.route("/away", .redirect(location: "http://localhost:\(server.port)/login"))
        let config = ServerConfig(name: "Home", addresses: .local(server.base))
        let transport = ServerHTTPTransport(config: config)
        let destination = FileManager.default.temporaryDirectory.appending(path: "wall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await transport.download(URLRequest(url: server.base.appending(path: "away")), to: destination)
            Issue.record("expected the wall to be reported")
        } catch ProviderError.proxySignInRequired(let url) {
            #expect(url.path == "/away")
        } catch {
            Issue.record("expected proxySignInRequired, got \(error)")
        }
    }

    @Test("D-09: a proxy session stamps the request it is asked about, for its own origin only")
    func cookieIsStampedForItsOriginOnly() throws {
        let home = URL(string: "https://music.example.com/rest/download?id=1")!
        let elsewhere = URL(string: "https://other.example.com/rest/download?id=1")!
        let session = ProxySession(
            origin: URLOrigin(url: home)!,
            cookies: [.init(name: "authelia_session", value: "abc")]
        )
        let holder = ProxySessionHolder(session)

        #expect(holder.authenticating(URLRequest(url: home)).value(forHTTPHeaderField: "Cookie") == "authelia_session=abc")
        #expect(holder.authenticating(URLRequest(url: elsewhere)).value(forHTTPHeaderField: "Cookie") == nil)
    }
}
