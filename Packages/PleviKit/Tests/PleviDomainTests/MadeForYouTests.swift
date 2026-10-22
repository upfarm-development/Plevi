import Foundation
import Testing
@testable import PleviDomain

@Suite struct MadeForYouTests {
    private static let server = ServerID(rawValue: UUID())

    /// A played song, shaped the way the index hands them over.
    private func track(
        _ title: String,
        by artist: String,
        id: String? = nil,
        genre: String? = nil,
        year: Int? = nil
    ) -> Track {
        Track(
            id: MediaID(server: Self.server, rawValue: id ?? "\(artist)-\(title)"),
            title: title,
            artistName: artist,
            artistID: MediaID(server: Self.server, rawValue: "artist-\(artist)"),
            year: year,
            genre: genre,
            artwork: ArtworkID(server: Self.server, rawValue: "art-\(artist)")
        )
    }

    /// Reads a mix's artist name, or nothing if it is not an artist mix.
    private func artistName(_ mix: MadeForYou.Mix) -> String? {
        if case .artist(let name, _, _) = mix.kind { return name }
        return nil
    }

    private func seeds(_ mix: MadeForYou.Mix) -> [MediaID] {
        if case .artist(_, _, let songs) = mix.kind { return songs }
        return []
    }

    /// `history` is newest first, so several plays of one artist spread
    /// through it should outrank a burst of another further back.
    private func history(_ pairs: [(String, Int)]) -> [Track] {
        var out: [Track] = []
        for (artist, count) in pairs {
            for index in 0..<count {
                out.append(track("song\(index)", by: artist, id: "\(artist)-\(index)"))
            }
        }
        return out
    }

    @Test func picksTheArtistsPlayedMost() {
        let mixes = MadeForYou.mixes(
            from: history([("Aretha", 12), ("Oscar", 8), ("Natasha", 4)]),
            limit: 5
        )
        #expect(mixes.compactMap(artistName) == ["Aretha", "Oscar", "Natasha"])
    }

    /// One play is a try, not a taste. A shelf built on a quiet week should
    /// be short rather than full of artists someone skipped through once.
    @Test func oneOffsAreNotWorthAMix() {
        var songs = history([("Aretha", 6)])
        songs.append(contentsOf: (0..<9).map { track("x", by: "OneOff\($0)", id: "o\($0)") })
        let mixes = MadeForYou.mixes(from: songs, limit: 5)
        #expect(mixes.compactMap(artistName) == ["Aretha"])
    }

    /// What is being played now beats what was played a fortnight ago, even
    /// when the fortnight has more songs in it.
    @Test func recentListeningOutweighsOlder() {
        // Oscar is right at the front; Aretha is 250 songs back with more.
        var songs = history([("Oscar", 10)])
        songs.append(contentsOf: (0..<250).map { track("filler", by: "Filler\($0)", id: "f\($0)") })
        songs.append(contentsOf: history([("Aretha", 40)]))
        let mixes = MadeForYou.mixes(from: songs, limit: 2)
        #expect(artistName(mixes[0]) == "Oscar")
    }

    @Test func aMixCarriesItsArtistAndArtwork() throws {
        let mix = try #require(MadeForYou.mixes(from: history([("Aretha", 4)])).first)
        guard case .artist(let name, let id, let songs) = mix.kind else {
            Issue.record("not an artist mix"); return
        }
        #expect(name == "Aretha")
        #expect(id?.rawValue == "artist-Aretha")
        #expect(mix.artwork?.rawValue == "art-Aretha")
        #expect(songs.count == 4)
    }

    /// The same song must not be kept twice, or a mix seeded from "three
    /// different songs" is one song three times.
    @Test func seedsAreDistinct() {
        let repeated = (0..<10).map { _ in track("Respect", by: "Aretha", id: "same") }
        let mix = MadeForYou.mixes(from: repeated).first
        #expect(mix.map(seeds) == [MediaID(server: Self.server, rawValue: "same")])
    }

    /// Different every day, and never the same two days running — which is
    /// the whole point of walking the list rather than picking at random.
    @Test func seedsWalkOnEachDay() throws {
        let mix = try #require(MadeForYou.mixes(from: history([("Aretha", 9)])).first)
        let monday = MadeForYou.seeds(for: mix, dayOfYear: 100, count: 3)
        let tuesday = MadeForYou.seeds(for: mix, dayOfYear: 101, count: 3)
        #expect(monday.count == 3)
        #expect(Set(monday).count == 3)
        #expect(monday != tuesday)
        #expect(monday.first != tuesday.first)
    }

