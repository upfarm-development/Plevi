import Foundation
import Testing
@testable import PleviTransport

@Suite struct ProxySessionTests {
    private let remote = URL(string: "https://music.example.com")!

    private func session(
        for url: URL? = nil,
        cookies: [ProxySession.Cookie] = [.init(name: "p_session", value: "abc123")],
        expiresAt: Date? = nil
    ) -> ProxySession {
        ProxySession(
            origin: URLOrigin(url: url ?? remote)!,
            cookies: cookies,
            expiresAt: expiresAt
        )
    }

    @Test func headerJoinsCookiesTheWayABrowserWould() {
        let session = session(cookies: [
            .init(name: "p_session", value: "abc"),
            .init(name: "csrf", value: "def"),
        ])
        #expect(session.headerValue == "p_session=abc; csrf=def")
    }

    // MARK: Origin scoping

    @Test func appliesToItsOwnOrigin() {
        #expect(session().applies(to: URL(string: "https://music.example.com/rest/ping.view")!))
    }

    @Test func neverAppliesToADifferentHost() {
        #expect(!session().applies(to: URL(string: "https://elsewhere.example.com/rest/ping.view")!))
    }

    /// The local address is the whole reason this is origin-scoped: it is the
    /// same server over a different path, and whatever answers on the LAN must
    /// not be handed the remote proxy's session.
    @Test func neverAppliesToTheLocalAddress() {
        #expect(!session().applies(to: URL(string: "http://192.168.1.20:4533/rest/ping.view")!))
    }

    @Test func neverAppliesOverPlainHTTPOnTheSameHost() {
        #expect(!session().applies(to: URL(string: "http://music.example.com/rest/ping.view")!))
    }

    @Test func neverAppliesToADifferentPort() {
        #expect(!session().applies(to: URL(string: "https://music.example.com:8443/rest/ping.view")!))
    }

    // MARK: Expiry

    @Test func aSessionWithNoStatedExpiryIsValid() {
        #expect(session().isValid())
    }

    @Test func anExpiredSessionIsNotValid() {
        let expired = session(expiresAt: Date(timeIntervalSinceNow: -1))
        #expect(!expired.isValid())
    }

    /// Expiring inside the margin counts as expired, so a request does not set
    /// off with a cookie that lapses before the response comes back.
    @Test func aSessionAboutToExpireIsAlreadyTreatedAsExpired() {
        let soon = session(expiresAt: Date(timeIntervalSinceNow: ProxySession.expiryMargin / 2))
        #expect(!soon.isValid())
    }

    @Test func aSessionWithNoCookiesIsNeverValid() {
        #expect(!session(cookies: []).isValid())
    }

    // MARK: Holder

    @Test func holderWithholdsTheSessionFromOtherOrigins() {
        let holder = ProxySessionHolder(session())
        #expect(holder.session(for: URL(string: "https://music.example.com/rest/ping.view")!) != nil)
        #expect(holder.session(for: URL(string: "http://192.168.1.20:4533/rest/ping.view")!) == nil)
    }

    @Test func holderWithholdsAnExpiredSession() {
        let holder = ProxySessionHolder(session(expiresAt: Date(timeIntervalSinceNow: -1)))
        #expect(holder.session(for: URL(string: "https://music.example.com/rest/ping.view")!) == nil)
    }

    @Test func holderCanBeClearedAndReplaced() {
        let holder = ProxySessionHolder()
        #expect(holder.session(for: remote) == nil)
        holder.set(session())
        #expect(holder.session(for: remote) != nil)
        holder.set(nil)
        #expect(holder.session(for: remote) == nil)
    }

    @Test func roundTripsThroughCodableForTheKeychain() throws {
        let original = session(expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxySession.self, from: data)
        #expect(decoded == original)
    }
}

@Suite struct ProxySessionRequestTests {
    private let remote = URL(string: "https://music.example.com")!

    private func holder() -> ProxySessionHolder {
        ProxySessionHolder(ProxySession(
            origin: URLOrigin(url: remote)!,
            cookies: [.init(name: "p_session", value: "abc123")]
        ))
    }

    @Test func attachesTheCookieForItsOwnOrigin() {
        let request = URLRequest(url: URL(string: "https://music.example.com/rest/stream?id=1")!)
        let authenticated = holder().authenticating(request)
        #expect(authenticated.value(forHTTPHeaderField: "Cookie") == "p_session=abc123")
    }

    /// Media is loaded by AVFoundation rather than through the transport, so
    /// this is the path that keeps playback working behind an SSO proxy.
    @Test func attachesNothingForTheLocalAddress() {
        let request = URLRequest(url: URL(string: "http://192.168.1.20:4533/rest/stream?id=1")!)
        let authenticated = holder().authenticating(request)
        #expect(authenticated.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func leavesOtherHeadersAlone() {
        var request = URLRequest(url: URL(string: "https://music.example.com/rest/stream?id=1")!)
        request.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        let authenticated = holder().authenticating(request)
        #expect(authenticated.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(authenticated.value(forHTTPHeaderField: "Cookie") == "p_session=abc123")
    }

    @Test func attachesNothingWithoutASession() {
        let request = URLRequest(url: URL(string: "https://music.example.com/rest/stream?id=1")!)
        #expect(ProxySessionHolder().authenticating(request).value(forHTTPHeaderField: "Cookie") == nil)
    }
}
