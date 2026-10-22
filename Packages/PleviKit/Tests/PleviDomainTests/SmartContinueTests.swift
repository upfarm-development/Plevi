import Foundation
import Testing
@testable import PleviDomain

@Suite("Carrying a queue on")
struct SmartContinueTests {
    private static let server = ServerID()

    private static func song(_ name: String) -> Track {
        Track(id: MediaID(server: server, rawValue: name), title: name)
    }

    private static func songs(_ names: [String]) -> [Track] { names.map(song) }

    // MARK: Seeds

    @Test("A short queue seeds from all of it")
    func shortQueue() {
        let played = Self.songs(["a", "b", "c"])
        #expect(SmartContinue.seeds(from: played).map(\.title) == ["a", "b", "c"])
    }

    @Test("A long queue is sampled across, not off the end")
    func spreadAcross() {
        // Twenty songs: an hour that started somewhere else. Seeding from the
        // last six would make the whole station about the last record.
        let played = Self.songs((1...20).map { "t\($0)" })
        let seeds = SmartContinue.seeds(from: played, limit: 4).map(\.title)
        #expect(seeds.first == "t1", "the beginning of the queue should count")
        #expect(seeds.last == "t20", "the most recent song is always a seed")
        #expect(seeds.count == 4)
        // And the middle is represented rather than skipped.
        #expect(seeds.contains { $0 != "t1" && $0 != "t20" })
    }

    @Test("The same song twice seeds once")
    func deduplicates() {
        let repeated = Self.songs(["a", "a", "a", "b"])
        #expect(SmartContinue.seeds(from: repeated).map(\.title) == ["a", "b"])
    }

    @Test("Nothing played, nothing to seed from")
    func emptyQueue() {
        #expect(SmartContinue.seeds(from: []).isEmpty)
    }

    // MARK: The blend

    @Test("A song already in the queue is not offered again from another record")
    func sameSongOnAnotherRecord() {
        let server = Self.server
        func copy(_ id: String, album: String) -> Track {
            Track(id: MediaID(server: server, rawValue: id), title: "Ain't Giving Up",
                  albumName: album, artistName: "Craig David & Sigala")
        }
        let playing = copy("a", album: "Following My Intuition")
        let onACompilation = copy("b", album: "Now 95")
        let other = Self.song("other")
        let blended = SmartContinue.blend(
            [[onACompilation, other]],
            excluding: [playing.id],
            alreadyHeard: [playing]
        )
        #expect(blended.map(\.title) == ["other"])
    }

    @Test("Case, accents and spacing do not make a song a different one")
    func songKeyIgnoresFormatting() {
        let server = Self.server
        let one = Track(id: MediaID(server: server, rawValue: "1"), title: "Café  Del Mar", artistName: "Energy 52")
        let two = Track(id: MediaID(server: server, rawValue: "2"), title: "cafe del mar", artistName: "ENERGY 52")
        #expect(SmartContinue.songKey(one) == SmartContinue.songKey(two))
    }

    @Test("Near several seeds beats nearest to one")
    func breadthBeatsDepth() {
        // "broad" is a middling neighbour of three seeds; "narrow" is the
        // nearest neighbour of one and unknown to the others. The whole point
        // of blending is that "broad" wins.
        let seedOne = Self.songs(["narrow", "x", "y", "broad"])
        let seedTwo = Self.songs(["p", "q", "broad", "r"])
        let seedThree = Self.songs(["s", "broad", "t", "u"])

        let blended = SmartContinue.blend([seedOne, seedTwo, seedThree], excluding: [])
        #expect(blended.first?.title == "broad")
    }

    @Test("Level on breadth, the closer neighbour goes first")
    func ties() {
        // Both appear once. "close" was its seed's nearest, "far" was last.
        let seed = Self.songs(["close", "a", "b", "far"])
        let blended = SmartContinue.blend([seed], excluding: []).map(\.title)
        #expect(blended.first == "close")
        #expect(blended.last == "far")
    }

    @Test("What has already played is not played again")
    func excludesWhatIsPlayed() {
        let seed = Self.songs(["heard", "new"])
        let blended = SmartContinue.blend(
            [seed],
            excluding: [MediaID(server: Self.server, rawValue: "heard")]
        )
        #expect(blended.map(\.title) == ["new"])
    }

