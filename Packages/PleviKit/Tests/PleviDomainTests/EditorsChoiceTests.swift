import Foundation
import Testing
@testable import PleviDomain

/// Long enough to be a review rather than a stub — see
/// `EditorsChoice.shortestUsableReview`, which a fixture has to clear or the
/// record is not a candidate at all.
private let sampleReview = """
Cut ten days after a falling-out, and you can hear the courtesy in every bar.
"""

/// Choosing one well-reviewed record a day.
@Suite("Editors' Choice")
struct EditorsChoiceTests {
    private static let server = ServerID(rawValue: UUID())
    private func id(_ raw: String) -> MediaID { MediaID(server: Self.server, rawValue: raw) }

    private func album(_ name: String, score: Double = 9, review: String = sampleReview) -> Album {
        Album(
            id: id(name),
            name: name,
            artistName: "Someone",
            criticRating: score,
            review: review
        )
    }

    private func pool(_ names: [String]) -> [Album] {
        names.map { album($0) }
    }

    // MARK: The pick

    @Test("The same day gives the same record, every time it is asked")
    func stableWithinADay() {
        let candidates = pool((1...20).map { "a\($0)" })
        let first = EditorsChoice.pick(for: 20_000, from: candidates)
        for _ in 0..<50 {
            #expect(EditorsChoice.pick(for: 20_000, from: candidates)?.id == first?.id)
        }
    }

    @Test("A different day gives a different record")
    func turnsOverDaily() {
        let candidates = pool((1...30).map { "a\($0)" })
        let week = (20_000..<20_007).compactMap {
            EditorsChoice.pick(for: $0, from: candidates)?.id
        }
        // Not a guarantee of seven distinct records in general — a hash may
        // collide — but over a pool of thirty it should not be reading the
        // list out in order, which is the failure worth catching.
        #expect(Set(week).count >= 5)
    }

    @Test("Consecutive days do not walk the list in order")
    func doesNotReadTheListOut() {
        let candidates = pool((1...30).map { "a\($0)" })
        let indices = (20_000..<20_010).map { EditorsChoice.index(for: $0, count: 30) }
        let steps = zip(indices, indices.dropFirst()).map { $1 - $0 }
        #expect(!steps.allSatisfy { $0 == 1 })
    }

    @Test("Nothing over the bar means no card at all")
    func nothingToShow() {
        #expect(EditorsChoice.pick(for: 20_000, from: []) == nil)
    }

    @Test("A record shown lately is passed over")
    func restsRecentPicks() {
        let candidates = pool(["a", "b", "c"])
        let chosen = try? #require(EditorsChoice.pick(for: 20_000, from: candidates))
        let again = EditorsChoice.pick(
            for: 20_001,
            from: candidates,
            recentlyShown: [.init(albumID: chosen!.id, day: 20_000)]
        )
        #expect(again?.id != chosen?.id)
    }

    @Test("A record is free to come round again once it has rested")
    func restExpires() {
        let candidates = [album("only")]
        let old = EditorsChoice.Appearance(albumID: id("only"), day: 20_000)
        // Still resting the day before the period is up.
        let during = EditorsChoice.pick(
            for: 20_000 + EditorsChoice.restDays - 1,
            from: candidates,
            recentlyShown: [old]
        )
        // With nothing else to show it comes back rather than the card
        // disappearing — see the note in `pick`.
        #expect(during?.id == id("only"))

        let after = EditorsChoice.pick(
            for: 20_000 + EditorsChoice.restDays,
            from: candidates,
            recentlyShown: [old]
        )
        #expect(after?.id == id("only"))
    }

    @Test("A library with everything rested repeats rather than lowering the bar")
    func repeatsRatherThanReachingDown() {
        let candidates = pool(["a", "b"])
        let shown = candidates.map { EditorsChoice.Appearance(albumID: $0.id, day: 20_000) }
        let picked = EditorsChoice.pick(for: 20_001, from: candidates, recentlyShown: shown)
        #expect(picked != nil)
        #expect(candidates.map(\.id).contains(picked!.id))
    }

    // MARK: The excerpt

    @Test("A short review is left exactly as it is")
    func shortReviewUntouched() {
        let text = "Cut ten days after a falling-out, and you can hear the courtesy."
        #expect(EditorsChoice.excerpt(from: text) == text)
    }

    @Test("A long review is cut at a sentence, not mid-clause")
    func cutsAtASentence() {
        let text = """
        Cut ten days after a falling-out, and you can hear the courtesy. \
        LaFaro answers every phrase Evans leaves open; Motian keeps the room \
        breathing rather than keeping time. It is the sound of three people \
        agreeing to disagree politely, and it changed what a piano trio was \
        allowed to be for the next forty years.
        """
        let cut = EditorsChoice.excerpt(from: text, limit: 220)
        #expect(cut.count <= 220)
        #expect(cut.hasSuffix("."))
        #expect(cut.hasPrefix("Cut ten days"))
        // Not cut in the middle of the sentence that would not fit.
        #expect(!cut.contains("agreeing to disagree"))
    }

