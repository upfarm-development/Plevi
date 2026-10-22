import Foundation
import Testing
@testable import PleviDomain

/// Not very fresh: six songs off one album by one artist in a single gap.
/// The bug, as a test.
@Suite("DJ artist cooldown")
struct DJArtistCooldownTests {
    private static let server = ServerID(rawValue: UUID())
    private func id(_ raw: String) -> MediaID { MediaID(server: Self.server, rawValue: raw) }

    private func track(_ name: String, artist: String) -> Track {
        Track(id: id(name), title: name, artistName: artist)
    }

    @Test("A fresh cooldown excludes nothing")
    func startsEmpty() {
        let cooldown = DJArtistCooldown()
        #expect(!cooldown.excludes("Anyone"))
    }

    @Test("A recorded artist is excluded until it ages out")
    func recordsAndExpires() {
        var cooldown = DJArtistCooldown(capacity: 2)
        cooldown.record("A")
        #expect(cooldown.excludes("A"))
        cooldown.record("B")
        cooldown.record("C")
        // Capacity two: "A" has aged out behind "B" and "C".
        #expect(!cooldown.excludes("A"))
        #expect(cooldown.excludes("C"))
    }

    @Test("A batch never repeats an artist within itself")
    func diversifiesOneBatch() {
        let ranked = [
            track("a1", artist: "Same Artist"),
            track("a2", artist: "Same Artist"),
            track("a3", artist: "Same Artist"),
            track("b1", artist: "Other Artist"),
        ]
        let cooldown = DJArtistCooldown()
        let picked = cooldown.diversePick(from: ranked, limit: 2)
        #expect(picked.map(\.id) == [id("a1"), id("b1")])
    }

    @Test("An artist already cooling down is skipped")
    func skipsCooledDownArtist() {
        var cooldown = DJArtistCooldown()
        let ranked = [
            track("a1", artist: "Same Artist"),
            track("b1", artist: "Other Artist"),
        ]
        // Recorded the way production code actually records it — through
        // `key(for:)`, not a hand-typed literal — so this stays correct
        // whatever that function normalises to.
        cooldown.record(DJArtistCooldown.key(for: ranked[0]))
        let picked = cooldown.diversePick(from: ranked, limit: 1)
        #expect(picked.map(\.id) == [id("b1")])
    }

    @Test("Running out of variety still fills the gap")
    func neverStarvesTheGap() {
        let ranked = [
            track("a1", artist: "Only Artist"),
            track("a2", artist: "Only Artist"),
            track("a3", artist: "Only Artist"),
        ]
        let cooldown = DJArtistCooldown()
        let picked = cooldown.diversePick(from: ranked, limit: 3)
        #expect(picked.count == 3)
    }

    @Test("The artist key is case- and whitespace-insensitive when there is no artist id")
    func keyIsNormalisedWithoutAnArtistID() {
        let first = track("a1", artist: "Aqua")
        let second = track("a2", artist: "  AQUA ")
        #expect(DJArtistCooldown.key(for: first) == DJArtistCooldown.key(for: second))
        var cooldown = DJArtistCooldown()
        cooldown.record(DJArtistCooldown.key(for: first))
        #expect(cooldown.excludes(DJArtistCooldown.key(for: second)))
    }

    @Test("Tracks with no artist credit are never excluded on that basis")
    func noArtistNeverCooledDown() {
        var cooldown = DJArtistCooldown()
        cooldown.record(nil)
        #expect(!cooldown.excludes(nil))
        let untitled = Track(id: id("x"), title: "x", artistName: nil)
        let ranked = [untitled, untitled]
        // Both entries lack an artist key, so neither blocks the other —
        // the cooldown only ever governs a real, shared identity.
        let picked = cooldown.diversePick(from: ranked, limit: 2)
        #expect(picked.count == 2)
    }
}
