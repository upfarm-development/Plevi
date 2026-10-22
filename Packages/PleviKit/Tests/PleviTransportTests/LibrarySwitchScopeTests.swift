import Foundation
import Testing
@testable import PleviTransport

@Suite("Which libraries a server can be switched to")
struct LibrarySwitchScopeTests {
    private static let address = ServerAddresses.remote(URL(string: "https://music.example.com")!)

    private static func plex(machine: String, key: String = "1") -> ServerConfig {
        ServerConfig(
            name: "Plex", addresses: address, kind: .plex,
            library: LibrarySelection(key: key, title: "Music", machineIdentifier: machine)
        )
    }

    private static let subsonic = ServerConfig(name: "Navidrome", addresses: address)

    private static let list = [
        LibrarySelection(key: "1", title: "Music", machineIdentifier: "machine-A"),
        LibrarySelection(key: "2", title: "Kids", machineIdentifier: "machine-A"),
        LibrarySelection(key: "1", title: "Other music", machineIdentifier: "machine-B"),
        LibrarySelection(key: "9", title: "Legacy", machineIdentifier: ""),
    ]

    @Test("A Plex server is offered only its own machine's libraries")
    func plexSeesItsOwn() {
        let a = Self.plex(machine: "machine-A")
        #expect(a.quickSwitchChoices(from: Self.list).map(\.title) == ["Music", "Kids"])
        let b = Self.plex(machine: "machine-B")
        #expect(b.quickSwitchChoices(from: Self.list).map(\.title) == ["Other music"])
    }

    @Test("A Navidrome server is offered nothing")
    func subsonicSeesNothing() {
        #expect(Self.subsonic.quickSwitchChoices(from: Self.list).isEmpty)
        #expect(!Self.subsonic.offers(Self.list[0]))
    }

    @Test("A Plex server with no library chosen yet is offered nothing")
    func noLibraryYet() {
        let bare = ServerConfig(name: "Plex", addresses: Self.address, kind: .plex)
        #expect(bare.quickSwitchChoices(from: Self.list).isEmpty)
    }

    @Test("An empty machine identifier matches nothing, even another empty one")
    func emptyIdentifierMatchesNothing() {
        let legacy = Self.plex(machine: "")
        #expect(legacy.quickSwitchChoices(from: Self.list).isEmpty)
        #expect(!Self.plex(machine: "machine-A").offers(Self.list[3]))
    }

    @Test("The same section key on another machine is not the same library")
    func sameKeyDifferentMachine() {
        let a = Self.plex(machine: "machine-A", key: "1")
        #expect(!a.offers(LibrarySelection(key: "1", title: "Music", machineIdentifier: "machine-B")))
        #expect(a.offers(LibrarySelection(key: "1", title: "Music", machineIdentifier: "machine-A")))
    }
}