    @Test("A song offered by two seeds is added once")
    func noDuplicates() {
        let seedOne = Self.songs(["same", "a"])
        let seedTwo = Self.songs(["same", "b"])
        let blended = SmartContinue.blend([seedOne, seedTwo], excluding: [])
        #expect(blended.filter { $0.title == "same" }.count == 1)
    }

    @Test("The same queue blends the same way twice")
    func stable() {
        // Two songs with identical scores and ranks: without a final
        // tie-break the order would be whatever the dictionary gave, and the
        // station would shuffle itself between runs.
        let seed = Self.songs(["b", "a"])
        let first = SmartContinue.blend([[seed[0]], [seed[1]]], excluding: []).map(\.title)
        let second = SmartContinue.blend([[seed[0]], [seed[1]]], excluding: []).map(\.title)
        #expect(first == second)
    }

    @Test("Nothing similar means nothing added, not silence dressed up")
    func nothingToAdd() {
        #expect(SmartContinue.blend([], excluding: []).isEmpty)
        #expect(SmartContinue.blend([[], []], excluding: []).isEmpty)
    }

    @Test("Only as much as was asked for")
    func honoursLimit() {
        let seed = Self.songs((1...50).map { "t\($0)" })
        #expect(SmartContinue.blend([seed], excluding: [], limit: 5).count == 5)
    }

    // MARK: Variety

    /// A small generator that can be seeded, so a draw can be repeated.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("Varied seeds still cover the whole queue and end on the latest song")
    func variedSeedsSpreadAndKeepTheLatest() {
        let played = Self.songs((0..<60).map { "s\($0)" })
        for seed in 0..<30 {
            var generator = Seeded(UInt64(seed))
            let seeds = SmartContinue.variedSeeds(from: played, using: &generator)
            #expect(seeds.count == SmartContinue.seedCount)
            #expect(seeds.last?.title == "s59")
            // One from each stretch of the earlier songs, in order.
            let positions = seeds.dropLast().compactMap { seed in played.firstIndex { $0.id == seed.id } }
            #expect(positions == positions.sorted())
            let stretch = 59 / (SmartContinue.seedCount - 1)
            for (index, position) in positions.enumerated() {
                #expect(position / stretch >= index - 1 && position / stretch <= index + 1)
            }
        }
    }

    @Test("The same draw repeats, and different draws differ")
    func variedSeedsAreRepeatableAndVary() {
        let played = Self.songs((0..<60).map { "s\($0)" })
        func titles(_ seed: UInt64) -> [String] {
            var generator = Seeded(seed)
            return SmartContinue.variedSeeds(from: played, using: &generator).map(\.title)
        }
        #expect(titles(7) == titles(7))
        #expect(Set((0..<20).map { titles(UInt64($0)) }).count > 10)
    }

    @Test("A short queue seeds with all of it, as before")
    func variedSeedsOfAShortQueue() {
        var generator = Seeded(1)
        let played = Self.songs(["a", "b", "c"])
        #expect(SmartContinue.variedSeeds(from: played, using: &generator).map(\.title) == ["a", "b", "c"])
        #expect(SmartContinue.variedSeeds(from: [], using: &generator).isEmpty)
        #expect(SmartContinue.variedSeeds(from: played, limit: 1, using: &generator).map(\.title) == ["c"])
    }

    /// Six seeds, as in use, that all name "hot" first, each with twenty-four
    /// others of its own.
    private static func neighbourhoods() -> [[Track]] {
        (0..<SmartContinue.seedCount).map { seed in
            [song("hot")] + (0..<24).map { song("seed\(seed)-\($0)") }
        }
    }

    @Test("A varied blend can be repeated, and is not the same every time")
    func variedBlendVaries() {
        func picked(_ seed: UInt64) -> [String] {
            var generator = Seeded(seed)
            return SmartContinue.blend(Self.neighbourhoods(), excluding: [], limit: SmartContinue.additionLength, varied: &generator).map(\.title)
        }
        #expect(picked(3) == picked(3))
        #expect(Set((0..<20).map { picked(UInt64($0)) }).count > 10)
    }

