import Foundation
import Testing
@testable import PleviDomain

/// A seeded generator, so a statistical test is a fact rather than a mood.
private struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Seconds as a `Double`, for the scale suite's ratios and its printing.
private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

@Suite("A shuffle with the dice loaded")
struct SmartShuffleTests {
    private static let server = ServerID()
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func song(
        _ title: String,
        artist: String = "Someone",
        album: String = "Something",
        stars: Double? = nil,
        plays: Int? = nil,
        playedDaysAgo: Double? = nil
    ) -> Track {
        Track(
            id: MediaID(server: server, rawValue: "\(artist)|\(album)|\(title)"),
            title: title,
            albumName: album,
            artistName: artist,
            rating: stars.flatMap(StarRating.init),
            playCount: plays,
            playedAt: playedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        )
    }

    private static func onlySignal(_ signal: ShuffleSignal, spacing: Int = 0) -> SmartShuffleSettings {
        SmartShuffleSettings(
            ranking: [signal],
            enabled: [signal],
            artistSpacing: spacing,
            albumSpacing: spacing
        )
    }

    /// How often `title` lands in the first `topN` over many shuffles.
    private static func timesNearTheTop(
        _ title: String,
        of tracks: [Track],
        settings: SmartShuffleSettings,
        runs: Int = 400,
        topN: Int
    ) -> Int {
        var generator = Seeded(20_260_823)
        var hits = 0
        for _ in 0..<runs {
            let order = SmartShuffle.order(tracks, settings: settings, now: now, using: &generator)
            if order.prefix(topN).contains(where: { $0.title == title }) { hits += 1 }
        }
        return hits
    }

    // MARK: It is still a shuffle

    @Test("Two shuffles of the same songs differ")
    func stillRandom() {
        // The whole risk of weighting: it quietly becomes a sort, and every
        // shuffle gives the identical running order.
        let tracks = (1...40).map { Self.song("t\($0)", artist: "Artist \($0)") }
        var generator = Seeded(1)
        let first = SmartShuffle.order(tracks, settings: .init(), now: Self.now, using: &generator)
        let second = SmartShuffle.order(tracks, settings: .init(), now: Self.now, using: &generator)
        #expect(first.map(\.title) != second.map(\.title))
    }

    @Test("Nothing is lost and nothing is duplicated")
    func keepsEverything() {
        let tracks = (1...60).map { Self.song("t\($0)", artist: "Artist \($0 % 7)", album: "Album \($0 % 5)") }
        var generator = Seeded(2)
        let order = SmartShuffle.order(tracks, settings: .init(), now: Self.now, using: &generator)
        #expect(order.count == tracks.count)
        #expect(Set(order.map(\.id)) == Set(tracks.map(\.id)))
    }

    @Test("One song shuffles to itself")
    func trivialCases() {
        var generator = Seeded(3)
        #expect(SmartShuffle.order([], settings: .init(), now: Self.now, using: &generator).isEmpty)
        let one = [Self.song("only")]
        #expect(SmartShuffle.order(one, settings: .init(), now: Self.now, using: &generator).count == 1)
    }

    // MARK: The dice are actually loaded

    @Test("A five-star song beats a one-star song over many shuffles")
    func ratingLifts() {
        var tracks = (1...48).map { Self.song("filler\($0)", artist: "Filler \($0)", stars: 3) }
        tracks.append(Self.song("loved", artist: "Loved", stars: 5))
        tracks.append(Self.song("hated", artist: "Hated", stars: 1))

        let settings = Self.onlySignal(.rating)
        let loved = Self.timesNearTheTop("loved", of: tracks, settings: settings, topN: 10)
        let hated = Self.timesNearTheTop("hated", of: tracks, settings: settings, topN: 10)
        #expect(loved > hated, "five stars reached the top \(loved) times, one star \(hated)")
    }