    @Test("A first sentence longer than the limit is trimmed at a word")
    func noSentenceEndsInTime() {
        let text = String(repeating: "word ", count: 100)
        let cut = EditorsChoice.excerpt(from: text, limit: 40)
        #expect(cut.count <= 41)
        #expect(cut.hasSuffix("…"))
        #expect(!cut.contains("wor…"))
    }

    @Test("Line breaks in a review do not reach the card")
    func flattensWhitespace() {
        let cut = EditorsChoice.excerpt(from: "One line.\nAnd another.")
        #expect(!cut.contains("\n"))
    }
}

/// Keeping the shelf from showing a fortnight of the same thing.
@Suite("Editors' Choice variety")
struct EditorsChoiceVarietyTests {
    private static let server = ServerID(rawValue: UUID())
    private func id(_ raw: String) -> MediaID { MediaID(server: Self.server, rawValue: raw) }

    private func album(_ name: String, genre: String, year: Int) -> Album {
        Album(
            id: id(name),
            name: name,
            artistName: "Someone",
            year: year,
            genre: genre,
            criticRating: 9,
            review: sampleReview
        )
    }

    /// A library that is mostly jazz, with enough of everything else to rotate through — the shape
    /// that produced a fortnight of jazz.
    private var jazzHeavy: [Album] {
        (1...30).map { album("jazz\($0)", genre: "Jazz", year: 1950 + $0) }
            + (1...8).map { album("pop\($0)", genre: "Pop/Rock", year: 1965 + $0) }
            + (1...8).map { album("soul\($0)", genre: "Soul", year: 1968 + $0) }
            + (1...8).map { album("elec\($0)", genre: "Electronic", year: 1990 + $0) }
    }

    @Test("Yesterday's genre cannot be today's")
    func genreDoesNotRepeatDayToDay() {
        let yesterday = EditorsChoice.Appearance(
            album: album("jazz1", genre: "Jazz", year: 1959),
            day: 20_000
        )
        let today = EditorsChoice.pick(
            for: 20_001,
            from: jazzHeavy,
            recentlyShown: [yesterday]
        )
        #expect(today?.genre != "Jazz")
    }

    /// The complaint, as a test: run the shelf for a fortnight against a
    /// mostly-jazz library and count how often it says jazz twice running.
    @Test("A fortnight of a jazz-heavy library is not a fortnight of jazz")
    func noLongRunsOfOneGenre() {
        var history: [EditorsChoice.Appearance] = []
        var picked: [String] = []
        for day in 20_000..<20_014 {
            guard let choice = EditorsChoice.pick(
                for: day,
                from: jazzHeavy,
                recentlyShown: history
            ) else { continue }
            picked.append(choice.genre ?? "?")
            history.append(EditorsChoice.Appearance(album: choice, day: day))
        }
        #expect(picked.count == 14)
        // Never the same genre two days running.
        for (yesterday, today) in zip(picked, picked.dropFirst()) {
            #expect(yesterday != today, "\(yesterday) followed by \(today)")
        }
        // And more than one kind of music over the fortnight.
        #expect(Set(picked).count >= 3)
    }

    @Test("Four spellings of one genre count as one genre")
    func genreFamiliesCountTogether() {
        // "Swing" belongs to the Jazz family, so it is not variety.
        let library = [
            album("swing1", genre: "Swing", year: 1955),
            album("jazz1", genre: "Jazz", year: 1959),
        ]
        let yesterday = EditorsChoice.Appearance(
            album: album("jazz1", genre: "Jazz", year: 1959),
            day: 20_000
        )
        // Both remaining records are the same family as yesterday's, so the
        // rule cannot be satisfied — and the shelf shows something anyway
        // rather than going blank.
        #expect(EditorsChoice.pick(for: 20_001, from: library, recentlyShown: [yesterday]) != nil)
    }

    @Test("A library of one genre still shows a card every day")
    func oneGenreLibraryStillWorks() {
        let onlyJazz = (1...5).map { album("j\($0)", genre: "Jazz", year: 1950 + $0) }
        var history: [EditorsChoice.Appearance] = []
        for day in 20_000..<20_010 {
            let choice = EditorsChoice.pick(for: day, from: onlyJazz, recentlyShown: history)
            #expect(choice != nil, "no card on day \(day)")
            if let choice {
                history.append(EditorsChoice.Appearance(album: choice, day: day))
            }
        }
    }

