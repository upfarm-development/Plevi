import Foundation
import Testing
@testable import PleviDomain

/// The pure halves of "what plays next" — the shuffle's spacing pass, the weighted draw and Smart
/// Continue's seeding and blend — on the pools a stressed queue produces: empty, one song, the same
/// song fifty times, one artist for the whole…
@Suite("Queue ordering at the edges")
struct StressPlaybackSmartQueueEdgeTests {
    private static let server = ServerID()

    private static func song(
        _ n: Int, artist: String? = "A", album: String? = "X", stars: Double? = nil
    ) -> Track {
        Track(
            id: MediaID(server: server, rawValue: "t\(n)"),
            title: "T\(n)",
            albumName: album,
            artistName: artist,
            rating: stars.flatMap(StarRating.init)
        )
    }

    private static func multiset(_ tracks: [Track]) -> [MediaID: Int] {
        tracks.reduce(into: [:]) { $0[$1.id, default: 0] += 1 }
    }

    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    // MARK: Smart shuffle

    @Test("Empty and single-song pools come back untouched under every setting")
    func tinyPools() {
        var generator = Seeded(state: 1)
        let settings: [SmartShuffleSettings] = [
            SmartShuffleSettings(),
            SmartShuffleSettings(ranking: [], enabled: [], artistSpacing: 0, albumSpacing: 0),
            SmartShuffleSettings(artistSpacing: Int.max, albumSpacing: Int.max),
            SmartShuffleSettings(artistSpacing: Int.min, albumSpacing: Int.min),
        ]
        for setting in settings {
            #expect(SmartShuffle.order([], settings: setting, using: &generator).isEmpty)
            let one = [Self.song(1)]
            #expect(SmartShuffle.order(one, settings: setting, using: &generator) == one)
            #expect(SmartShuffle.space([], settings: setting).isEmpty)
            #expect(SmartShuffle.space(one, settings: setting) == one)
        }
    }

    @Test("Nothing is lost or invented, whatever the pool and whatever the spacing")
    func alwaysAPermutation() {
        var generator = Seeded(state: 7)
        let pools: [(String, [Track])] = [
            ("two identical songs", [Self.song(1), Self.song(1)]),
            ("the same song fifty times", Array(repeating: Self.song(1), count: 50)),
            ("one artist, one album", (0..<200).map { Self.song($0) }),
            ("no artist, no album", (0..<200).map { Self.song($0, artist: nil, album: nil) }),
            ("every artist different", (0..<200).map { Self.song($0, artist: "A\($0)", album: "X\($0)") }),
            ("two artists alternating", (0..<200).map { Self.song($0, artist: $0.isMultiple(of: 2) ? "A" : "B", album: nil) }),
            ("blank artist names", (0..<100).map { Self.song($0, artist: " ", album: "") }),
        ]
        let spacings: [(Int, Int)] = [(0, 0), (1, 1), (5, 3), (50, 50), (10_000, 10_000), (Int.max, Int.max), (-5, -5)]
        for (name, pool) in pools {
            for (artistGap, albumGap) in spacings {
                let settings = SmartShuffleSettings(artistSpacing: artistGap, albumSpacing: albumGap)
                let shuffled = SmartShuffle.order(pool, settings: settings, using: &generator)
                #expect(Self.multiset(shuffled) == Self.multiset(pool), "\(name) spacing \(artistGap)/\(albumGap)")
                let spaced = SmartShuffle.space(pool, settings: settings)
                #expect(Self.multiset(spaced) == Self.multiset(pool), "\(name) space \(artistGap)/\(albumGap)")
            }
        }
    }

    @Test("A large pool by one artist finishes: the tail of the spacing pass is quadratic, and this pins it to a sane bound")
    func oneArtistAtScale() {
        // P-01 (related): the spacing pass's tail loop is O(waiting x waiting) when almost
        // everything is blocked by one artist.
        var generator = Seeded(state: 99)
        let pool = (0..<2_000).map { Self.song($0) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = SmartShuffle.order(pool, settings: SmartShuffleSettings(), using: &generator)
        }
        print("StressPlayback one-artist shuffle of \(pool.count): \(elapsed)")
        #expect(elapsed < .seconds(60), "took \(elapsed)")
    }