    @Test("An unrated song is treated as middling, not as bad")
    func unratedSitInTheMiddle() {
        // Four songs in five in the real library carry no rating. If unrated
        // behaved like one star, most of the music would disappear.
        var tracks = (1...48).map { Self.song("filler\($0)", artist: "Filler \($0)", stars: 3) }
        tracks.append(Self.song("unrated", artist: "Unrated"))
        tracks.append(Self.song("hated", artist: "Hated", stars: 1))

        let settings = Self.onlySignal(.rating)
        let unrated = Self.timesNearTheTop("unrated", of: tracks, settings: settings, topN: 10)
        let hated = Self.timesNearTheTop("hated", of: tracks, settings: settings, topN: 10)
        #expect(unrated > hated, "unrated \(unrated) vs one star \(hated)")
    }

    @Test("Something unheard for a year beats something heard yesterday")
    func staleLifts() {
        var tracks = (1...48).map { Self.song("filler\($0)", artist: "Filler \($0)", playedDaysAgo: 180) }
        tracks.append(Self.song("forgotten", artist: "Forgotten", playedDaysAgo: 400))
        tracks.append(Self.song("justheard", artist: "Just Heard", playedDaysAgo: 1))

        let settings = Self.onlySignal(.lastPlayed)
        let forgotten = Self.timesNearTheTop("forgotten", of: tracks, settings: settings, topN: 10)
        let recent = Self.timesNearTheTop("justheard", of: tracks, settings: settings, topN: 10)
        #expect(forgotten > recent, "forgotten \(forgotten) vs just heard \(recent)")
    }

    @Test("Never played counts as the longest wait of all")
    func neverPlayedLifts() {
        var tracks = (1...48).map { Self.song("filler\($0)", artist: "Filler \($0)", playedDaysAgo: 100) }
        tracks.append(Self.song("neverheard", artist: "Never Heard"))
        tracks.append(Self.song("justheard", artist: "Just Heard", playedDaysAgo: 1))

        let settings = Self.onlySignal(.lastPlayed)
        let never = Self.timesNearTheTop("neverheard", of: tracks, settings: settings, topN: 10)
        let recent = Self.timesNearTheTop("justheard", of: tracks, settings: settings, topN: 10)
        #expect(never > recent, "never played \(never) vs just heard \(recent)")
    }

    @Test("The order of the list is the weighting")
    func rankingDecidesWeight() {
        let ranked = SmartShuffleSettings(
            ranking: [.rating, .lastPlayed, .playCount],
            enabled: Set(ShuffleSignal.allCases)
        )
        let weights = SmartShuffle.weighting(for: ranked)
        #expect(weights[.rating] == 1.0)
        #expect(weights[.lastPlayed] == 0.5)
        #expect(weights[.playCount] == 0.25)
    }

    @Test("A signal switched off carries no weight at all")
    func disabledSignalsAreIgnored() {
        let settings = SmartShuffleSettings(
            ranking: [.rating, .lastPlayed, .playCount],
            enabled: [.lastPlayed]
        )
        let weights = SmartShuffle.weighting(for: settings)
        #expect(weights[.rating] == nil)
        #expect(weights[.playCount] == nil)
        #expect(weights[.lastPlayed] == 1.0)
    }

    // MARK: Spacing

    @Test("Songs by one artist are pushed apart")
    func spacesArtists() {
        // Ten artists, six songs each: plenty of room to keep them apart.
        var tracks: [Track] = []
        for artist in 1...10 {
            for number in 1...6 {
                tracks.append(Self.song("a\(artist)t\(number)", artist: "Artist \(artist)", album: "Album \(artist)-\(number)"))
            }
        }
        let settings = SmartShuffleSettings(artistSpacing: 4, albumSpacing: 0)
        var generator = Seeded(7)
        let order = SmartShuffle.order(tracks, settings: settings, now: Self.now, using: &generator)

        // The real guarantee: spacing holds everywhere except the last few slots, where whatever is
        // left is all there is.
        var lastSeen: [String: Int] = [:]
        var closePositions: [Int] = []
        for (position, track) in order.enumerated() {
            let artist = track.artistName ?? ""
            if let previous = lastSeen[artist], position - previous <= 4 {
                closePositions.append(position)
            }
            lastSeen[artist] = position
        }
        let body = closePositions.filter { $0 < order.count - 5 }
        #expect(body.isEmpty, "artists landed too close mid-shuffle at \(body)")
        #expect(closePositions.count <= 5, "\(closePositions.count) close pairs is more than a tail")
    }

