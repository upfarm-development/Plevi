import Foundation
import Testing
@testable import PleviDomain

/// A seeded generator, so a statistical test is a fact rather than a mood.
private struct DrawSeeded: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Picking a few of many, differently each time.
@Suite("Drawing a few of many")
struct WeightedDrawTests {
    private static let server = ServerID()

    private static func song(_ number: Int, rating: Double? = nil, plays: Int? = nil) -> Track {
        Track(
            id: MediaID(server: server, rawValue: "t\(number)"),
            title: "Song \(number)",
            albumName: "Record \(number)",
            artistName: "The Artist",
            rating: rating.flatMap(StarRating.init),
            playCount: plays
        )
    }

    private static var twenty: [Track] { (0..<20).map { song($0) } }

    @Test("Asking twice gives two different answers")
    func variesPerAsk() {
        // The actual complaint, as a test.
        var generator = SystemRandomNumberGenerator()
        let pool = Self.twenty
        var seen: Set<String> = []
        for _ in 0..<12 {
            let drawn = SmartShuffle.drawing(pool, count: 4, using: &generator) { _ in 1 }
            #expect(drawn.count == 4)
            seen.insert(drawn.map(\.id.rawValue).joined(separator: ","))
        }
        #expect(
            seen.count > 1,
            "twelve draws of four from twenty came back identical, which is the bug"
        )
    }

    @Test("Weight raises the odds without deciding")
    func weightRaisesOdds() {
        // Both halves of that sentence are tested: the favourite turns up far more often than an
        // even draw would give it, and the others still turn up.
        var generator = DrawSeeded(20_260_921)
        let favourite = Self.song(99, rating: 5)
        let pool = [favourite] + Self.twenty
        var favouriteAppeared = 0
        var everyoneElse: Set<String> = []
        let rounds = 400
        for _ in 0..<rounds {
            let drawn = SmartShuffle.drawing(pool, count: 4, using: &generator) {
                $0.rating?.value ?? 0 >= 4.5 ? 12 : 1
            }
            if drawn.contains(where: { $0.id == favourite.id }) { favouriteAppeared += 1 }
            for track in drawn where track.id != favourite.id {
                everyoneElse.insert(track.id.rawValue)
            }
        }
        // An even draw of four from twenty-one gives the favourite about 19%.
        #expect(
            favouriteAppeared > rounds / 2,
            "a five-star song appeared in \(favouriteAppeared) of \(rounds), which is not favoured"
        )
        #expect(
            favouriteAppeared < rounds,
            "it appeared every single time, which is a ranking rather than a draw"
        )
        #expect(
            everyoneElse.count == 20,
            "only \(everyoneElse.count) of the other twenty were ever reachable"
        )
    }

    @Test("Taking everything loses nothing")
    func nothingIsDropped() {
        var generator = DrawSeeded(7)
        let pool = Self.twenty
        let drawn = SmartShuffle.drawing(pool, count: 20, using: &generator) { _ in 1 }
        #expect(Set(drawn.map(\.id)) == Set(pool.map(\.id)))
        let more = SmartShuffle.drawing(pool, count: 50, using: &generator) { _ in 1 }
        #expect(more.count == 20, "asking for more than there is should give what there is")
    }

    @Test("A weight of zero is unlikely, not impossible")
    func zeroWeightStillReachable() {
        // A song you marked down should be rare in a station, not barred
        // from one. The floor in `drawing` is what makes that true, and a
        // weight of zero without it divides by nothing.
        var generator = DrawSeeded(11)
        let marked = Self.song(99, rating: 1)
        let pool = [marked] + Self.twenty
        var appeared = 0
        for _ in 0..<2_000 {
            let drawn = SmartShuffle.drawing(pool, count: 4, using: &generator) {
                $0.id == marked.id ? 0 : 1
            }
            if drawn.contains(where: { $0.id == marked.id }) { appeared += 1 }
        }
        #expect(appeared > 0, "a weight of zero should be unlikely, not excluded")
        #expect(appeared < 200, "it turned up \(appeared) times in two thousand, which is not rare")
    }

    /// The draw a station's seeds actually use, records and all.
    private static func drawSpread(
        _ tracks: [Track],
        count: Int,
        using generator: inout some RandomNumberGenerator
    ) -> [Track] {
        guard count > 0, !tracks.isEmpty else { return [] }
        var byRecord: [String: [Track]] = [:]
        for track in tracks {
            byRecord[track.albumName ?? track.id.rawValue, default: []].append(track)
        }
        var representatives: [Track] = []
        var leftovers: [Track] = []
        for songs in byRecord.values {
            let standing = SmartShuffle.drawing(songs, count: 1, using: &generator) { _ in 1 }
            representatives.append(contentsOf: standing)
            let taken = Set(standing.map(\.id))
            leftovers.append(contentsOf: songs.filter { !taken.contains($0.id) })
        }
        let first = SmartShuffle.drawing(
            representatives, count: count, using: &generator
        ) { _ in 1 }
        guard first.count < count else { return first }
        return first + SmartShuffle.drawing(
            leftovers, count: count - first.count, using: &generator
        ) { _ in 1 }
    }

    /// Twelve songs spread over `records` records.
    private static func catalogue(records: Int) -> [Track] {
        (0..<12).map { index in
            Track(
                id: MediaID(server: server, rawValue: "t\(index)"),
                title: "Song \(index)",
                albumName: "Record \(index % records)",
                artistName: "The Artist"
            )
        }
    }

    @Test(
        "However many records an artist has, the station differs",
        arguments: [1, 2, 3, 4, 5, 6, 12]
    )
    func everyCatalogueShapeVaries(records: Int) {
        // Four records was the case that slipped through the first fix, and slipped through because
        // it is the one shape where drawing four from one-song-per-record takes every one of them.
        var generator = SystemRandomNumberGenerator()
        let songs = Self.catalogue(records: records)
        var seen: Set<String> = []
        for _ in 0..<40 {
            let seeds = Self.drawSpread(songs, count: 4, using: &generator)
            #expect(seeds.count == 4, "\(records) records gave \(seeds.count) seeds, not four")
            #expect(Set(seeds.map(\.id)).count == 4, "the same song was drawn twice")
            seen.insert(seeds.map(\.id.rawValue).sorted().joined(separator: ","))
        }
        #expect(
            seen.count > 1,
            "forty taps on a \(records)-record artist gave one station"
        )
    }

    @Test("Nothing to draw from, or nothing asked for")
    func degenerate() {
        var generator = DrawSeeded(3)
        #expect(SmartShuffle.drawing([Track](), count: 4, using: &generator) { _ in 1 }.isEmpty)
        #expect(SmartShuffle.drawing(Self.twenty, count: 0, using: &generator) { _ in 1 }.isEmpty)
        #expect(SmartShuffle.drawing(Self.twenty, count: -1, using: &generator) { _ in 1 }.isEmpty)
    }
}
