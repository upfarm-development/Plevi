import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

@Suite("Naming a library across installs")
struct LibraryFingerprintTests {
    private func plex(id: ServerID = ServerID(), machine: String, key: String, remote: String = "https://plex.example.com:32400") -> ServerConfig {
        ServerConfig(
            id: id, name: "Plex",
            addresses: .remote(URL(string: remote)!),
            kind: .plex,
            library: LibrarySelection(key: key, title: "Music", machineIdentifier: machine)
        )
    }

    @Test func theSameLibraryOnANewInstallHasTheSameName() {
        // A different ServerID each time: that is what a reinstall does.
        let first = LibraryFingerprint.of(config: plex(machine: "abc", key: "3"), username: nil)
        let second = LibraryFingerprint.of(config: plex(machine: "abc", key: "3"), username: nil)
        #expect(first != nil)
        #expect(first == second)
    }

    @Test func otherLibrariesAndServersHaveOtherNames() {
        let base = LibraryFingerprint.of(config: plex(machine: "abc", key: "3"), username: nil)
        #expect(base != LibraryFingerprint.of(config: plex(machine: "abc", key: "4"), username: nil))
        #expect(base != LibraryFingerprint.of(config: plex(machine: "xyz", key: "3"), username: nil))
    }

    @Test func aPlexLibraryIsTheSameFromHomeAndAway() {
        let away = plex(machine: "abc", key: "3", remote: "https://plex.example.com:32400")
        var home = away
        home.addresses = .both(local: URL(string: "http://192.168.1.4:32400")!, remote: URL(string: "https://plex.example.com:32400")!)
        #expect(LibraryFingerprint.of(config: away, username: nil) == LibraryFingerprint.of(config: home, username: nil))
    }

    @Test func aSubsonicLibraryIsNamedByServerAndAccount() {
        func navidrome(_ url: String) -> ServerConfig {
            ServerConfig(name: "Navidrome", addresses: .remote(URL(string: url)!))
        }
        let alice = LibraryFingerprint.of(config: navidrome("https://Music.Example.com"), username: "alice")
        #expect(alice == LibraryFingerprint.of(config: navidrome("https://music.example.com:443"), username: "alice"))
        #expect(alice != LibraryFingerprint.of(config: navidrome("https://music.example.com"), username: "guest"))
        #expect(alice != LibraryFingerprint.of(config: navidrome("https://other.example.com"), username: "alice"))
        // Hashed, not spelled out in the iCloud document.
        #expect(alice?.contains("alice") == false)
        #expect(alice?.contains("example") == false)
    }

    @Test func aPlexEntryWithNoLibraryChosenHasNoName() {
        var config = plex(machine: "abc", key: "3")
        config.library = nil
        #expect(LibraryFingerprint.of(config: config, username: nil) == nil)
    }
}