    @Test("Spacing beats a plain shuffle by a mile")
    func spacingIsWorthHaving() {
        // The comparison that says the feature does anything: the same songs
        // shuffled uniformly, counted the same way.
        var tracks: [Track] = []
        for artist in 1...10 {
            for number in 1...6 {
                tracks.append(Self.song("a\(artist)t\(number)", artist: "Artist \(artist)", album: "Album \(artist)-\(number)"))
            }
        }
        func closePairs(_ order: [Track]) -> Int {
            var lastSeen: [String: Int] = [:]
            var count = 0
            for (position, track) in order.enumerated() {
                let artist = track.artistName ?? ""
                if let previous = lastSeen[artist], position - previous <= 4 { count += 1 }
                lastSeen[artist] = position
            }
            return count
        }

        var generator = Seeded(11)
        let smart = closePairs(SmartShuffle.order(
            tracks,
            settings: SmartShuffleSettings(artistSpacing: 4, albumSpacing: 0),
            now: Self.now,
            using: &generator
        ))
        var plainTotal = 0
        for _ in 0..<20 { plainTotal += closePairs(tracks.shuffled(using: &generator)) }
        let plainAverage = Double(plainTotal) / 20

        print("COMPARE smart=\(smart) plainAverage=\(plainAverage)")
        #expect(Double(smart) < plainAverage / 3,
                "smart had \(smart) close pairs, a plain shuffle averaged \(plainAverage)")
    }

    @Test("A queue of one artist still plays rather than emptying itself")
    func impossibleSpacingStillPlays() {
        // Spacing cannot be honoured here. Dropping the songs would be worse
        // than ignoring the rule, so everything must still come back.
        let tracks = (1...12).map { Self.song("t\($0)", artist: "The Only Band", album: "The Only Record") }
        let settings = SmartShuffleSettings(artistSpacing: 5, albumSpacing: 5)
        var generator = Seeded(9)
        let order = SmartShuffle.order(tracks, settings: settings, now: Self.now, using: &generator)
        #expect(order.count == 12)
        #expect(Set(order.map(\.id)).count == 12)
    }

    @Test("Spacing set to zero leaves the order alone")
    func spacingOff() {
        let tracks = (1...20).map { Self.song("t\($0)", artist: "One", album: "One") }
        let settings = SmartShuffleSettings(artistSpacing: 0, albumSpacing: 0)
        #expect(SmartShuffle.space(tracks, settings: settings).map(\.title) == tracks.map(\.title))
    }

    @Test("Songs with no artist named do not count as one artist")
    func blankArtistsAreNotACrowd() {
        // Otherwise a library with missing tags would space songs apart for
        // sharing a name that isn't there.
        let tracks = (1...10).map {
            Track(id: MediaID(server: Self.server, rawValue: "u\($0)"), title: "Untitled \($0)")
        }
        let spaced = SmartShuffle.space(tracks, settings: SmartShuffleSettings(artistSpacing: 5, albumSpacing: 5))
        #expect(spaced.map(\.title) == tracks.map(\.title))
    }

    /// What a radio station hands over: songs already chosen by `ORDER BY RANDOM()`, which has no
    /// memory and so clusters.
    @Test("A clustered station queue is broken up without losing a song")
    func spacingBreaksUpAStationQueue() {
        // The shape a true shuffle really produces: one artist's songs landing in a block.
        let clustered = (1...5).map { Self.song("boss\($0)", artist: "Springsteen", album: "Born") }
            + (1...15).map { Self.song("other\($0)", artist: "Someone \($0)", album: "Album \($0)") }

        #expect(longestRun(clustered) == 5)

        let spaced = SmartShuffle.space(
            clustered, settings: SmartShuffleSettings(artistSpacing: 5, albumSpacing: 3)
        )

        // Nothing invented, nothing lost.
        #expect(spaced.count == clustered.count)
        #expect(Set(spaced.map(\.id)) == Set(clustered.map(\.id)))
        // And the block is broken up.
        #expect(longestRun(spaced) <= 2)
    }

    private func longestRun(_ tracks: [Track]) -> Int {
        var longest = 0
        var current = 0
        var last: String?
        for name in tracks.map({ $0.artistName ?? "" }) {
            current = name == last ? current + 1 : 1
            last = name
            longest = max(longest, current)
        }
        return longest
    }

    @Test("A saved ranking missing a new signal still mentions every one")
    func rankingSurvivesNewSignals() {
        let old = SmartShuffleSettings(ranking: [.rating], enabled: [.rating])
        #expect(Set(old.completeRanking) == Set(ShuffleSignal.allCases))
        #expect(old.completeRanking.first == .rating)
        #expect(old.completeRanking.count == ShuffleSignal.allCases.count)
    }
}