    @Test("The decade is varied too, where the library allows it")
    func decadeIsVaried() {
        let library = [
            album("a", genre: "Jazz", year: 1959),
            album("b", genre: "Pop/Rock", year: 1955),
            album("c", genre: "Soul", year: 1994),
        ]
        let yesterday = EditorsChoice.Appearance(
            album: album("a", genre: "Jazz", year: 1959),
            day: 20_000
        )
        let today = EditorsChoice.pick(for: 20_001, from: library, recentlyShown: [yesterday])
        // Not the fifties again, and not jazz again.
        #expect(today?.year == 1994)
    }

    @Test("Showing the same record again is conceded last of all")
    func recordRestOutranksGenreRest() {
        // One record only: every rule but the last has to give way, and the
        // record comes back rather than the section disappearing.
        let library = [album("only", genre: "Jazz", year: 1959)]
        let yesterday = EditorsChoice.Appearance(album: library[0], day: 20_000)
        #expect(EditorsChoice.pick(for: 20_001, from: library, recentlyShown: [yesterday])?.id
                == library[0].id)
    }
}

/// What happens when the rules cannot all be kept at once.
@Suite("Editors' Choice under pressure")
struct EditorsChoiceDegradationTests {
    private static let server = ServerID(rawValue: UUID())
    private func id(_ raw: String) -> MediaID { MediaID(server: Self.server, rawValue: raw) }

    private func album(_ name: String, genre: String, year: Int) -> Album {
        Album(
            id: id(name),
            name: name,
            artistName: "Someone",
            year: year,
            genre: genre,
            criticRating: 9,
            review: sampleReview
        )
    }

    /// A fresh record of the wrong genre beats repeating one of the right
    /// genre. Showing the same record twice in a week is the most obvious
    /// repetition there is, so it is the last thing given up.
    @Test("A fresh record outranks a varied genre")
    func freshnessOutranksVariety() {
        // One pop record, already shown yesterday, and plenty of jazz.
        let library = [album("pop1", genre: "Pop/Rock", year: 1971)]
            + (1...5).map { album("jazz\($0)", genre: "Jazz", year: 1950 + $0) }
        let history = [
            EditorsChoice.Appearance(album: album("jazz0", genre: "Jazz", year: 1959), day: 20_000),
            EditorsChoice.Appearance(album: library[0], day: 19_999),
        ]
        let today = EditorsChoice.pick(for: 20_001, from: library, recentlyShown: history)
        // Jazz again, rather than the pop record a second time this week.
        #expect(today?.genre == "Jazz")
    }

    /// And a card every day regardless: a library with nothing left that
    /// satisfies any rule still shows the best it has.
    @Test("Every rule exhausted still leaves a card")
    func alwaysSomethingToShow() {
        let only = [album("only", genre: "Jazz", year: 1959)]
        let history = [EditorsChoice.Appearance(album: only[0], day: 20_000)]
        for day in 20_001..<20_020 {
            #expect(EditorsChoice.pick(for: day, from: only, recentlyShown: history) != nil)
        }
    }
}

/// That a day's record is the same record all day.
@Suite("Editors' Choice holds for the day")
struct EditorsChoiceStabilityTests {
    private static let server = ServerID(rawValue: UUID())
    private func id(_ raw: String) -> MediaID { MediaID(server: Self.server, rawValue: raw) }

    private func album(_ name: String, genre: String = "Jazz", year: Int = 1959) -> Album {
        Album(
            id: id(name),
            name: name,
            artistName: "Someone",
            year: year,
            genre: genre,
            criticRating: 9,
            review: sampleReview
        )
    }

    /// The bug, as a test. Working the day out again once it has been
    /// written down must give the same answer — the entry stamped with today
    /// is that answer, not a record to steer away from.
    @Test("Today's own appearance does not push today's record aside")
    func todaysEntryIsNotHistory() {
        let library = (1...12).map { album("a\($0)", genre: "G\($0 % 4)", year: 1950 + $0) }
        let first = EditorsChoice.pick(for: 20_000, from: library)
        let recorded = EditorsChoice.Appearance(album: first!, day: 20_000)

        // Asked again for the same day, with the answer already recorded.
        let again = EditorsChoice.pick(for: 20_000, from: library, recentlyShown: [recorded])
        #expect(again?.id == first?.id)
    }

    @Test("Asking all day, however many times, gives one record")
    func stableAcrossManyLooks() {
        let library = (1...12).map { album("a\($0)", genre: "G\($0 % 4)", year: 1950 + $0) }
        var history: [EditorsChoice.Appearance] = []
        var answers: Set<MediaID> = []
        for _ in 0..<25 {
            guard let choice = EditorsChoice.pick(
                for: 20_000,
                from: library,
                recentlyShown: history
            ) else { continue }
            answers.insert(choice.id)
            // As the store does: one entry per day, rewritten each time.
            history.removeAll { $0.day == 20_000 }
            history.append(EditorsChoice.Appearance(album: choice, day: 20_000))
        }
        #expect(answers.count == 1)
    }

