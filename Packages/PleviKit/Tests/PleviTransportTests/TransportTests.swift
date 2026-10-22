import Foundation
import Security
import CryptoKit
import Testing
import PleviDomain
@testable import PleviTransport

// MARK: - Endpoint validation

@Suite struct EndpointValidationTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test func acceptsHTTPSAnywhere() {
        #expect(EndpointValidation.validate(url("https://music.example.com")) == nil)
        #expect(EndpointValidation.validate(url("https://192.168.1.5:4533")) == nil)
    }

    @Test func rejectsPlainHTTPToPublicHosts() {
        #expect(
            EndpointValidation.validate(url("http://music.example.com")) == .plainHTTPToPublicHost
        )
        #expect(
            EndpointValidation.validate(url("http://8.8.8.8:4533")) == .plainHTTPToPublicHost
        )
    }

    @Test func toleratesPlainHTTPOnPrivateNetworks() {
        #expect(EndpointValidation.validate(url("http://192.168.1.5:4533")) == nil)
        #expect(EndpointValidation.validate(url("http://10.0.0.2")) == nil)
        #expect(EndpointValidation.validate(url("http://172.20.0.1")) == nil)
        #expect(EndpointValidation.validate(url("http://navidrome.local:4533")) == nil)
        #expect(EndpointValidation.validate(url("http://localhost:4533")) == nil)
        #expect(EndpointValidation.validate(url("http://server.home.arpa")) == nil)
    }

    @Test func recognizes172RangeBoundaries() {
        #expect(EndpointValidation.isPrivateHost("172.16.0.1"))
        #expect(EndpointValidation.isPrivateHost("172.31.255.1"))
        #expect(!EndpointValidation.isPrivateHost("172.32.0.1"))
        #expect(!EndpointValidation.isPrivateHost("172.15.0.1"))
    }

    @Test func rejectsEmbeddedCredentials() {
        #expect(
            EndpointValidation.validate(url("https://admin:hunter2@music.example.com")) == .embedsCredentials
        )
    }

    @Test func rejectsNonHTTPSchemes() {
        #expect(EndpointValidation.validate(url("ftp://music.example.com")) == .notHTTPURL)
    }
}

// MARK: - Address input interpretation

@Suite struct AddressInputTests {
    @Test func explicitSchemeIsRespected() {
        let candidates = EndpointValidation.candidateURLs(forUserInput: "http://192.168.1.20:4533")
        #expect(candidates.map(\.absoluteString) == ["http://192.168.1.20:4533"])
    }

    @Test func barePrivateAddressTriesHTTPSThenHTTP() {
        let candidates = EndpointValidation.candidateURLs(forUserInput: "192.168.1.20:4533")
        #expect(candidates.map(\.absoluteString) == [
            "https://192.168.1.20:4533",
            "http://192.168.1.20:4533",
        ])
    }

    @Test func barePublicHostOnlyGetsHTTPS() {
        let candidates = EndpointValidation.candidateURLs(forUserInput: "music.example.com")
        #expect(candidates.map(\.absoluteString) == ["https://music.example.com"])
    }

    @Test func whitespaceAndEmptyInputsHandled() {
        #expect(EndpointValidation.candidateURLs(forUserInput: "  ").isEmpty)
        let candidates = EndpointValidation.candidateURLs(forUserInput: " navidrome.local ")
        #expect(candidates.first?.absoluteString == "https://navidrome.local")
    }

}

// MARK: - Origins

@Suite struct URLOriginTests {
    @Test func defaultsPortsByScheme() {
        let https = URLOrigin(url: URL(string: "https://example.com/rest/ping")!)
        #expect(https?.port == 443)
        let http = URLOrigin(url: URL(string: "http://example.com")!)
        #expect(http?.port == 80)
        let custom = URLOrigin(url: URL(string: "https://example.com:8443")!)
        #expect(custom?.port == 8443)
    }

    @Test func matchingIgnoresPathAndCase() {
        let origin = URLOrigin(url: URL(string: "https://Music.Example.com")!)
        #expect(origin?.matches(URL(string: "https://music.example.com/rest/stream?id=1")!) == true)
        #expect(origin?.matches(URL(string: "https://other.example.com/rest/stream")!) == false)
        #expect(origin?.matches(URL(string: "http://music.example.com/rest/stream")!) == false)
        #expect(origin?.matches(URL(string: "https://music.example.com:8443/x")!) == false)
    }