    /// A mix with fewer songs than a day's seeds still gives what it has,
    /// without repeating one of them into the same blend.
    @Test func aThinMixDoesNotRepeatItself() throws {
        let mix = try #require(MadeForYou.mixes(from: history([("Aretha", 2)])).first)
        let asked = MadeForYou.seeds(for: mix, dayOfYear: 7, count: 3)
        #expect(asked.count == 2)
        #expect(Set(asked).count == 2)
    }

    @Test func nothingPlayedGivesNothing() {
        #expect(MadeForYou.mixes(from: []).isEmpty)
    }
}

/// The genre and decade half of the shelf.
@Suite struct MadeForYouTagTests {
    private static let server = ServerID(rawValue: UUID())

    private static let shape: LibraryShape = {
        let families = [
            GenreFamily.Family(name: "Pop/Rock", members: ["Pop/Rock"], songs: 19454),
            GenreFamily.Family(name: "Jazz", members: ["Jazz", "Swing", "Big band"], songs: 11304),
            GenreFamily.Family(name: "R&B", members: ["R&B", "Soul"], songs: 3437),
            GenreFamily.Family(name: "Reggae", members: ["Reggae"], songs: 751),
            GenreFamily.Family(name: "Children's", members: ["Kids", "Jeunesse"], songs: 331),
            GenreFamily.Family(name: "Hawaiian", members: ["Hawaiian"], songs: 49),
        ]
        var decades: [String: Int] = [:]
        decades[LibraryShape.key(genre: "Jazz", decade: 1950)] = 3037
        decades[LibraryShape.key(genre: "Jazz", decade: 1960)] = 2800
        decades[LibraryShape.key(genre: "Pop/Rock", decade: 1990)] = 3049
        decades[LibraryShape.key(genre: "R&B", decade: 1990)] = 407
        decades[LibraryShape.key(genre: "Reggae", decade: 1970)] = 200
        decades[LibraryShape.key(genre: "Children's", decade: 2010)] = 140
        decades[LibraryShape.key(genre: "Hawaiian", decade: 1960)] = 20
        return LibraryShape(totalTracks: 61287, families: families, decadeCounts: decades)
    }()

    private func played(_ genre: String, _ year: Int, times: Int, artist: String) -> [Track] {
        (0..<times).map { index in
            Track(
                id: MediaID(server: Self.server, rawValue: "\(genre)-\(year)-\(index)"),
                title: "song\(index)",
                artistName: artist,
                year: year,
                genre: genre
            )
        }
    }

    private func titles(_ mixes: [MadeForYou.Mix]) -> [String] {
        mixes.filter { !$0.isArtist }.map(\.title)
    }