@Suite("At the size of a real library")
struct SmartShuffleScaleTests {
    /// All Music holds 61,287 songs. If this were slow the feature would be
    /// unusable exactly where it matters most.
    private static let wholeLibrary = 61_287
    /// A third of it, to have something to compare the whole against.
    private static let aThirdOfIt = 20_429

    /// The shuffle weights every song in one pass, sorts once, and spaces in one pass that never
    /// looks further than `scanLimit` ahead — so its cost should follow the size of the library and
    /// not the square of it.
    private static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Tripling the library triples the work, and does not square it")
    func staysLinear() {
        let server = ServerID()
        let libraries = [Self.aThirdOfIt, Self.wholeLibrary].map { count in
            (count, (0..<count).map { index in
                Track(
                    id: MediaID(server: server, rawValue: "t\(index)"),
                    title: "Track \(index)",
                    albumName: "Album \(index % 5_000)",
                    artistName: "Artist \(index % 1_200)",
                    rating: index % 5 == 0 ? StarRating(4) : nil,
                    playCount: index % 3,
                    playedAt: index % 7 == 0 ? Date() : nil
                )
            })
        }

        // Best of four, never the mean: contention only ever *adds* time, so the quickest of a few
        // attempts is the closest this machine got to the real cost.
        let clock = ContinuousClock()
        var best = [Int: Double]()
        for round in 0..<4 {
            for (count, tracks) in libraries {
                // Re-seeded to the same value before every measured call, and outside the timed
                // region.
                var generator = Seeded(UInt64(count))
                let started = clock.now
                let order = SmartShuffle.order(
                    tracks, settings: .init(), now: Self.pinnedNow, using: &generator
                )
                let elapsed = started.duration(to: clock.now).seconds
                #expect(order.count == tracks.count)
                guard round > 0 else { continue }
                best[count] = min(best[count] ?? .infinity, elapsed)
            }
        }
        // Never force-unwrapped: dropping the round count to watch the test
        // fail faster would otherwise turn a failing assertion into a crash
        // with no message on it.
        guard let small = best[Self.aThirdOfIt], let large = best[Self.wholeLibrary],
              small > 0, large.isFinite else {
            Issue.record("no round was measured, or the clock did not move")
            return
        }
        let growth = large / small

        print("""
            SCALE \(Self.aThirdOfIt) songs in \(String(format: "%.3f", small))s, \
            \(Self.wholeLibrary) in \(String(format: "%.3f", large))s — \
            \(String(format: "%.1f", growth))x for 3x the songs
            """)
        #expect(
            growth < 6,
            """
            tripling the library cost \(String(format: "%.1f", growth))x the time \
            (\(String(format: "%.3f", small))s -> \(String(format: "%.3f", large))s). \
            Sorting costs about 3.5x; something has gone quadratic.
            """
        )
        // The backstop a ratio cannot be: a regression that made every size equally slower would
        // keep the growth at 3.5x while the feature became unusable.
        #expect(large < 10, "took \(String(format: "%.2f", large))s")
    }
}

