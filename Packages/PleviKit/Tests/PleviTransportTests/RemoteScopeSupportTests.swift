import Foundation
import Testing
@testable import PleviTransport

/// `ServerConfig.accountID`: a Plex config's own
/// scope value for Remote Control's iCloud check.
@Suite struct ServerConfigAccountIDTests {
    private func config(accountID: String? = nil) -> ServerConfig {
        ServerConfig(name: "Home", addresses: .local(URL(string: "http://192.168.1.5:32400")!), kind: .plex, accountID: accountID)
    }

    @Test func roundTripsThroughCoding() throws {
        let encoded = try JSONEncoder().encode(config(accountID: "acc-123"))
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: encoded)
        #expect(decoded.accountID == "acc-123")
    }

    /// A server saved before step 5 has no `accountID` key at all — must
    /// still decode, with `accountID == nil`, not be dropped or thrown away.
    @Test func aConfigSavedBeforeAccountIDExistedStillDecodes() throws {
        let legacy = config()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object["accountID"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)
        #expect(decoded.accountID == nil)
        #expect(decoded.id == legacy.id)
    }
}

/// `HTTPTransport.isDirect`: whether `perform` would attach a proxy
/// session's cookie — the transport's half of "direct"; a custom header is the caller's own, which
/// `ServerHTTPTransport` cannot see.
@Suite struct ServerHTTPTransportIsDirectTests {
    private let origin = URL(string: "https://music.example.com")!

    private func config() -> ServerConfig {
        ServerConfig(name: "Home", addresses: .remote(origin))
    }

    @Test func noCapturedSessionIsDirect() {
        let transport = ServerHTTPTransport(config: config(), proxySessions: ProxySessionHolder())
        #expect(transport.isDirect(URLRequest(url: origin)))
    }

    @Test func aCapturedSessionForThatOriginIsNotDirect() throws {
        let holder = ProxySessionHolder()
        holder.set(ProxySession(
            origin: try #require(URLOrigin(url: origin)),
            cookies: [.init(name: "p_session", value: "abc")]
        ))
        let transport = ServerHTTPTransport(config: config(), proxySessions: holder)
        #expect(!transport.isDirect(URLRequest(url: origin)))
    }

    /// A session captured for a *different* origin (the remote address,
    /// say) must not make a request to the local one look indirect.
    @Test func aSessionForAnotherOriginLeavesThisOneDirect() throws {
        let holder = ProxySessionHolder()
        holder.set(ProxySession(
            origin: try #require(URLOrigin(url: URL(string: "https://elsewhere.example.com")!)),
            cookies: [.init(name: "p_session", value: "abc")]
        ))
        let transport = ServerHTTPTransport(config: config(), proxySessions: holder)
        #expect(transport.isDirect(URLRequest(url: origin)))
    }

    /// The protocol's own default, for a transport with no notion of a
    /// proxy at all (every test fake).
    @Test func theProtocolDefaultIsAlwaysDirect() {
        struct Bare: HTTPTransport {
            func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                fatalError("unused")
            }
        }
        #expect(Bare().isDirect(URLRequest(url: origin)))
    }
}