    /// The thing that was asked for: a lot of fifties jazz gives a fifties
    /// jazz mix, not a jazz mix and not a fifties mix.
    @Test func fiftiesJazzListeningGivesAFiftiesJazzMix() {
        let history = played("Jazz", 1955, times: 20, artist: "Miles")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape)
        #expect(titles(mixes).contains("1950s Jazz"))
    }

    /// A genre without much music is offered whole, however clearly the
    /// listening points at one decade of it — cutting it up would turn one
    /// mix worth playing into several that are not.
    @Test func aSmallGenreIsNotCutIntoDecades() {
        let history = played("Reggae", 1975, times: 20, artist: "Bob")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape)
        #expect(titles(mixes).contains("Reggae"))
        #expect(!titles(mixes).contains("1970s Reggae"))
    }

    /// A genre covering a third of the library is a shuffle with a label on.
    /// Its decades are mixes; it is not.
    @Test func aGenreTooBigToBeAMixIsOnlyOfferedByDecade() {
        var history = played("Pop/Rock", 1995, times: 30, artist: "Blur")
        history += played("Pop/Rock", 2005, times: 5, artist: "Keane")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape)
        #expect(titles(mixes).contains("1990s Pop/Rock"))
        #expect(!titles(mixes).contains("Pop/Rock"))
    }

    /// The ceiling on its own, with no decade mix to hide behind.
    @Test func aGenreTooBigToBeAMixIsNotOfferedEvenWithNoDecadeToUse() {
        let history = played("Pop/Rock", 1935, times: 30, artist: "Whoever")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape)
        #expect(titles(mixes).isEmpty)
    }

    /// And the same rule must not throw out a genre that *is* a slice.
    @Test func aGenreSmallEnoughToBeAMixIsOffered() {
        let history = played("R&B", 1975, times: 20, artist: "Aretha")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape)
        #expect(titles(mixes) == ["R&B"])
    }

    /// Nothing is offered that the library cannot fill.
    @Test func aGenreWithTooLittleMusicIsNotOfferedAtAll() {
        let history = played("Hawaiian", 1965, times: 20, artist: "Israel")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape)
        #expect(titles(mixes).isEmpty)
    }

    /// The library's several names for one genre are one genre. Ten plays
    /// spread over three spellings is ten plays of Jazz, not three piles of
    /// three or four.
    @Test func theSpellingsOfOneGenreCountTogether() {
        var history = played("Jazz", 1955, times: 4, artist: "Miles")
        history += played("Swing", 1955, times: 4, artist: "Basie")
        history += played("Big band", 1955, times: 4, artist: "Ellington")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape)
        #expect(titles(mixes).contains("1950s Jazz"))
    }

    /// One genre gives one card. A shelf with "1950s Jazz" and "Jazz" on it
    /// is saying the same thing twice.
    @Test func aGenreAppearsOnce() {
        var history = played("Jazz", 1955, times: 20, artist: "Miles")
        history += played("Jazz", 1965, times: 18, artist: "Coltrane")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape)
        #expect(titles(mixes).filter { $0.hasSuffix("Jazz") }.count == 1)
    }

    /// Neither kind may take the whole shelf.
    @Test func bothKindsGetARow() {
        var history: [Track] = []
        for artist in ["Miles", "Coltrane", "Monk", "Evans", "Mingus"] {
            history += played("Jazz", 1955, times: 8, artist: artist)
        }
        history += played("R&B", 1995, times: 8, artist: "Aretha")
        let mixes = MadeForYou.mixes(from: history, shape: Self.shape, limit: 6)
        #expect(mixes.filter(\.isArtist).count <= MadeForYou.artistsAtMost)
        #expect(mixes.filter { !$0.isArtist }.count <= MadeForYou.tagsAtMost)
        #expect(mixes.contains { $0.isArtist })
        #expect(mixes.contains { !$0.isArtist })
    }

    /// Without a library to measure against, no genre mix can be judged worth
    /// offering — so none is. The artist mixes still work.
    @Test func withoutALibraryShapeThereAreNoGenreMixes() {
        let history = played("Jazz", 1955, times: 20, artist: "Miles")
        let mixes = MadeForYou.mixes(from: history)
        #expect(titles(mixes).isEmpty)
        #expect(mixes.allSatisfy { $0.isArtist })
    }
}

/// The shelf as a rolling line: one new mix every other day, newest first,
/// ten kept.
@Suite struct MadeForYouRotationTests {
    private func mix(_ name: String) -> MadeForYou.Mix {
        MadeForYou.Mix(kind: .artist(name: name, artistID: nil, seeds: []))
    }

    private func names(_ mixes: [MadeForYou.Mix]) -> [String] {
        mixes.map(\.title)
    }

    private func pool(_ names: [String]) -> [MadeForYou.Mix] {
        names.map(mix)
    }

    @Test("An empty shelf fills up in one go rather than one mix a day")
    func firstFill() {
        let shelf = MadeForYou.rotate(
            existing: [],
            candidates: pool((1...(MadeForYou.carouselSize * 2)).map { "A\($0)" }),
            adding: 0
        )
        #expect(shelf.count == MadeForYou.carouselSize)
        #expect(names(shelf).first == "A1")
    }

    @Test("The new mix goes to the front and the rest shift back one place")
    func newestGoesFirst() {
        let existing = pool(["B", "C", "D"])
        let shelf = MadeForYou.rotate(
            existing: existing,
            candidates: pool(["B", "C", "D", "E"]),
            adding: 1
        )
        #expect(names(shelf) == ["E", "B", "C", "D"])
    }

