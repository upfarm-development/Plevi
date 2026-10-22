import Foundation
import Testing
@testable import PleviTransport

@Suite("Telling an address that only works at home from one that works anywhere")
struct ServerAddressKindTests {
    @Test("The private ranges are on your network")
    func privateRangesAreLocal() {
        for host in ["10.0.0.4", "192.168.1.50", "172.16.0.1", "172.26.0.1",
                     "172.31.255.254", "127.0.0.1", "169.254.7.7", "100.100.1.1"] {
            #expect(ServerAddressKind(host: host) == .onYourNetwork, "\(host)")
        }
    }

    @Test("The addresses either side of 172.16/12 are not in it")
    func theEdgesOfTheAwkwardRange() {
        // The one range nobody remembers: 172.16 through 172.31, not the
        // whole of 172.
        #expect(ServerAddressKind(host: "172.15.0.1") == .fromAnywhere)
        #expect(ServerAddressKind(host: "172.32.0.1") == .fromAnywhere)
    }

    @Test("A public address is reachable from anywhere")
    func publicAddresses() {
        for host in ["203.0.113.7", "8.8.8.8", "1.1.1.1"] {
            #expect(ServerAddressKind(host: host) == .fromAnywhere, "\(host)")
        }
    }

    @Test("Plex writes the address into the name, and it is read back")
    func plexDirectNames() {
        // The case that started this: both of these are plex.direct names,
        // and the app called the first one local because of the slot it was
        // filed in rather than because of what it says.
        #expect(
            ServerAddressKind(host: "203-0-113-7.0123456789abcd.plex.direct") == .fromAnywhere
        )
        #expect(
            ServerAddressKind(host: "172-26-0-1.0123456789abcd.plex.direct") == .onYourNetwork
        )
    }

    @Test("A name that merely has dashes in it is not an address")
    func dashesAreNotAnAddress() {
        #expect(ServerAddressKind(host: "my-music-server.example.com") == .unknown)
        #expect(ServerAddressKind(host: "plex-1-2.example.com") == .unknown)
        // Four parts, but not four numbers.
        #expect(ServerAddressKind(host: "a-b-c-d.example.com") == .unknown)
        // Numbers, but out of range.
        #expect(ServerAddressKind(host: "999-1-1-1.example.com") == .unknown)
    }

    @Test("Names that only mean anything at home")
    func localNames() {
        for host in ["localhost", "nuc.local", "NUC.LOCAL", "box.home.arpa"] {
            #expect(ServerAddressKind(host: host) == .onYourNetwork, "\(host)")
        }
    }

    @Test("An ordinary domain gives nothing away, and says so")
    func ordinaryDomains() {
        #expect(ServerAddressKind(host: "music.example.com") == .unknown)
        #expect(ServerAddressKind(host: "") == .unknown)
        // Nil rather than a made-up label, so the caller can fall back to
        // whatever it called the address itself.
        #expect(ServerAddressKind.unknown.label == nil)
    }

    @Test("IPv6, both kinds")
    func ipv6() {
        #expect(ServerAddressKind(host: "::1") == .onYourNetwork)
        #expect(ServerAddressKind(host: "fe80::1") == .onYourNetwork)
        #expect(ServerAddressKind(host: "fd00::1234") == .onYourNetwork)
        #expect(ServerAddressKind(host: "2001:4860:4860::8888") == .fromAnywhere)
    }

    @Test("Read off a URL, brackets and all")
    func fromURLs() {
        #expect(URL(string: "https://172-26-0-1.abc.plex.direct:32400")!.addressKind == .onYourNetwork)
        #expect(URL(string: "https://203.0.113.7:32400")!.addressKind == .fromAnywhere)
        #expect(URL(string: "http://[fe80::1]:32400")!.addressKind == .onYourNetwork)
    }
}
