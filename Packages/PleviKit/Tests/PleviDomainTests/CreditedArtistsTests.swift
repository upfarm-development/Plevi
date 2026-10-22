import Foundation
import Testing
@testable import PleviDomain

@Suite("The people named in a credit")
struct CreditedArtistsTests {
    private static let server = ServerID(rawValue: UUID())

    private func artist(_ name: String) -> Artist {
        Artist(id: MediaID(server: Self.server, rawValue: name.lowercased()), name: name)
    }

    /// Stands in for the index: knows the names given to it and nothing else.
    private func library(_ names: String...) -> (String) -> Artist? {
        let known = Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), artist($0)) })
        return { known[$0.lowercased()] }
    }

    @Test("A credit naming one person is one name")
    func single() {
        #expect(CreditedArtists.names(in: "Belinda Carlisle") == ["Belinda Carlisle"])
    }

    @Test("Ampersands, commas and features all separate")
    func separators() {
        let names = CreditedArtists.names(in: "Berliner Philharmoniker & Herbert von Karajan")
        #expect(names.contains("Berliner Philharmoniker"))
        #expect(names.contains("Herbert von Karajan"))

        let jazz = CreditedArtists.names(in: "Curtis Fuller, Tommy Flanagan, Benny Golson")
        #expect(jazz.contains("Curtis Fuller"))
        #expect(jazz.contains("Tommy Flanagan"))
        #expect(jazz.contains("Benny Golson"))

        let guest = CreditedArtists.names(in: "Queen feat. David Bowie")
        #expect(guest.contains("Queen"))
        #expect(guest.contains("David Bowie"))
    }

    /// The whole credit leads, so a caller resolving in order meets it first.
    @Test("The whole credit is always offered before its pieces")
    func wholeCreditFirst() {
        let names = CreditedArtists.names(in: "Emerson, Lake & Palmer")
        #expect(names.first == "Emerson, Lake & Palmer")
    }

    /// A band with a separator in its name is one act, not three — and the
    /// library is what settles it.
    @Test("A band whose name has a comma in it stays one artist")
    func bandWithASeparatorInItsName() {
        let found = CreditedArtists.named(
            in: "Emerson, Lake & Palmer",
            resolve: library("Emerson, Lake & Palmer", "Palmer")
        )
        #expect(found.map(\.name) == ["Emerson, Lake & Palmer"])
    }

    @Test("Several people the library knows are all offered, in written order")
    func severalKnownPeople() {
        let found = CreditedArtists.named(
            in: "Berliner Philharmoniker & Herbert von Karajan & Edvard Grieg",
            resolve: library("Berliner Philharmoniker", "Herbert von Karajan", "Edvard Grieg")
        )
        #expect(found.map(\.name) == [
            "Berliner Philharmoniker", "Herbert von Karajan", "Edvard Grieg",
        ])
    }

    /// A name nobody has heard of is no use as a destination.
    @Test("Names the library does not hold are left out")
    func unknownNamesAreDropped() {
        let found = CreditedArtists.named(
            in: "Queen feat. Somebody Else",
            resolve: library("Queen")
        )
        #expect(found.map(\.name) == ["Queen"])
    }

    @Test("The same person credited twice is offered once")
    func noRepeats() {
        let found = CreditedArtists.named(
            in: "Queen & Queen",
            resolve: library("Queen")
        )
        #expect(found.count == 1)
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(CreditedArtists.names(in: "   ").isEmpty)
        #expect(CreditedArtists.named(in: "", resolve: { _ in nil }).isEmpty)
    }
}