    @Test("The shelf never grows past its size")
    func capped() {
        let size = MadeForYou.carouselSize
        let existing = pool((1...size).map { "M\($0)" })
        let shelf = MadeForYou.rotate(
            existing: existing,
            candidates: pool(["New"]),
            adding: 1
        )
        #expect(shelf.count == size)
        #expect(names(shelf).first == "New")
        // The oldest has fallen off the end.
        #expect(!names(shelf).contains("M\(size)"))
        #expect(names(shelf).last == "M\(size - 1)")
    }

    @Test("A phone left in a drawer catches up in one go, newest still first")
    func catchesUp() {
        let existing = pool(["Old1", "Old2"])
        let shelf = MadeForYou.rotate(
            existing: existing,
            candidates: pool(["Old1", "Old2", "N1", "N2", "N3"]),
            adding: 3
        )
        // Three arrived; the last to arrive is at the front.
        #expect(names(shelf) == ["N3", "N2", "N1", "Old1", "Old2"])
    }

    @Test("A mix already on the shelf is never added twice")
    func noDuplicates() {
        let existing = pool(["B", "C"])
        let shelf = MadeForYou.rotate(
            existing: existing,
            candidates: pool(["B", "C"]),
            adding: 1
        )
        #expect(names(shelf) == ["B", "C"])
    }

    @Test("With nothing new to offer the shelf stays exactly as it was")
    func staysPutWhenNothingIsNew() {
        let existing = pool(["B", "C", "D"])
        let shelf = MadeForYou.rotate(
            existing: existing,
            candidates: pool(["D", "C", "B"]),
            adding: 4
        )
        // Same mixes, same order — it does not shuffle itself to look busy.
        #expect(names(shelf) == ["B", "C", "D"])
    }

    @Test("No rotation has passed, so nothing moves")
    func nothingOwed() {
        let existing = pool(["B", "C"])
        let shelf = MadeForYou.rotate(
            existing: existing,
            candidates: pool(["New"]),
            adding: 0
        )
        #expect(names(shelf) == ["B", "C"])
    }

    // MARK: The clock

    @Test("A rotation is one day long")
    func rotationIsOneDay() {
        let calendar = Calendar(identifier: .gregorian)
        func date(_ day: Int) -> Date {
            Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200)
        }
        func period(_ day: Int) -> Int {
            MadeForYou.rotationPeriod(for: date(day), calendar: calendar)
        }
        func dayNumber(_ day: Int) -> Int {
            MadeForYou.dayNumber(for: date(day), calendar: calendar)
        }

        for day in 20_000..<20_020 {
            #expect(dayNumber(day + 1) == dayNumber(day) + 1)
            // Every day is exactly one rotation on: a mix a day, and never
            // a day that brings nothing.
            #expect(period(day + 1) == period(day) + 1)
        }
    }

    @Test("The day number carries across a new year")
    func dayNumberIsMonotonic() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 31
        components.hour = 12
        let newYearsEve = calendar.date(from: components)!
        let newYearsDay = newYearsEve.addingTimeInterval(86_400)
        // The old day-of-year would have gone from 365 back to 1 here.
        #expect(
            MadeForYou.dayNumber(for: newYearsDay, calendar: calendar)
                == MadeForYou.dayNumber(for: newYearsEve, calendar: calendar) + 1
        )
    }
}

/// Assembling the shelf: what to show, and what still needs looking up.
@Suite struct MadeForYouAssemblyTests {
    private func mix(_ name: String, artwork: ArtworkID? = nil) -> MadeForYou.Mix {
        MadeForYou.Mix(
            kind: .artist(name: name, artistID: nil, seeds: []),
            artwork: artwork
        )
    }

    private func names(_ mixes: [MadeForYou.Mix]) -> [String] { mixes.map(\.title) }

    @Test("Nothing stored is never up to date")
    func emptyIsNotUpToDate() {
        #expect(!MadeForYou.isUpToDate(nil, at: 10))
    }

    @Test("A shelf with nothing on it is asked again rather than left empty")
    func emptyShelfIsRebuilt() {
        let stored = MadeForYou.Shelf(mixes: [], period: 10)
        // A library that had nothing to offer when it was first asked should
        // not go on showing nothing until the next rotation.
        #expect(!MadeForYou.isUpToDate(stored, at: 10))
    }