    @Test func serverConfigCollectsBothOrigins() {
        let config = ServerConfig(
            name: "Home",
            addresses: .both(
                local: URL(string: "http://192.168.1.5:4533")!,
                remote: URL(string: "https://music.example.com")!
            )
        )
        #expect(config.allowedOrigins.count == 2)
    }
}

// MARK: - Address model

@Suite struct ServerAddressesTests {
    private let lan = URL(string: "http://192.168.1.20:4533")!
    private let wan = URL(string: "https://music.example.com")!

    @Test func requiresAtLeastOneAddress() {
        #expect(ServerAddresses(local: nil, remote: nil) == nil)
        #expect(ServerAddresses(local: lan, remote: nil) == .local(lan))
        #expect(ServerAddresses(local: nil, remote: wan) == .remote(wan))
        #expect(ServerAddresses(local: lan, remote: wan) == .both(local: lan, remote: wan))
    }

    @Test func localIsPreferredWhenBothConfigured() {
        #expect(ServerAddresses.both(local: lan, remote: wan).preferred == lan)
        #expect(ServerAddresses.both(local: lan, remote: wan).inPreferenceOrder == [lan, wan])
    }

    @Test func singleAddressIsItsOwnPreference() {
        #expect(ServerAddresses.remote(wan).preferred == wan)
        #expect(ServerAddresses.remote(wan).local == nil)
        #expect(ServerAddresses.local(lan).preferred == lan)
        #expect(ServerAddresses.local(lan).remote == nil)
    }

    @Test func roundTripsThroughCoding() throws {
        let addresses = ServerAddresses.both(local: lan, remote: wan)
        let decoded = try JSONDecoder().decode(
            ServerAddresses.self,
            from: JSONEncoder().encode(addresses)
        )
        #expect(decoded == addresses)
    }
}

// MARK: - Per-origin certificate pinning

@Suite struct PinnedCertificateTests {
    private func config(pins: [PinnedCertificate]) -> ServerConfig {
        ServerConfig(
            name: "Home",
            addresses: .both(
                local: URL(string: "https://192.168.1.20:4533")!,
                remote: URL(string: "https://music.example.com")!
            ),
            pinnedCertificates: pins
        )
    }

    @Test func pinIsFoundOnlyForItsOwnOrigin() throws {
        let lanOrigin = try #require(URLOrigin(url: URL(string: "https://192.168.1.20:4533")!))
        let pin = Data(repeating: 0xAB, count: 32)
        let server = config(pins: [PinnedCertificate(origin: lanOrigin, sha256: pin)])

        #expect(server.pin(forHost: "192.168.1.20", port: 4533) == pin)
        // The remote address must fall through to ordinary system trust,
        // otherwise a self-signed LAN cert would break the public one.
        #expect(server.pin(forHost: "music.example.com", port: 443) == nil)
        #expect(server.pin(forHost: "192.168.1.20", port: 443) == nil)
    }

    @Test func hostMatchingIsCaseInsensitive() throws {
        let origin = try #require(URLOrigin(url: URL(string: "https://Music.Example.com")!))
        let pin = Data(repeating: 0x01, count: 32)
        let server = config(pins: [PinnedCertificate(origin: origin, sha256: pin)])
        #expect(server.pin(forHost: "MUSIC.EXAMPLE.COM", port: 443) == pin)
    }

    @Test func eachAddressCanCarryItsOwnPin() throws {
        let lanOrigin = try #require(URLOrigin(url: URL(string: "https://192.168.1.20:4533")!))
        let wanOrigin = try #require(URLOrigin(url: URL(string: "https://music.example.com")!))
        let lanPin = Data(repeating: 0x0A, count: 32)
        let wanPin = Data(repeating: 0x0B, count: 32)
        let server = config(pins: [
            PinnedCertificate(origin: lanOrigin, sha256: lanPin),
            PinnedCertificate(origin: wanOrigin, sha256: wanPin),
        ])
        #expect(server.pin(forHost: "192.168.1.20", port: 4533) == lanPin)
        #expect(server.pin(forHost: "music.example.com", port: 443) == wanPin)
    }
}

