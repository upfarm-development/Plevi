import Foundation
import Testing
@testable import PleviDomain

@Suite("Spotlight: one artist a week")
struct SpotlightTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func album(_ raw: String, critic: Double? = nil, stars: StarRating? = nil) -> Album {
        Album(id: id(raw), name: raw, rating: stars, criticRating: critic)
    }

    private func candidate(_ name: String, critic: [Double]) -> Spotlight.Candidate {
        Spotlight.Candidate(
            artistName: name,
            topAlbums: critic.enumerated().map { offset, score in album("\(name)-\(offset)", critic: score) }
        )
    }

    // MARK: Week numbering

    @Test("ISO week number does not collide across years")
    func weekNumberIsYearQualified() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        // The first Monday of January 2026 and of January 2025 both fall in
        // "week 1" of their own year — the point of the test.
        let jan2026 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let jan2025 = calendar.date(from: DateComponents(year: 2025, month: 1, day: 6))!
        let week2026 = Spotlight.weekNumber(for: jan2026, calendar: calendar)
        let week2025 = Spotlight.weekNumber(for: jan2025, calendar: calendar)
        #expect(week2026 != week2025)
        #expect(week2026 == 202_602)
        #expect(week2025 == 202_502)
    }

    @Test("A week number round-trips to the Monday it names")
    func weekNumberRoundTrips() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let monday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 24))!
        let week = Spotlight.weekNumber(for: monday, calendar: calendar)
        let recovered = Spotlight.date(forWeek: week, calendar: calendar)
        #expect(recovered.map { calendar.isDate($0, inSameDayAs: monday) } == true)
    }

    @Test("The same calendar week gives the same number on any day within it")
    func weekNumberIsStableWithinAWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let monday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 24))!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 30))!
        #expect(Spotlight.weekNumber(for: monday, calendar: calendar)
            == Spotlight.weekNumber(for: sunday, calendar: calendar))
    }

    // MARK: Eligibility

    @Test("An artist under the rated-album floor is not a candidate, however good those albums are")
    func fewerThanMinimumRatedAlbumsIsIneligible() {
        let thin = candidate("Thin Artist", critic: [10, 10])
        #expect(Spotlight.pick(for: 1, from: [thin], usingCriticRating: true) == nil)
    }

    @Test("An artist whose mean falls short of the floor is not a candidate")
    func belowMeanThresholdIsIneligible() {
        let mediocre = candidate("Mediocre Artist", critic: [8, 8, 6])
        #expect(Spotlight.pick(for: 1, from: [mediocre], usingCriticRating: true) == nil)
    }

    @Test("An artist whose mean meets the floor exactly is eligible")
    func meetingTheFloorExactlyIsEligible() {
        let exact = candidate("Exact Artist", critic: [8, 8, 8])
        let picked = Spotlight.pick(for: 1, from: [exact], usingCriticRating: true)
        #expect(picked?.artistName == "Exact Artist")
    }

    @Test("Star-rating candidates are judged on the 0-5 floor, not the critic one")
    func starRatingUsesItsOwnFloor() {
        let starArtist = Spotlight.Candidate(
            artistName: "Star Artist",
            topAlbums: [
                album("s0", stars: StarRating(4)), album("s1", stars: StarRating(4)),
                album("s2", stars: StarRating(4)),
            ]
        )
        #expect(Spotlight.pick(for: 1, from: [starArtist], usingCriticRating: false)?.artistName == "Star Artist")
        // The same three-4-star albums would fall far short of the *critic*
        // floor of 8 if misjudged on that scale instead.
        #expect(Spotlight.pick(for: 1, from: [starArtist], usingCriticRating: true) == nil)
    }

    // MARK: Rotation

    @Test("An artist shown within the rest window is passed over while another is eligible")
    func restingArtistIsPassedOver() {
        let a = candidate("Artist A", critic: [9, 9, 9])
        let b = candidate("Artist B", critic: [8, 8, 8])
        let recent = [Spotlight.Appearance(artistName: "Artist A", week: 10)]
        let picked = Spotlight.pick(for: 12, from: [a, b], usingCriticRating: true, recentlyShown: recent)
        #expect(picked?.artistName == "Artist B")
    }

    @Test("A rest window survives a year boundary — the encoded week number is not a linear count")
    func restWindowSurvivesYearBoundary() {
        // The last ISO week of 2025 and the first of 2026: one real week apart, but 202601 - 202552
        // is 49 — subtracting the encoded numbers directly would read this as long out of the rest
        // window when it has barely begun.
        #expect(Spotlight.weeksElapsed(from: 202_552, to: 202_601) == 1)

        let a = candidate("Only Artist", critic: [9, 9, 9])
        let shownLastWeekOfPriorYear = [Spotlight.Appearance(artistName: "Only Artist", week: 202_552)]
        #expect(Spotlight.pick(
            for: 202_601, from: [a], usingCriticRating: true, recentlyShown: shownLastWeekOfPriorYear
        )?.artistName == "Only Artist")
    }

    @Test("An artist rests for exactly restWeeks, not one week more or less")
    func restWindowBoundary() {
        let a = candidate("Only Artist", critic: [9, 9, 9])
        // Shown exactly `restWeeks` ago: the window has closed.
        let justOutside = [Spotlight.Appearance(artistName: "Only Artist", week: 1)]
        #expect(Spotlight.pick(
            for: 1 + Spotlight.restWeeks, from: [a], usingCriticRating: true, recentlyShown: justOutside
        )?.artistName == "Only Artist")
        // Shown one week later than that: still resting, and the only
        // candidate there is — the rest rule is dropped rather than
        // leaving no pick at all.
        let justInside = [Spotlight.Appearance(artistName: "Only Artist", week: 2)]
        #expect(Spotlight.pick(
            for: 2 + Spotlight.restWeeks - 1, from: [a], usingCriticRating: true, recentlyShown: justInside
        )?.artistName == "Only Artist")
    }

    @Test("This week's own settled appearance is not treated as history against itself")
    func todaysOwnAppearanceIsNotResting() {
        let a = candidate("Only Artist", critic: [9, 9, 9])
        let settledThisWeek = [Spotlight.Appearance(artistName: "Only Artist", week: 5)]
        #expect(Spotlight.pick(
            for: 5, from: [a], usingCriticRating: true, recentlyShown: settledThisWeek
        )?.artistName == "Only Artist")
    }

    // MARK: Determinism

    @Test("The same week and the same candidates always land on the same artist")
    func deterministicAcrossCalls() {
        let candidates = (0..<8).map { candidate("Artist \($0)", critic: [9, 9, 9]) }
        let first = Spotlight.pick(for: 42, from: candidates, usingCriticRating: true)
        let second = Spotlight.pick(for: 42, from: candidates, usingCriticRating: true)
        #expect(first == second)
    }

    @Test("Consecutive weeks do not walk the candidate list in order")
    func doesNotWalkInOrder() {
        let candidates = (0..<10).map { candidate("Artist \($0)", critic: [9, 9, 9]) }
        let picks = (1...5).map { Spotlight.pick(for: $0, from: candidates, usingCriticRating: true)?.artistName }
        // Not every week landing on "Artist 0", "Artist 1", "Artist 2"...
        let sequential = (0..<5).map { "Artist \($0)" }
        #expect(picks.map { $0 ?? "" } != sequential)
    }

    // MARK: Fairness

    /// The ISO week number `offset` weeks after the first of 2026, which is a
    /// real sequence — the rest window is measured in real weeks, so the
    /// tests need real week numbers rather than counting up from 1.
    private func week(_ offset: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let date = calendar.date(byAdding: .day, value: offset * 7, to: start)!
        return Spotlight.weekNumber(for: date, calendar: calendar)
    }

    @Test("Someone featured before is far less likely than someone who never was, once the rest is over")
    func leansAwayFromRepeats() {
        let candidates = (0..<20).map { candidate("Artist \($0)", critic: [9, 9, 9]) }
        // Artist 7 was featured long ago: outside the rest, but on record.
        let history = [Spotlight.Appearance(artistName: "Artist 7", week: week(0))]
        let picks = (100..<500).compactMap {
            Spotlight.pick(for: week($0), from: candidates, usingCriticRating: true, recentlyShown: history)?.artistName
        }
        let repeats = picks.filter { $0 == "Artist 7" }.count
        // Uniform would be about 20 of 400; a sixteenth as likely is about one.
        #expect(repeats <= 5)
        #expect(picks.count == 400)
    }

    @Test("Over years, the freeze holds and everyone's number of turns stays close")
    func longRunIsFairAndRested() {
        let candidates = (0..<100).map { candidate("Artist \($0)", critic: [9, 9, 9]) }
        var history: [Spotlight.Appearance] = []
        var featured: [String: [Int]] = [:]
        for offset in 0..<520 {   // ten years of weeks
            let thisWeek = week(offset)
            guard let pick = Spotlight.pick(
                for: thisWeek, from: candidates, usingCriticRating: true, recentlyShown: history
            ) else { Issue.record("no pick in week \(offset)"); return }
            history.append(Spotlight.Appearance(artistName: pick.artistName, week: thisWeek))
            featured[pick.artistName, default: []].append(offset)
        }
        // Never inside the rest window.
        for (name, weeks) in featured {
            for (a, b) in zip(weeks, weeks.dropFirst()) {
                #expect(b - a >= Spotlight.restWeeks, "\(name) came back after \(b - a) weeks")
            }
        }
        // And the turns stay close: nobody far ahead, nobody left out.
        let counts = (0..<100).map { featured["Artist \($0)"]?.count ?? 0 }
        #expect(counts.max()! - counts.min()! <= 3, "turns ranged \(counts.min()!)...\(counts.max()!)")
    }
}
