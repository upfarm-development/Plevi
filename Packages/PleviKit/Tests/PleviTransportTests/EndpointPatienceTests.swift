import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

/// A socket that accepts a connection and then never says anything.
private final class SilentSocket: @unchecked Sendable {
    let port: UInt16
    private let handle: Int32

    init?() {
        // Everything through a local: the closures below would otherwise
        // capture a `self` whose `port` is not set yet, which Swift refuses.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // Whatever is free.
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Listening, and never accepting. The backlog is what does the work.
        guard bound == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            return nil
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0 else {
            close(descriptor)
            return nil
        }
        handle = descriptor
        port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit { close(handle) }
}

/// A socket that answers, so the branch that picks the home address is covered too.
private final class AnsweringSocket: @unchecked Sendable {
    let port: UInt16
    private let handle: Int32

    init?() {
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
        guard bound == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            return nil
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0 else {
            close(descriptor)
            return nil
        }
        handle = descriptor
        port = UInt16(bigEndian: assigned.sin_port)

        // Closing the listener in `deinit` makes `accept` fail, which is how
        // this thread is told to stop.
        Thread.detachNewThread { [descriptor] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                var request = [UInt8](repeating: 0, count: 2048)
                _ = recv(client, &request, request.count, 0)
                // What a Subsonic server says to a request with no credentials, which is what the
                // probe now asks: an answer in its own envelope.
                let body = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":10,"message":"missing"}}}"#
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = reply.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }
    }

    deinit { close(handle) }
}

/// What the selector does when the home address does not answer.
@Suite("How long the home address is given")
struct EndpointPatienceTests {
    private static func config(local: URL, remote: URL) -> ServerConfig {
        ServerConfig(
            name: "Test",
            addresses: ServerAddresses(local: local, remote: remote)!
        )
    }

    @Test("A silent home address gives way to the remote one without waiting out the timeout")
    func silenceIsNotWaitedOut() async throws {
        let silent = try #require(SilentSocket())
        let local = URL(string: "http://127.0.0.1:\(silent.port)")!
        let remote = URL(string: "http://127.0.0.1:9")!
        let selector = EndpointSelector(config: Self.config(local: local, remote: remote))

        let started = ContinuousClock.now
        let chosen = await selector.activeBaseURL()
        let took = ContinuousClock.now - started

        #expect(chosen == remote, "a home address that says nothing is not the one to use")
        // Bounded on both sides on purpose.
        #expect(
            took > .milliseconds(800),
            "came back in \(took), so the socket refused rather than went quiet"
        )
        #expect(
            took < .seconds(2),
            "gave up after \(took), which is the timeout rather than the patience"
        )
        let choice = await selector.lastChoice
        #expect(choice?.isLocal == false)
        #expect(choice?.localHost == "127.0.0.1")
        #expect(
            choice?.localFailure == "The home address did not answer in time.",
            "a screen showing this needs the patience's own reason, not the system's"
        )
        // The listener has to outlive the probe, and nothing above reads it
        // after the first line.
        withExtendedLifetime(silent) {}
    }

    @Test("A home address that answers is the one used")
    func answeringHomeAddressWins() async throws {
        let listening = try #require(AnsweringSocket())
        let local = URL(string: "http://127.0.0.1:\(listening.port)")!
        // Discard. If this were ever chosen the test would say so, and if
        // anything ever probed it the refusal would be immediate.
        let remote = URL(string: "http://127.0.0.1:9")!
        let selector = EndpointSelector(config: Self.config(local: local, remote: remote))

        let started = ContinuousClock.now
        let chosen = await selector.activeBaseURL()
        let took = ContinuousClock.now - started

        #expect(chosen == local, "the home address answered and should have been used")
        #expect(took < .milliseconds(800), "a local answer took \(took)")
        let choice = await selector.lastChoice
        #expect(choice?.isLocal == true)
        #expect(choice?.localFailure == nil, "nothing failed, so nothing to report")
        withExtendedLifetime(listening) {}
    }

    @Test("The answer is reused rather than probed again")
    func theChoiceIsRemembered() async throws {
        let listening = try #require(AnsweringSocket())
        let local = URL(string: "http://127.0.0.1:\(listening.port)")!
        let remote = URL(string: "http://127.0.0.1:9")!
        let selector = EndpointSelector(config: Self.config(local: local, remote: remote))

        #expect(await selector.activeBaseURL() == local)
        let started = ContinuousClock.now
        #expect(await selector.activeBaseURL() == local)
        #expect(
            ContinuousClock.now - started < .milliseconds(50),
            "the second ask should be answered from the last thirty seconds, not the network"
        )
        withExtendedLifetime(listening) {}
    }

    @Test("A home address that refuses outright is not waited on at all")
    func refusalIsImmediate() async throws {
        // Port 9 is discard; nothing listens, so the connection is refused
        // rather than ignored. That path was already correct and is here so
        // a change to the patience cannot quietly slow it down.
        let local = URL(string: "http://127.0.0.1:9")!
        let remote = URL(string: "http://127.0.0.1:10")!
        let selector = EndpointSelector(config: Self.config(local: local, remote: remote))

        let started = ContinuousClock.now
        let chosen = await selector.activeBaseURL()
        let took = ContinuousClock.now - started

        #expect(chosen == remote)
        #expect(took < .milliseconds(500), "a refusal took \(took)")
    }

    @Test("One address is used without probing anything")
    func nothingToChooseBetween() async throws {
        let only = URL(string: "http://127.0.0.1:9")!
        let selector = EndpointSelector(
            config: ServerConfig(name: "Test", addresses: .remote(only))
        )
        let started = ContinuousClock.now
        let chosen = await selector.activeBaseURL()
        #expect(chosen == only)
        #expect(ContinuousClock.now - started < .milliseconds(100))
    }
}
