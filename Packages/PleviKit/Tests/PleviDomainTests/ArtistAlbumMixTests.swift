import Foundation
import Testing
@testable import PleviDomain

@Suite("Artist & Album Mixer")
struct ArtistAlbumMixTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func track(
        _ raw: String,
        artist: String = "An Artist",
        album: String = "An Album",
        plays: Int? = nil,
        stars: Double? = nil
    ) -> Track {
        Track(
            id: id(raw),
            title: raw,
            albumName: album,
            artistName: artist,
            rating: stars.flatMap(StarRating.init),
            playCount: plays
        )
    }

    /// A generator that is random but reproducible, so a distribution test
    /// that passes here passes on every machine and every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private static let floor = 2.5

    // MARK: The pool

    @Test("An artist and one of their own albums selected together counts each song once")
    func deduplicatesAcrossSelections() {
        // What the index would hand back for "the artist" and "that album":
        // the album's songs appear in both.
        let fromArtist = [track("a1"), track("a2"), track("a3")]
        let fromAlbum = [track("a2"), track("a3")]

        let pool = ArtistAlbumMix.pool(from: fromArtist + fromAlbum, ratingFloor: Self.floor)

        #expect(pool.count == 3)
        #expect(Set(pool.map(\.id)).count == 3)
    }

    @Test("A song rated below the floor never reaches the pool; unrated always does")
    func poolAppliesTheRatingFloor() {
        let pool = ArtistAlbumMix.pool(
            from: [
                track("disliked", stars: 1),
                track("borderline", stars: 2),
                track("exactly", stars: 2.5),
                track("unrated"),
                track("loved", stars: 5),
            ],
            ratingFloor: Self.floor
        )
        #expect(pool.map(\.title).sorted() == ["exactly", "loved", "unrated"])
    }

    @Test("Every emphasis honours the rating floor — it is a weighting, never a way in", arguments: ArtistAlbumMix.Emphasis.allCases)
    func floorHoldsInEveryEmphasis(emphasis: ArtistAlbumMix.Emphasis) {
        // Deliberately made attractive to each emphasis in turn: never
        // played, five stars, heavily played. None of it may get in.
        let rejected = [
            track("d1", stars: 1),
            track("d2", plays: 0, stars: 0.5),
            track("d3", plays: 900, stars: 2),
        ]
        let allowed = (0..<200).map { track("ok\($0)", plays: $0, stars: nil) }
        let pool = ArtistAlbumMix.pool(from: rejected + allowed, ratingFloor: Self.floor)

        // The limit has to sit *below* the pool, or `sample` takes its
        // "everything is going in anyway" shortcut and the weighted draw —
        // the path this test exists to check the floor against — never runs.
        var generator = SeededGenerator(seed: 99)
        let mix = ArtistAlbumMix.build(
            pool: pool, limit: 50, emphasis: emphasis, artistCount: 1, using: &generator
        )
        #expect(mix.count == 50)
        #expect(mix.allSatisfy { DJRatingFloor.passes($0, atLeast: Self.floor) })
        #expect(mix.contains { $0.title.hasPrefix("d") } == false)
    }

    // MARK: Small pools

    @Test("A pool smaller than the mix uses everything, and pads from nowhere")
    func smallPoolIsUsedWhole() {
        let pool = (0..<7).map { track("t\($0)") }
        var generator = SeededGenerator(seed: 4)
        let mix = ArtistAlbumMix.build(
            pool: pool, limit: 200, emphasis: .shuffle, artistCount: 1, using: &generator
        )
        #expect(mix.count == 7)
        #expect(Set(mix.map(\.id)) == Set(pool.map(\.id)))
    }

    @Test("An empty pool makes an empty mix rather than trouble")
    func emptyPoolIsHandled() {
        var generator = SeededGenerator(seed: 1)
        let mix = ArtistAlbumMix.build(
            pool: [], limit: 200, emphasis: .topRated, artistCount: 0, using: &generator
        )
        #expect(mix.isEmpty)
    }

    @Test("A mix never repeats a track")
    func drawsWithoutReplacement() {
        let pool = (0..<300).map { track("t\($0)", plays: $0 % 11) }
        var generator = SeededGenerator(seed: 7)
        let mix = ArtistAlbumMix.build(
            pool: pool, limit: 200, emphasis: .popular, artistCount: 1, using: &generator
        )
        #expect(mix.count == 200)
        #expect(Set(mix.map(\.id)).count == 200)
    }

    // MARK: Artist spread

    @Test("With three or more artists, no more than two in a row share one")
    func spreadHoldsTheRun() {
        // Lopsided on purpose: one artist owns most of the pool, which is
        // exactly the case a naive shuffle handles badly.
        let heavy = (0..<40).map { track("h\($0)", artist: "Heavy", album: "H") }
        let middle = (0..<20).map { track("m\($0)", artist: "Middle", album: "M") }
        let light = (0..<20).map { track("l\($0)", artist: "Light", album: "L") }

        let spread = ArtistAlbumMix.spread(heavy + middle + light, artistCount: 3)

        #expect(spread.count == 80)
        #expect(Set(spread.map(\.id)).count == 80)
        // The literal the spec fixes, not `maximumRun` — asserting against
        // the constant would keep passing if the constant itself drifted.
        #expect(longestRun(spread, by: { $0.artistName }) <= 2)
    }

    @Test("One artist's mix keeps its albums from running back to back")
    func spreadFallsBackToAlbums() {
        let first = (0..<10).map { track("a\($0)", artist: "Only", album: "First") }
        let second = (0..<10).map { track("b\($0)", artist: "Only", album: "Second") }

        let spread = ArtistAlbumMix.spread(first + second, artistCount: 1)

        #expect(spread.count == 20)
        #expect(longestRun(spread, by: { $0.albumName }) == 1)
    }

    @Test("A selection with nothing to spread still hands back everything it was given")
    func spreadCannotDropTracks() {
        // One artist, one album: every rule is unsatisfiable, and the only
        // wrong answer is losing songs.
        let only = (0..<15).map { track("t\($0)", artist: "Solo", album: "Sole") }
        let spread = ArtistAlbumMix.spread(only, artistCount: 1)
        #expect(spread.count == 15)
        #expect(Set(spread.map(\.id)).count == 15)
    }

    private func longestRun(_ tracks: [Track], by key: (Track) -> String?) -> Int {
        var longest = 0
        var current = 0
        var last: String?
        for track in tracks {
            let this = key(track)
            if this == last {
                current += 1
            } else {
                last = this
                current = 1
            }
            longest = max(longest, current)
        }
        return longest
    }

    // MARK: The weighting actually leans

    /// The real test of a weighting: run it many times and look at the shape
    /// of what comes back. A single mix proves nothing — any one draw is
    /// allowed to be unusual.
    @Test("Rarely Played draws the forgotten end far more often than Shuffle does")
    func rarelyPlayedShiftsTheDistribution() {
        let pool = (0..<100).map { track("rare\($0)", plays: 0) }
            + (0..<100).map { track("worn\($0)", plays: 50) }

        let rareUnderShuffle = averageShare(of: "rare", pool: pool, emphasis: .shuffle)
        let rareUnderEmphasis = averageShare(of: "rare", pool: pool, emphasis: .rarelyPlayed)

        // Shuffle is even-handed, so about half.
        #expect(abs(rareUnderShuffle - 0.5) < 0.06)
        // The emphasis leans hard, but does not become a filter: worn tracks
        // still turn up.
        #expect(rareUnderEmphasis > 0.75)
        #expect(rareUnderEmphasis < 1.0)
    }

    @Test("Top Rated favours four stars and up, without shutting unrated out")
    func topRatedShiftsTheDistribution() {
        let pool = (0..<100).map { track("great\($0)", stars: 4.5) }
            + (0..<100).map { track("plain\($0)") }

        let greatUnderShuffle = averageShare(of: "great", pool: pool, emphasis: .shuffle)
        let greatUnderEmphasis = averageShare(of: "great", pool: pool, emphasis: .topRated)

        #expect(abs(greatUnderShuffle - 0.5) < 0.06)
        #expect(greatUnderEmphasis > 0.75)
        #expect(greatUnderEmphasis < 1.0)
    }

    @Test("Popular favours what has actually been played, and still reaches the rest")
    func popularShiftsTheDistribution() {
        let pool = (0..<100).map { track("played\($0)", plays: 200) }
            + (0..<100).map { track("never\($0)", plays: 0) }

        let playedUnderShuffle = averageShare(of: "played", pool: pool, emphasis: .shuffle)
        let playedUnderEmphasis = averageShare(of: "played", pool: pool, emphasis: .popular)

        #expect(abs(playedUnderShuffle - 0.5) < 0.06)
        #expect(playedUnderEmphasis > 0.70)
        #expect(playedUnderEmphasis < 1.0)
    }

    @Test("Each emphasis produces a different mix from the same pool and seed")
    func emphasesDisagree() {
        let pool = (0..<200).map {
            track("t\($0)", plays: $0 % 40, stars: $0 % 9 == 0 ? 4.5 : nil)
        }
        var lists: [[MediaID]] = []
        for emphasis in ArtistAlbumMix.Emphasis.allCases {
            var generator = SeededGenerator(seed: 2024)
            lists.append(
                ArtistAlbumMix.build(
                    pool: pool, limit: 60, emphasis: emphasis, artistCount: 1, using: &generator
                ).map(\.id)
            )
        }
        // No two emphases hand back the same queue.
        for left in lists.indices {
            for right in (left + 1)..<lists.count {
                #expect(lists[left] != lists[right])
            }
        }
    }

    /// The case most mixes actually are: a few albums, all of which fit in the queue.
    @Test("On a pool that fits entirely, the emphasis still decides the running order")
    func emphasisOrdersASmallPool() {
        // One album, so the spread has nothing to interleave and the order
        // on show is purely the one the emphasis chose. Picking a single
        // record is also the plainest version of the case this is about.
        let pool = (0..<20).map { track("great\($0)", artist: "A", album: "A1", stars: 5) }
            + (0..<20).map { track("plain\($0)", artist: "A", album: "A1") }

        var early = 0.0
        let runs = 200
        for run in 0..<runs {
            var generator = SeededGenerator(seed: UInt64(run) &+ 1)
            let mix = ArtistAlbumMix.build(
                pool: pool, limit: 200, emphasis: .topRated, artistCount: 1, using: &generator
            )
            // Everything is included whatever the emphasis says.
            #expect(mix.count == 40)
            // The question is where the good songs landed.
            let firstHalf = mix.prefix(20).filter { $0.title.hasPrefix("great") }.count
            early += Double(firstHalf) / 20
        }
        let share = early / Double(runs)
        // Comfortably front-loaded, without being a hard sort — a five-star
        // song is likelier to open the mix, not guaranteed to.
        #expect(share > 0.65)
        #expect(share < 1.0)
    }

    @Test("Shuffle leaves a small pool genuinely even, front to back")
    func shuffleDoesNotFrontLoadASmallPool() {
        let pool = (0..<20).map { track("great\($0)", artist: "A", album: "A1", stars: 5) }
            + (0..<20).map { track("plain\($0)", artist: "A", album: "A1") }

        var early = 0.0
        let runs = 200
        for run in 0..<runs {
            var generator = SeededGenerator(seed: UInt64(run) &+ 1)
            let mix = ArtistAlbumMix.build(
                pool: pool, limit: 200, emphasis: .shuffle, artistCount: 1, using: &generator
            )
            early += Double(mix.prefix(20).filter { $0.title.hasPrefix("great") }.count) / 20
        }
        #expect(abs(early / Double(runs) - 0.5) < 0.08)
    }

    @Test("Regenerating gives a different mix, so a second tap is worth making")
    func regeneratingDiffers() {
        let pool = (0..<400).map { track("t\($0)", plays: $0 % 30) }
        var first = SeededGenerator(seed: 11)
        var second = SeededGenerator(seed: 12)
        let one = ArtistAlbumMix.build(
            pool: pool, limit: 200, emphasis: .shuffle, artistCount: 1, using: &first
        )
        let two = ArtistAlbumMix.build(
            pool: pool, limit: 200, emphasis: .shuffle, artistCount: 1, using: &second
        )
        #expect(one.map(\.id) != two.map(\.id))
    }

    /// The mean share of the mix taken by tracks whose title starts with
    /// `prefix`, over enough runs for the mean to mean something.
    private func averageShare(
        of prefix: String,
        pool: [Track],
        emphasis: ArtistAlbumMix.Emphasis,
        runs: Int = 300,
        limit: Int = 40
    ) -> Double {
        var total = 0.0
        for run in 0..<runs {
            var generator = SeededGenerator(seed: UInt64(run) &+ 1)
            let mix = ArtistAlbumMix.sample(pool, limit: limit, emphasis: emphasis, using: &generator)
            let matching = mix.filter { $0.title.hasPrefix(prefix) }.count
            total += Double(matching) / Double(mix.count)
        }
        return total / Double(runs)
    }
}