// MARK: - Redaction

@Suite struct RedactorTests {
    @Test func masksSensitiveQueryValues() {
        let url = URL(string: "https://host/rest/ping?u=alice&t=deadbeef&s=abc123&v=1.16.1&c=Plevi")!
        let redacted = Redactor.redacted(url)
        #expect(!redacted.contains("alice"))
        #expect(!redacted.contains("deadbeef"))
        #expect(!redacted.contains("abc123"))
        #expect(redacted.contains("v=1.16.1"))
        #expect(redacted.contains("c=Plevi"))
    }

    @Test func masksAreCaseInsensitive() {
        let url = URL(string: "https://host/x?ApiKey=secret&TOKEN=alsosecret")!
        let redacted = Redactor.redacted(url)
        #expect(!redacted.contains("secret"))
        #expect(!redacted.contains("alsosecret"))
    }

    @Test func stripsUserinfo() {
        let url = URL(string: "https://user:pass@host/x")!
        let redacted = Redactor.redacted(url)
        #expect(!redacted.contains("user"))
        #expect(!redacted.contains("pass"))
    }

    @Test func masksSensitiveHeaders() {
        var request = URLRequest(url: URL(string: "https://host/x")!)
        request.setValue("Bearer topsecret", forHTTPHeaderField: "Authorization")
        request.setValue("cf-secret-value", forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue("client-id-ok", forHTTPHeaderField: "CF-Access-Client-Id")
        let redacted = Redactor.redacted(request)
        #expect(!redacted.contains("topsecret"))
        #expect(!redacted.contains("cf-secret-value"))
        #expect(redacted.contains("client-id-ok"))
    }
}

// MARK: - Trust evaluation

@Suite struct ServerTrustTests {
    private func loadCertificate(named name: String) throws -> (SecCertificate, Data) {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "der",
            subdirectory: "Fixtures"
        ))
        let der = try Data(contentsOf: url)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        return (certificate, der)
    }

    private func makeTrust(certificate: SecCertificate, host: String) throws -> SecTrust {
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        let status = SecTrustCreateWithCertificates(certificate, policy, &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    @Test func fingerprintFormatMatchesKnownVector() {
        // SHA-256("abc") is a published test vector.
        let fingerprint = ServerTrustEvaluator.fingerprintSHA256(ofDER: Data("abc".utf8))
        #expect(fingerprint.hasPrefix("ba:78:16:bf:8f:01:cf:ea"))
        #expect(fingerprint.split(separator: ":").count == 32)
    }

    @Test func pinnedCertificateIsAccepted() throws {
        let (certificate, der) = try loadCertificate(named: "test-cert")
        let trust = try makeTrust(certificate: certificate, host: "test.local")
        let pin = Data(SHA256.hash(data: der))
        #expect(ServerTrustEvaluator.evaluate(trust, pin: pin) == .accept)
    }

    @Test func wrongPinIsRejectedWithBothFingerprints() throws {
        let (certificate, der) = try loadCertificate(named: "test-cert")
        let (_, otherDER) = try loadCertificate(named: "other-cert")
        let trust = try makeTrust(certificate: certificate, host: "test.local")
        let wrongPin = Data(SHA256.hash(data: otherDER))
        let verdict = ServerTrustEvaluator.evaluate(trust, pin: wrongPin)
        let expectedActual = ServerTrustEvaluator.fingerprintSHA256(ofDER: der)
        let expectedExpected = ServerTrustEvaluator.fingerprintSHA256(ofDER: otherDER)
        #expect(verdict == .reject(.pinMismatch(expected: expectedExpected, actual: expectedActual)))
    }

    @Test func unpinnedOriginFallsBackToSystemTrust() throws {
        let (certificate, der) = try loadCertificate(named: "test-cert")
        let trust = try makeTrust(certificate: certificate, host: "test.local")
        let verdict = ServerTrustEvaluator.evaluate(trust, pin: nil)
        let fingerprint = ServerTrustEvaluator.fingerprintSHA256(ofDER: der)
        // Self-signed, so system trust rejects it — and reports the
        // fingerprint the approval sheet shows.
        #expect(verdict == .reject(.certificateNotTrusted(fingerprintSHA256: fingerprint)))
    }
}

/// The slot an address is stored in is not a claim about the address.
@Suite struct ServerAddressProbeOrderTests {
    private let lan = URL(string: "https://192-168-1-10.hash.plex.direct:32400")!
    private let wan = URL(string: "https://203-0-113-7.hash.plex.direct:32400")!

    @Test func probesThePrivateAddressEvenWhenItIsStoredAsTheRemoteOne() throws {
        // What a server added from a train looks like: the public address
        // answered, so setup filed it as "local".
        let addresses = ServerAddresses.both(local: wan, remote: lan)
        let order = try #require(addresses.probeOrder)
        #expect(order.first == lan)
        #expect(order.second == wan)
    }

    @Test func leavesTheOrdinaryCaseAlone() throws {
        let order = try #require(ServerAddresses.both(local: lan, remote: wan).probeOrder)
        #expect(order.first == lan)
        #expect(order.second == wan)
    }

    @Test func leavesAPairItCannotJudgeAlone() throws {
        let named = URL(string: "https://music.example.com")!
        let other = URL(string: "https://backup.example.com")!
        let order = try #require(ServerAddresses.both(local: named, remote: other).probeOrder)
        #expect(order.first == named)
    }

    @Test func twoPrivateAddressesKeepTheirStoredOrder() throws {
        let docker = URL(string: "https://172-26-0-1.hash.plex.direct:32400")!
        let order = try #require(ServerAddresses.both(local: docker, remote: lan).probeOrder)
        #expect(order.first == docker)
    }

    @Test func oneAddressHasNothingToOrder() {
        #expect(ServerAddresses.local(lan).probeOrder == nil)
        #expect(ServerAddresses.remote(wan).probeOrder == nil)
    }
}

/// Repairing the address a server is reached at on its own network must
/// never cost it the address that works from anywhere else.
@Suite struct ReplacingLocalAddressTests {
    private let bridge = URL(string: "https://172-26-0-1.hash.plex.direct:32400")!
    private let lan = URL(string: "https://192-168-1-10.hash.plex.direct:32400")!
    private let wan = URL(string: "https://203-0-113-7.hash.plex.direct:32400")!

    @Test func replacesABridgeAddressAndKeepsTheRemoteOne() {
        let repaired = ServerAddresses.both(local: bridge, remote: wan).replacingLocal(with: lan)
        #expect(repaired == .both(local: lan, remote: wan))
    }

    @Test func keepsAPublicAddressItIsDisplacingFromTheLocalSlot() {
        // What an entry added away from home looks like: the public address
        // answered, so it was filed as "local", and there is nothing else.
        let repaired = ServerAddresses.local(wan).replacingLocal(with: lan)
        #expect(repaired == .both(local: lan, remote: wan))
    }

    @Test func doesNotKeepAPrivateAddressItIsDisplacing() {
        // A bridge interface giving way to a real address is no loss.
        let repaired = ServerAddresses.local(bridge).replacingLocal(with: lan)
        #expect(repaired == .local(lan))
    }

    @Test func leavesAnExistingRemoteAddressAloneRatherThanPreferringTheDisplacedOne() {
        let repaired = ServerAddresses.both(local: wan, remote: bridge).replacingLocal(with: lan)
        #expect(repaired == .both(local: lan, remote: bridge))
    }

    @Test func aServerWithOnlyARemoteAddressGainsALocalOne() {
        let repaired = ServerAddresses.remote(wan).replacingLocal(with: lan)
        #expect(repaired == .both(local: lan, remote: wan))
    }
}

@Suite struct ReplacingLocalAddressEdgeTests {
    private let bridge = URL(string: "https://172-26-0-1.hash.plex.direct:32400")!
    private let lan = URL(string: "https://192-168-1-10.hash.plex.direct:32400")!

    @Test func neverFilesTheSameAddressInBothSlots() {
        // The good address was only ever the fallback; repairing the local
        // slot with it must not leave it standing as its own fallback too.
        let repaired = ServerAddresses.both(local: bridge, remote: lan).replacingLocal(with: lan)
        #expect(repaired == .local(lan))
    }
}