    @Test("A varied blend still prefers what several seeds agree on")
    func variedBlendFavoursBreadth() {
        var hot = 0
        var lastOfOne = 0
        for seed in 0..<200 {
            var generator = Seeded(UInt64(seed))
            let blended = SmartContinue.blend(
                Self.neighbourhoods(), excluding: [], limit: SmartContinue.additionLength, varied: &generator
            ).map(\.title)
            if blended.contains("hot") { hot += 1 }
            // The furthest neighbour of a single seed.
            if blended.contains("seed0-23") { lastOfOne += 1 }
        }
        #expect(hot >= 195, "the song every seed names was picked \(hot) times in 200")
        #expect(lastOfOne < 60, "a distant neighbour of one seed was picked \(lastOfOne) times in 200")
    }

    @Test("A varied blend keeps to its limit, its exclusions and its caps")
    func variedBlendKeepsTheRules() {
        func byArtist(_ title: String, _ artist: String) -> Track {
            Track(id: MediaID(server: Self.server, rawValue: title), title: title, artistName: artist)
        }
        let crowd = (0..<8).map { byArtist("c\($0)", "Same Artist") }
        let others = (0..<8).map { byArtist("o\($0)", "Artist \($0)") }
        let excluded = Set([crowd[0].id, others[0].id])
        for seed in 0..<30 {
            var generator = Seeded(UInt64(seed))
            let blended = SmartContinue.blend([crowd + others], excluding: excluded, limit: 8, varied: &generator)
            #expect(blended.count == 8)
            #expect(!blended.contains { excluded.contains($0.id) })
            #expect(Set(blended.map(\.id)).count == blended.count)
            // The cap holds while there is anything else to take.
            #expect(blended.filter { $0.artistName == "Same Artist" }.count <= SmartContinue.perArtist)
        }
        var generator = Seeded(1)
        #expect(SmartContinue.blend([crowd], excluding: [], limit: 0, varied: &generator).isEmpty)
    }
}


/// A radio is a mix, however many songs seeded it.
@Suite("A station is not a tracklist")
struct SmartContinueSpreadTests {
    private static let server = ServerID()

    private static func song(_ title: String, artist: String, album: String) -> Track {
        Track(
            id: MediaID(server: server, rawValue: "\(artist)-\(title)"),
            title: title,
            albumName: album,
            artistName: artist
        )
    }

    @Test("One seed still gives a mix, not one album in order")
    func oneSeedIsStillAMix() {
        // What Plex actually answers for a single track: its neighbours are
        // largely the rest of its own record, in running order.
        let sameAlbum = (1...10).map { Self.song("Track \($0)", artist: "Rusted Root", album: "When I Woke") }
        // ...and the rest of what a 25-neighbour answer holds, ranked below it.
        let others = (1...15).map {
            Self.song("Song \($0)", artist: "Band \($0)", album: "Record \($0)")
        }
        let blended = SmartContinue.blend([sameAlbum + others], excluding: [], limit: 6)

        let artists = Set(blended.compactMap(\.artistName))
        #expect(artists.count >= 5, "a station of one artist is a tracklist, not a station")
        let fromOneAlbum = blended.filter { $0.albumName == "When I Woke" }.count
        #expect(fromOneAlbum <= 2, "an assertion against the constant would pass at any cap")
        // The seed's own record still leads — it is what was asked for.
        #expect(blended.first?.artistName == "Rusted Root")
    }

    @Test("Held-back songs fill the tail rather than leaving it short")
    func fillsRatherThanRunsOut() {
        // Everything is by one artist: the caps would leave two songs, which
        // is not a station. The rest come back in score order.
        let all = (1...10).map { Self.song("Track \($0)", artist: "One Band", album: "One Record") }
        let blended = SmartContinue.blend([all], excluding: [], limit: 8)
        #expect(blended.count == 8)
        // And the two that led are still the two the ranking put first.
        #expect(blended.prefix(2).map(\.title) == ["Track 1", "Track 2"])
    }

    @Test("Songs with no artist named are not treated as one artist")
    func blankArtistsAreNotACrowd() {
        let unnamed = (1...5).map {
            Track(id: MediaID(server: Self.server, rawValue: "u\($0)"), title: "Untitled \($0)")
        }
        let blended = SmartContinue.blend([unnamed], excluding: [], limit: 5)
        #expect(blended.count == 5, "blank artist names must not cap each other")
    }
}

@Suite("The same song is not played twice")
struct SmartContinueRepeatTests {
    private static let server = ServerID()