    @Test("A shelf already brought up to this rotation is left alone")
    func upToDate() {
        let stored = MadeForYou.Shelf(mixes: [mix("A")], period: 10)
        #expect(MadeForYou.isUpToDate(stored, at: 10))
        #expect(MadeForYou.isUpToDate(stored, at: 9))
        #expect(!MadeForYou.isUpToDate(stored, at: 11))
    }

    /// The bug, as a test.
    @Test("A mix that arrives with artwork is still counted as new")
    func newnessIsNotInferredFromArtwork() {
        let server = ServerID(rawValue: UUID())
        let seeded = mix("Aretha", artwork: ArtworkID(server: server, rawValue: "a-track-cover"))
        let assembly = MadeForYou.assemble(stored: nil, candidates: [seeded], at: 10)
        #expect(assembly.newlyArrived.contains(seeded.id))
    }

    @Test("Everything on a first build is new")
    func firstBuildDressesEverything() {
        let candidates = (1...(MadeForYou.carouselSize + 2)).map { mix("A\($0)") }
        let assembly = MadeForYou.assemble(stored: nil, candidates: candidates, at: 10)
        #expect(assembly.mixes.count == MadeForYou.carouselSize)
        #expect(assembly.newlyArrived.count == MadeForYou.carouselSize)
    }

    @Test("Only the arrival is new; what was already there is left dressed")
    func onlyArrivalsAreNew() {
        let stored = MadeForYou.Shelf(mixes: [mix("B"), mix("C")], period: 10)
        let assembly = MadeForYou.assemble(
            stored: stored,
            candidates: [mix("B"), mix("C"), mix("D")],
            at: 11
        )
        #expect(names(assembly.mixes) == ["D", "B", "C"])
        #expect(assembly.newlyArrived == ["artist:d"])
    }

    @Test("No rotation gone by means nothing new and nothing moved")
    func noRotation() {
        let stored = MadeForYou.Shelf(mixes: [mix("B"), mix("C")], period: 10)
        let assembly = MadeForYou.assemble(
            stored: stored,
            candidates: [mix("B"), mix("C"), mix("D")],
            at: 10
        )
        #expect(names(assembly.mixes) == ["B", "C"])
        #expect(assembly.newlyArrived.isEmpty)
    }

    @Test("A shelf left for a month catches up without owing more than it holds")
    func longAbsence() {
        let stored = MadeForYou.Shelf(mixes: [mix("B")], period: 10)
        let candidates = [mix("B")] + (1...30).map { mix("N\($0)") }
        let assembly = MadeForYou.assemble(stored: stored, candidates: candidates, at: 200)
        #expect(assembly.mixes.count == MadeForYou.carouselSize)
        // A shelf's worth arrived, so the one that was there has been
        // pushed off the end.
        #expect(assembly.newlyArrived.count == MadeForYou.carouselSize)
    }
}


@Suite("The day number a shelf rotates on")
struct DayNumberTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// Every civil day of a year, at 09:00 local.
    private func days(in zone: String, year: Int) -> [Date] {
        let calendar = calendar(zone)
        let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1, hour: 9))!
        return (0..<365).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }

    @Test("It advances by exactly one each day in zones whose offset crosses zero")
    func noRepeatsOrSkipsAcrossDST() {
        for zone in ["Europe/London", "Europe/Dublin", "Europe/Lisbon", "America/New_York",
                     "Europe/Berlin", "Pacific/Auckland", "UTC"] {
            let calendar = calendar(zone)
            let numbers = days(in: zone, year: 2026).map { MadeForYou.dayNumber(for: $0, calendar: calendar) }
            for pair in zip(numbers, numbers.dropFirst()) {
                #expect(pair.1 - pair.0 == 1, "\(zone): \(pair.0) then \(pair.1)")
            }
        }
    }

    @Test("Any time on the same local day gives the same number")
    func stableWithinADay() {
        let calendar = calendar("Europe/London")
        let morning = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 0, minute: 30))!
        let night = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 23, minute: 30))!
        #expect(MadeForYou.dayNumber(for: morning, calendar: calendar)
                == MadeForYou.dayNumber(for: night, calendar: calendar))
    }
}