@Suite("Which shuffle a given queue gets")
struct SmartShuffleModeTests {
    @Test("An album is always shuffled plainly")
    func albumsStayPlain() {
        // Whatever the setting says, and whatever was asked for.
        #expect(SmartShuffle.isSmart(default: true, isAlbum: true) == false)
        #expect(SmartShuffle.isSmart(default: true, override: true, isAlbum: true) == false)
        #expect(SmartShuffle.isSmart(default: false, override: true, isAlbum: true) == false)
    }

    @Test("Everything else follows the setting")
    func othersFollowTheSetting() {
        #expect(SmartShuffle.isSmart(default: true, isAlbum: false) == true)
        #expect(SmartShuffle.isSmart(default: false, isAlbum: false) == false)
    }

    @Test("Asking for the other one wins over the setting")
    func overrideWins() {
        // What a long press on the shuffle button does.
        #expect(SmartShuffle.isSmart(default: false, override: true, isAlbum: false) == true)
        #expect(SmartShuffle.isSmart(default: true, override: false, isAlbum: false) == false)
    }
}

@Suite("Who counts as the same artist")
struct SmartShuffleArtistKeyTests {
    private static let server = ServerID()

    /// One song, two records, two spellings of the guest — and the gap used
    /// to see two strangers. This is the pair that was reported: it came
    /// round twice within a couple of songs on a radio station.
    @Test("Guests spelled differently are still the same artist")
    func aGuestCreditDoesNotSplitAnArtist() {
        let nate = MediaID(server: Self.server, rawValue: "266050")
        let one = SmartShuffle.artistKey(id: nate, name: "Nate Dogg feat. Butch Cassidy")
        let other = SmartShuffle.artistKey(
            id: nate, name: "Nate Dogg feat. Danny \u{201C}Butch\u{201D} Means"
        )
        #expect(one == other)
        #expect(one == SmartShuffle.artistKey(id: nate, name: "Nate Dogg"))
    }

