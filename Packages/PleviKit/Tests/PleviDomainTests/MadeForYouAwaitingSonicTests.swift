import Foundation
import Testing
@testable import PleviDomain

/// A shelf built on a cold launch, before there is a server to ask, must not
/// be treated as finished.
@Suite("Made For You shelves that are still owed a server answer")
struct MadeForYouAwaitingSonicTests {
    private static let server = ServerID()

    private static func artistMix(_ name: String) -> MadeForYou.Mix {
        MadeForYou.Mix(kind: .artist(
            name: name, artistID: nil, seeds: [MediaID(server: server, rawValue: "\(name)-1")]
        ))
    }

    @Test("A shelf stored before the field existed decodes as settled")
    func oldBlobIsSettled() throws {
        let old = """
        {"mixes":[],"period":12}
        """
        let shelf = try JSONDecoder().decode(MadeForYou.Shelf.self, from: Data(old.utf8))
        #expect(shelf.awaitingSonic.isEmpty)
        #expect(shelf.period == 12)
    }

    @Test("What a shelf is still owed survives a round trip")
    func roundTrip() throws {
        let shelf = MadeForYou.Shelf(
            mixes: [Self.artistMix("Aretha")], period: 40, awaitingSonic: ["artist:aretha"]
        )
        let decoded = try JSONDecoder().decode(
            MadeForYou.Shelf.self, from: JSONEncoder().encode(shelf)
        )
        #expect(decoded == shelf)
    }

    @Test("The mixes to name are the new ones plus those a past run could not finish")
    func targets() {
        let aretha = Self.artistMix("Aretha")
        let oscar = Self.artistMix("Oscar")
        let natasha = Self.artistMix("Natasha")
        let stored = MadeForYou.Shelf(
            mixes: [aretha, oscar], period: 5, awaitingSonic: [aretha.id, "artist:gone"]
        )
        let assembly = MadeForYou.Assembly(
            mixes: [natasha, aretha, oscar], newlyArrived: [natasha.id]
        )
        #expect(MadeForYou.sonicTargets(assembly: assembly, stored: stored) == [natasha.id, aretha.id])
        #expect(MadeForYou.sonicTargets(assembly: assembly, stored: nil) == [natasha.id])
    }
}