    private static func song(_ title: String, artist: String, album: String) -> Track {
        Track(
            id: MediaID(server: server, rawValue: "\(album)-\(title)"),
            title: title,
            albumName: album,
            artistName: artist
        )
    }

    @Test("One song on two releases appears once")
    func sameSongTwoReleases() {
        // Straight from a real station: the single and the album cut, whose
        // titles differ only in how the parenthesis was capitalised.
        let candidates = [
            Self.song("Here (In Your Arms)", artist: "hellogoodbye", album: "Zombies! Aliens!"),
            Self.song("Here (in Your Arms)", artist: "hellogoodbye", album: "Hits"),
            Self.song("Get Away", artist: "Great Good Fine OK", album: "2M2H"),
        ]
        let blended = SmartContinue.blend([candidates], excluding: [], limit: 10)
        #expect(blended.filter { $0.title.lowercased().hasPrefix("here (") }.count == 1)
        #expect(blended.count == 2)
    }

    @Test("A remix is a different song, not a repeat")
    func remixesSurvive() {
        let candidates = [
            Self.song("Summer", artist: "WILD", album: "Summer"),
            Self.song("Summer - Great Good Fine OK Remix", artist: "WILD", album: "Summer (Remixes)"),
        ]
        let blended = SmartContinue.blend([candidates], excluding: [], limit: 10)
        #expect(blended.count == 2, "different recordings must not be collapsed")
    }

    @Test("Two artists may share a song title")
    func coversAreNotRepeats() {
        let candidates = [
            Self.song("Hallelujah", artist: "Jeff Buckley", album: "Grace"),
            Self.song("Hallelujah", artist: "Leonard Cohen", album: "Various Positions"),
        ]
        let blended = SmartContinue.blend([candidates], excluding: [], limit: 10)
        #expect(blended.count == 2, "a cover by someone else is its own song")
    }
}

/// The rating floor, which carrying a queue on shares with every station and
/// mix: a song actively marked down is not offered, and an unrated one is.
@Suite("What carrying on will not add")
struct SmartContinueRatingFloorTests {
    private static let server = ServerID()

    private static func song(_ name: String, stars: Double?) -> Track {
        Track(
            id: MediaID(server: server, rawValue: name),
            title: name,
            rating: stars.flatMap(StarRating.init)
        )
    }

    @Test("A song rated below the floor is never added")
    func belowTheFloorIsDropped() {
        let neighbours = [[
            Self.song("two stars", stars: 2),
            Self.song("one star", stars: 1),
            Self.song("half a star", stars: 0.5),
        ]]
        let out = SmartContinue.blend(neighbours, excluding: []).map(\.title)
        #expect(out.isEmpty, "every one of these is marked down and none should be offered")
    }

    @Test("Unrated songs still come through, and so does anything at the floor")
    func unratedAndAtTheFloorPass() {
        let neighbours = [[
            Self.song("unrated", stars: nil),
            Self.song("exactly the floor", stars: 2.5),
            Self.song("well liked", stars: 4.5),
            Self.song("marked down", stars: 1.5),
        ]]
        let out = SmartContinue.blend(neighbours, excluding: []).map(\.title)
        #expect(out.contains("unrated"))
        #expect(out.contains("exactly the floor"), "2.5 is the floor, not below it")
        #expect(out.contains("well liked"))
        #expect(out.contains("marked down") == false)
    }

    @Test("Dropping a low-rated song does not leave the addition short")
    func floorDoesNotCostALength() {
        // Ten candidates, four of them marked down. Asking for six should
        // give six — the floor has to apply before the cut, not after, or
        // the addition comes back four songs light.
        var list: [Track] = []
        for n in 0..<10 {
            list.append(Self.song("song \(n)", stars: n % 3 == 0 ? 1 : nil))
        }
        let out = SmartContinue.blend([list], excluding: [], limit: 6)
        #expect(out.count == 6)
        #expect(out.allSatisfy { $0.rating == nil || $0.rating!.value >= 2.5 })
    }

    @Test("The floor can be lifted or lowered by the caller")
    func floorIsAParameter() {
        let neighbours = [[Self.song("three stars", stars: 3)]]
        #expect(SmartContinue.blend(neighbours, excluding: [], ratingFloor: 4).isEmpty)
        #expect(SmartContinue.blend(neighbours, excluding: [], ratingFloor: 2).count == 1)
    }
}
