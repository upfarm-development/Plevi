import Foundation
import Testing
@testable import PleviDomain

@Suite("Most listened to a month that has had time to be judged")
struct MostListenedTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int = 1, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    @Test("Four months back names the month, not the one just gone")
    func targetMonthIsFourBack() {
        let month = MostListened.targetMonth(from: date(2026, 8, 30), calendar: calendar)
        #expect(month.start == date(2026, 4, 1, hour: 0))
        #expect(month.end == date(2026, 5, 1, hour: 0))
    }

    @Test("The target month crosses a year boundary correctly")
    func targetMonthCrossesYearBoundary() {
        let month = MostListened.targetMonth(from: date(2026, 2, 15), calendar: calendar)
        #expect(month.start == date(2025, 10, 1, hour: 0))
        #expect(month.end == date(2025, 11, 1, hour: 0))
    }

    @Test("The month's own name is used")
    func monthNameIsReadable() {
        let month = MostListened.targetMonth(from: date(2026, 8, 30), calendar: calendar)
        let name = MostListened.monthName(for: month, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(name == "April")
    }

    @Test("Albums are ranked by total playtime within the month, not by play count")
    func ranksByTotalPlaytime() {
        let month = DateInterval(start: date(2026, 4, 1, hour: 0), end: date(2026, 5, 1, hour: 0))
        let entries = [
            // Album A: one long play.
            PlayHistoryEntry(trackID: id("a1"), albumID: id("album-a"), playedAt: date(2026, 4, 5)),
            // Album B: three short plays that add up to less than A's one.
            PlayHistoryEntry(trackID: id("b1"), albumID: id("album-b"), playedAt: date(2026, 4, 6)),
            PlayHistoryEntry(trackID: id("b1"), albumID: id("album-b"), playedAt: date(2026, 4, 10)),
            PlayHistoryEntry(trackID: id("b1"), albumID: id("album-b"), playedAt: date(2026, 4, 20)),
        ]
        let durations: [MediaID: TimeInterval] = [id("a1"): 3000, id("b1"): 200]
        let ranked = MostListened.rank(entries, durations: durations, within: month)
        #expect(ranked.map(\.albumID) == [id("album-a"), id("album-b")])
        #expect(ranked[0].totalSeconds == 3000)
        #expect(ranked[1].totalSeconds == 600)
    }

    @Test("A play outside the month does not count toward it")
    func excludesPlaysOutsideTheMonth() {
        let month = DateInterval(start: date(2026, 4, 1, hour: 0), end: date(2026, 5, 1, hour: 0))
        let entries = [
            PlayHistoryEntry(trackID: id("t1"), albumID: id("album-a"), playedAt: date(2026, 3, 31, hour: 23)),
            PlayHistoryEntry(trackID: id("t2"), albumID: id("album-a"), playedAt: date(2026, 5, 1, hour: 0)),
        ]
        let durations: [MediaID: TimeInterval] = [id("t1"): 200, id("t2"): 200]
        #expect(MostListened.rank(entries, durations: durations, within: month).isEmpty)
    }

    @Test("A play with no known duration is left out rather than counted as zero")
    func excludesPlaysWithNoKnownDuration() {
        let month = DateInterval(start: date(2026, 4, 1, hour: 0), end: date(2026, 5, 1, hour: 0))
        let entries = [
            PlayHistoryEntry(trackID: id("t1"), albumID: id("album-a"), playedAt: date(2026, 4, 5)),
        ]
        #expect(MostListened.rank(entries, durations: [:], within: month).isEmpty)
    }

    @Test("A play with no album to credit does not surface an album from nowhere")
    func excludesPlaysWithNoAlbum() {
        let month = DateInterval(start: date(2026, 4, 1, hour: 0), end: date(2026, 5, 1, hour: 0))
        let entries = [
            PlayHistoryEntry(trackID: id("t1"), albumID: nil, playedAt: date(2026, 4, 5)),
        ]
        let durations: [MediaID: TimeInterval] = [id("t1"): 200]
        #expect(MostListened.rank(entries, durations: durations, within: month).isEmpty)
    }

    @Test("Only the top few albums are kept")
    func limitsToAlbumCount() {
        let month = DateInterval(start: date(2026, 4, 1, hour: 0), end: date(2026, 5, 1, hour: 0))
        var entries: [PlayHistoryEntry] = []
        var durations: [MediaID: TimeInterval] = [:]
        for index in 0..<8 {
            let track = id("t\(index)")
            entries.append(PlayHistoryEntry(trackID: track, albumID: id("album-\(index)"), playedAt: date(2026, 4, 5)))
            durations[track] = TimeInterval(8 - index) * 100
        }
        let ranked = MostListened.rank(entries, durations: durations, within: month, limit: 5)
        #expect(ranked.count == 5)
        #expect(ranked.map(\.albumID) == (0..<5).map { id("album-\($0)") })
    }
}