    /// A compilation files everyone under one id, so the id cannot be what
    /// tells them apart.
    @Test("One id standing for many artists does not fuse them")
    func variousArtistsStayVarious() {
        let various = MediaID(server: Self.server, rawValue: "231123")
        #expect(
            SmartShuffle.artistKey(id: various, name: "Toto")
                != SmartShuffle.artistKey(id: various, name: "Chicago")
        )
    }

    /// And the other direction, which is why the id is not in the key at all.
    @Test("One artist under several ids is still one artist")
    func oneArtistUnderSeveralIdsStaysOne() {
        let various = MediaID(server: Self.server, rawValue: "231123")
        let bennett = MediaID(server: Self.server, rawValue: "36568")
        let gaga = MediaID(server: Self.server, rawValue: "9001")
        let onACompilation = SmartShuffle.artistKey(id: various, name: "Lady Gaga")
        let onTheDuetsRecord = SmartShuffle.artistKey(id: bennett, name: "Lady Gaga")
        let onHerOwn = SmartShuffle.artistKey(id: gaga, name: "Lady Gaga")
        #expect(onACompilation == onTheDuetsRecord)
        #expect(onACompilation == onHerOwn)
    }

    @Test("Either half alone still tells artists apart")
    func eitherHalfAloneStillWorks() {
        #expect(
            SmartShuffle.artistKey(id: nil, name: "Nate Dogg feat. Someone")
                == SmartShuffle.artistKey(id: nil, name: "Nate Dogg")
        )
        let id = MediaID(server: Self.server, rawValue: "7")
        #expect(SmartShuffle.artistKey(id: id, name: nil) != nil)
        #expect(SmartShuffle.artistKey(id: nil, name: nil) == nil)
        #expect(SmartShuffle.artistKey(id: nil, name: "   ") == nil)
    }

    @Test("Only a word that introduces a guest cuts the credit")
    func onlyRealCreditWordsCut() {
        #expect(SmartShuffle.primaryCredit("Fatboy Slim") == "fatboy slim")
        #expect(
            SmartShuffle.primaryCredit("Guns N\u{2019} Roses")
                == SmartShuffle.primaryCredit("Guns N\u{27} Roses")
        )
        #expect(SmartShuffle.primaryCredit("Portishead (feat. Nobody)") == "portishead")
        #expect(SmartShuffle.primaryCredit("Sigur R\u{00F3}s") == "sigur ros")
    }

    /// A band whose name happens to end on one of those words, and a credit that never named its
    /// guest.
    @Test("A guest word is only a guest word with a name on both sides")
    func aBandIsNotACredit() {
        #expect(SmartShuffle.primaryCredit("Little Feat") == "little feat")
        #expect(SmartShuffle.primaryCredit("Little Feat ") == "little feat")
        #expect(SmartShuffle.primaryCredit("Nate Dogg feat.") == "nate dogg feat")
        #expect(SmartShuffle.primaryCredit("Little Feat") != SmartShuffle.primaryCredit("Little"))
    }

    /// End to end: the reported pair, put side by side on purpose, pulled
    /// apart by the spacing that used to walk straight past it.
    @Test("The same recording under two credits is spaced apart")
    func theReportedPairIsSeparated() {
        let nate = MediaID(server: Self.server, rawValue: "266050")
        func nateSong(_ credit: String, album: String) -> Track {
            Track(
                id: MediaID(server: Self.server, rawValue: album),
                title: "Scared of Love",
                albumName: album,
                artistName: credit,
                artistID: nate
            )
        }
        var tracks = [
            nateSong("Nate Dogg feat. Butch Cassidy", album: "Ghetto Preacher"),
            nateSong("Nate Dogg feat. Danny Means", album: "G-Funk Classics"),
        ]
        for index in 1...10 {
            tracks.append(
                Track(
                    id: MediaID(server: Self.server, rawValue: "f\(index)"),
                    title: "Filler \(index)",
                    albumName: "Album \(index)",
                    artistName: "Artist \(index)",
                    artistID: MediaID(server: Self.server, rawValue: "a\(index)")
                )
            )
        }
        let settings = SmartShuffleSettings(
            ranking: [], enabled: [], artistSpacing: 5, albumSpacing: 0
        )
        let order = SmartShuffle.space(tracks, settings: settings)
        let first = order.firstIndex { $0.albumName == "Ghetto Preacher" }
        let second = order.firstIndex { $0.albumName == "G-Funk Classics" }
        #expect(first != nil)
        #expect(second != nil)
        if let first, let second {
            #expect(abs(first - second) > 5, "the same recording landed \(abs(first - second)) apart")
        }
    }
}

/// What share of a station may be the artist it was started from.
@Suite("A station's share of its own artist")
struct StationOwnShareTests {
    private static let server = ServerID()

    private static func song(_ title: String, artist: String, album: String) -> Track {
        Track(
            id: MediaID(server: server, rawValue: "\(artist)|\(album)|\(title)"),
            title: title,
            albumName: album,
            artistName: artist
        )
    }

