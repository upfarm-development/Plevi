import Foundation

/// A Home shelf naming the month that has had time to actually be judged —
/// not the one just gone, which is still being lived in and would read as
/// "most listened to" on the strength of two weeks.
public enum MostListened {
    /// How many months back the shown month sits.
    public static let monthsAgo = 4

    /// How many albums the shelf shows.
    public static let albumCount = 5

    /// The month this shelf names today, as the half-open interval its
    /// plays have to fall inside.
    public static func targetMonth(from now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let startOfThisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let start = calendar.date(byAdding: .month, value: -monthsAgo, to: startOfThisMonth) ?? startOfThisMonth
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// "April" — the month's own name, for the shelf's title.
    public static func monthName(
        for month: DateInterval, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: month.start)
    }

    /// The albums a month of history actually was, biggest total first.
    public static func rank(
        _ entries: [PlayHistoryEntry],
        durations: [MediaID: TimeInterval],
        within month: DateInterval,
        limit: Int = albumCount
    ) -> [(albumID: MediaID, totalSeconds: TimeInterval)] {
        var totals: [MediaID: TimeInterval] = [:]
        for entry in entries {
            // Half-open, deliberately not `month.contains(_:)` — Foundation's own `DateInterval`
            // treats both ends as inclusive, which would let a play at the first instant of the
            // *next* month count toward this one too.
            guard let albumID = entry.albumID,
                  entry.playedAt >= month.start, entry.playedAt < month.end
            else { continue }
            guard let duration = durations[entry.trackID], duration > 0 else { continue }
            totals[albumID, default: 0] += duration
        }
        return totals
            .sorted { first, second in
                if first.value != second.value { return first.value > second.value }
                return first.key.rawValue < second.key.rawValue
            }
            .prefix(limit)
            .map { (albumID: $0.key, totalSeconds: $0.value) }
    }
}