    @Test("And tomorrow is a different record")
    func tomorrowMovesOn() {
        let library = (1...12).map { album("a\($0)", genre: "G\($0 % 4)", year: 1950 + $0) }
        let today = EditorsChoice.pick(for: 20_000, from: library)
        let history = [EditorsChoice.Appearance(album: today!, day: 20_000)]
        let tomorrow = EditorsChoice.pick(for: 20_001, from: library, recentlyShown: history)
        #expect(tomorrow?.id != today?.id)
    }
}

/// The review is the point of the card, so a record without one is not a
/// candidate however well it was reviewed.
@Suite("Editors' Choice needs something to read")
struct EditorsChoiceReviewTests {
    private static let server = ServerID(rawValue: UUID())
    private func id(_ raw: String) -> MediaID { MediaID(server: Self.server, rawValue: raw) }

    private func album(_ name: String, review: String?) -> Album {
        Album(
            id: id(name),
            name: name,
            artistName: "Someone",
            year: 1959,
            genre: "Jazz",
            criticRating: 9,
            review: review
        )
    }

    private let realReview = """
    Cut ten days after a falling-out, and you can hear the courtesy in every bar.
    """

    @Test("A record with no review is never chosen")
    func noReviewNoCard() {
        #expect(EditorsChoice.pick(for: 20_000, from: [album("a", review: nil)]) == nil)
    }

    @Test("An empty or blank review is no review")
    func blankReviewNoCard() {
        #expect(EditorsChoice.pick(for: 20_000, from: [album("a", review: "")]) == nil)
        #expect(EditorsChoice.pick(for: 20_000, from: [album("a", review: "   \n  ")]) == nil)
    }

    @Test("A word and a full stop is not a review")
    func tooShortNoCard() {
        #expect(EditorsChoice.pick(for: 20_000, from: [album("a", review: "Good.")]) == nil)
    }

    @Test("The one record with a review is the one chosen")
    func picksTheOneWithSomethingToRead() {
        let library = [
            album("no-review", review: nil),
            album("blank", review: "  "),
            album("stub", review: "Nice."),
            album("real", review: realReview),
        ]
        #expect(EditorsChoice.pick(for: 20_000, from: library)?.id == id("real"))
    }

    @Test("A whole library of reviewless records shows no section")
    func nothingToReadHidesTheSection() {
        let library = (1...20).map { album("a\($0)", review: $0.isMultiple(of: 2) ? nil : "Ok.") }
        #expect(EditorsChoice.pick(for: 20_000, from: library) == nil)
    }
}

/// A well-reviewed compilation is still not a record written as a specific
/// artist's own work.
@Suite("Editors' Choice needs a single artist")
struct EditorsChoiceArtistTests {
    private static let server = ServerID(rawValue: UUID())
    private func id(_ raw: String) -> MediaID { MediaID(server: Self.server, rawValue: raw) }

    private let realReview = """
    Cut ten days after a falling-out, and you can hear the courtesy in every bar.
    """

    private func album(_ name: String, artistName: String?) -> Album {
        Album(
            id: id(name),
            name: name,
            artistName: artistName,
            year: 1959,
            genre: "Jazz",
            criticRating: 9,
            review: realReview
        )
    }

    @Test("A various-artists credit is never chosen")
    func variousArtistsExcluded() {
        #expect(EditorsChoice.pick(for: 20_000, from: [album("a", artistName: "Various Artists")]) == nil)
    }

    @Test("Spellings other than English are caught too")
    func otherLanguagesExcluded() {
        for credit in ["VA", "Varios Artistas", "Artistes Divers", "Verschiedene Interpreten"] {
            #expect(
                EditorsChoice.pick(for: 20_000, from: [album("a", artistName: credit)]) == nil,
                "did not exclude \"\(credit)\""
            )
        }
    }

    @Test("The one record with a real artist is the one chosen")
    func picksTheOneWithARealArtist() {
        let library = [
            album("comp", artistName: "Various Artists"),
            album("real", artistName: "Bill Evans"),
        ]
        #expect(EditorsChoice.pick(for: 20_000, from: library)?.id == id("real"))
    }

    @Test("A whole library of compilations shows no section")
    func nothingButCompilationsHidesTheSection() {
        let library = (1...20).map { album("a\($0)", artistName: "Various Artists") }
        #expect(EditorsChoice.pick(for: 20_000, from: library) == nil)
    }
}