    /// Interleaves the way `MediaActions.interleaved(own:rest:)` does, so
    /// the arithmetic under test is the one a station actually uses.
    private static func interleaved(own: [Track], rest: [Track]) -> [Track] {
        guard !own.isEmpty else { return rest }
        guard !rest.isEmpty else { return own }
        let share = Double(rest.count + 1) / Double(own.count + 1)
        var result: [Track] = []
        var next = 0
        for (offset, track) in rest.enumerated() {
            result.append(track)
            while next < own.count, Double(offset + 1) >= share * Double(next + 1) {
                result.append(own[next])
                next += 1
            }
        }
        result.append(contentsOf: own[next...])
        return result
    }

    private static func station(own: Int, company: Int) -> [Track] {
        interleaved(
            own: (0..<own).map { song("Theirs \($0)", artist: "The Seed", album: "Record \($0)") },
            rest: (0..<company).map {
                song("Else \($0)", artist: "Artist \($0)", album: "Other \($0)")
            }
        )
    }

    private static func longestRun(ofArtist artist: String, in tracks: [Track]) -> Int {
        var longest = 0
        var current = 0
        for track in tracks {
            current = track.artistName == artist ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    /// The share is not a matter of taste: the spacing pass allows one song
    /// per artist per `artistSpacing + 1` slots, and `ownAllowance` asks for
    /// `company / (gap + 1)`, which is just inside it.
    @Test("A station sized to the artist gap comes through the spacing pass spread out")
    func sizedToTheGap() {
        let gap = 5
        let company = 120
        let allowance = company / (gap + 1)
        let spaced = SmartShuffle.space(
            Self.station(own: allowance, company: company),
            settings: SmartShuffleSettings(artistSpacing: gap, albumSpacing: 0)
        )
        #expect(spaced.count == company + allowance)
        #expect(
            Self.longestRun(ofArtist: "The Seed", in: spaced) == 1,
            "the seed artist should never land twice in a row"
        )
    }

    /// Why the allowance is that and not simply "more".
    @Test("Asking for more than the gap allows piles the surplus up at the end")
    func overSubscribedClumps() {
        let gap = 5
        let company = 120
        let greedy = Int(Double(company) * 0.3)
        let spaced = SmartShuffle.space(
            Self.station(own: greedy, company: company),
            settings: SmartShuffleSettings(artistSpacing: gap, albumSpacing: 0)
        )
        #expect(
            Self.longestRun(ofArtist: "The Seed", in: spaced) > 1,
            "a third of a station cannot be one artist at a gap of \(gap)"
        )
        // Measured, not estimated: a hundred and twenty neighbours against thirty-six of the
        // artist's own ends `...S.....S.....S..SSSSSSSSSSSS` — twelve of them back to back, where
        // the allowance above never puts two together at all.
        #expect(
            spaced.suffix(12).allSatisfy { $0.artistName == "The Seed" },
            "the surplus lands at the end, which is what the allowance avoids"
        )
    }

    /// The other end of the same setting.
    @Test("A narrow artist gap still reaches the end of the station")
    func narrowGapReachesTheEnd() {
        let gap = 1
        let company = 120
        let allowance = company / (gap + 1)
        let spaced = SmartShuffle.space(
            Self.station(own: allowance, company: company),
            settings: SmartShuffleSettings(artistSpacing: gap, albumSpacing: 0)
        )
        let lastQuarter = spaced.suffix(spaced.count / 4)
        #expect(
            lastQuarter.contains { $0.artistName == "The Seed" },
            "the artist a station is named after should still be in its final quarter"
        )
    }

    /// Which of a catalogue counts as "by this artist".
    @Test("A featured credit is still the same artist")
    func featuredCreditIsTheSameArtist() {
        let lead = DJRepeatWindow.leadArtist(of: "Justin Bieber")
        #expect(DJRepeatWindow.leadArtist(of: "Justin Bieber feat. Ludacris") == lead)
        #expect(DJRepeatWindow.leadArtist(of: "justin bieber & ludacris") == lead)
        #expect(DJRepeatWindow.leadArtist(of: "Ludacris feat. Justin Bieber") != lead)
    }
}