    @Test("Five thousand songs by one artist are spaced without dropping any, in near-linear time")
    func oneArtistDoesNotGoQuadratic() {
        // O-04: 4,000 songs took about two seconds and 8,000 eleven, because
        // the tail looked at everything still waiting for every placement.
        func run(_ count: Int) -> (Duration, Int) {
            var generator = Seeded(state: 7)
            let pool = (0..<count).map { Self.song($0) }
            var result: [Track] = []
            let elapsed = ContinuousClock().measure {
                result = SmartShuffle.order(pool, settings: SmartShuffleSettings(), using: &generator)
            }
            #expect(Set(result.map(\.id)) == Set(pool.map(\.id)))
            return (elapsed, result.count)
        }
        let small = run(1_000)
        let large = run(5_000)
        #expect(large.1 == 5_000)
        let ratio = (Double(large.0.components.seconds) + Double(large.0.components.attoseconds) * 1e-18)
            / max(Double(small.0.components.seconds) + Double(small.0.components.attoseconds) * 1e-18, 1e-6)
        print("StressPlayback one-artist 1k -> 5k ratio \(ratio)")
        // 5x the songs: linear is 5x, quadratic 25x.
        #expect(ratio < 14, "5x the songs took \(ratio)x as long")
    }

    // MARK: Weighted draw

    @Test("A weighted draw keeps its count and never repeats an item, whatever the weights are")
    func drawingWithHostileWeights() {
        var generator = Seeded(state: 3)
        let items = Array(0..<50)
        let weights: [(String, (Int) -> Double)] = [
            ("nan", { _ in .nan }),
            ("infinite", { _ in .infinity }),
            ("negative infinity", { _ in -.infinity }),
            ("zero", { _ in 0 }),
            ("negative", { _ in -3 }),
            ("huge", { _ in 1e300 }),
            ("mixed", { $0.isMultiple(of: 3) ? .nan : Double($0) }),
        ]
        for (name, weight) in weights {
            for count in [0, 1, 10, 49, 50, 51, 500] {
                let drawn = SmartShuffle.drawing(items, count: count, using: &generator, weight: weight)
                #expect(drawn.count == min(count, items.count), "\(name) count \(count) -> \(drawn.count)")
                #expect(Set(drawn).count == drawn.count, "\(name) count \(count) repeated an item")
            }
        }
        #expect(SmartShuffle.drawing([Int](), count: 5, using: &generator, weight: { _ in 1 }).isEmpty)
        #expect(SmartShuffle.drawing(items, count: -3, using: &generator, weight: { _ in 1 }).isEmpty)
    }

    // MARK: Smart Continue

    @Test("A limit of zero must add nothing")
    func blendLimitZero() {
        // P-26: `spread` only stops at `chosen.count == limit`, which a limit of 0 (or below) can
        // never equal, so everything ranked comes back.
        let neighbours = [(0..<10).map { Self.song($0, artist: "A\($0)", album: "X\($0)") }]
        #expect(SmartContinue.blend(neighbours, excluding: [], limit: 0).isEmpty)
        #expect(SmartContinue.blend(neighbours, excluding: [], limit: -1).isEmpty)
        #expect(SmartContinue.blend(neighbours, excluding: [], limit: 3).count == 3)
    }

    @Test("Seeds: every queue length and limit gives distinct seeds from the queue, the most recent included")
    func seedsAtTheEdges() {
        // A limit of 1 used to trap: `Double(n - 1) / 0` is infinite, and the
        // spread then computed `Int(NaN)` (P-26).
        for count in [0, 1, 2, 5, 6, 7, 30, 1_000] {
            let played = (0..<count).map { Self.song($0, artist: "A\($0)", album: "X\($0)") }
            for limit in [0, 1, 2, 3, 6, 50] {
                let seeds = SmartContinue.seeds(from: played, limit: limit)
                #expect(seeds.count <= max(limit, 0), "count \(count) limit \(limit) -> \(seeds.count)")
                #expect(Set(seeds.map(\.id)).count == seeds.count)
                #expect(seeds.allSatisfy { seed in played.contains { $0.id == seed.id } })
                // The most recent song is always among them: for a long queue the
                // last evenly spaced pick *is* the last song.
                if count > 0, limit >= 1 {
                    #expect(seeds.contains { $0.id == played.last?.id }, "count \(count) limit \(limit)")
                }
            }
        }
    }

    @Test("A blend of nothing, of empties, and of a list that is entirely excluded is empty")
    func blendOfNothing() {
        #expect(SmartContinue.blend([], excluding: []).isEmpty)
        #expect(SmartContinue.blend([[], []], excluding: []).isEmpty)
        let all = (0..<5).map { Self.song($0, artist: "A\($0)", album: "X\($0)") }
        #expect(SmartContinue.blend([all], excluding: Set(all.map(\.id))).isEmpty)
    }

    @Test("Songs marked down are kept out even when they are the only neighbours")
    func ratingFloorHoldsWhenItLeavesNothing() {
        let bad = (0..<5).map { Self.song($0, artist: "A\($0)", album: "X\($0)", stars: 1) }
        #expect(SmartContinue.blend([bad], excluding: []).isEmpty)
    }
}
