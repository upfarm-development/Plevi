import Foundation

/// A Home section giving one artist a whole week — long enough to actually
/// work through the five albums it puts up, which is what `EditorsChoice`'s
/// own one-day card never had room to be about more than in passing.
public enum Spotlight {
    /// The fewest of an artist's own albums that need a usable rating before
    /// their work says anything about them as a whole, rather than about one
    /// good record.
    public static let minimumRatedAlbums = 3
    /// Out of ten — the bar the mean of an artist's own top five has to
    /// clear on Plex's critic scale.
    public static let minimumMeanCriticRating = 8.0
    /// Out of five — the same bar on a listener's own stars, where a server
    /// has no critic score to ask instead.
    public static let minimumMeanStarRating = 4.0
    /// How many weeks an artist rests before being eligible again. A year: an
    /// artist who has had the whole front of the app for a week should not
    /// come round again while it is still remembered.
    public static let restWeeks = 52

    /// How steeply each earlier feature counts against an artist once the rest is over: the weight
    /// is `1 / (1 + features) ^ repeatPenaltyPower`.
    static let repeatPenaltyPower = 4.0

    /// One artist's own case for the spotlight — already narrowed to their own albums with a usable
    /// rating, best first, capped at five.
    public struct Candidate: Hashable, Sendable {
        public let artistName: String
        public let topAlbums: [Album]

        public init(artistName: String, topAlbums: [Album]) {
            self.artistName = artistName
            self.topAlbums = topAlbums
        }

        /// The mean of whatever `score` finds here — however many of the up to five albums actually
        /// carry a value under it, since the two rating scales live on different columns and a
        /// candidate built for one is not guaranteed to have anything under…
        func meanRating(_ score: (Album) -> Double?) -> Double? {
            let scores = topAlbums.compactMap(score)
            guard !scores.isEmpty else { return nil }
            return scores.reduce(0, +) / Double(scores.count)
        }
    }

    /// An artist shown in a given week, kept so the same one does not come
    /// round again too soon.
    public struct Appearance: Hashable, Sendable, Codable {
        /// Lowercased, matching how `Candidate.artistName` and
        /// `topRatedAlbumsByArtist`'s own keys are compared throughout.
        public let artistName: String
        public let week: Int

        public init(artistName: String, week: Int) {
            self.artistName = artistName.lowercased()
            self.week = week
        }
    }

    /// The ISO week a date falls in, as one sortable number — `202605` for the fifth week of 2026,
    /// never colliding with week 5 of any other year the way a bare week number would.
    public static func weekNumber(for date: Date, calendar: Calendar = .current) -> Int {
        var iso = calendar
        iso.minimumDaysInFirstWeek = 4
        iso.firstWeekday = 2
        let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return (parts.yearForWeekOfYear ?? 0) * 100 + (parts.weekOfYear ?? 0)
    }

    /// The Monday a week number names, for an Archive screen to date its
    /// rows by — the inverse of `weekNumber(for:)`, on the same ISO
    /// definition.
    public static func date(forWeek week: Int, calendar: Calendar = .current) -> Date? {
        var iso = calendar
        iso.minimumDaysInFirstWeek = 4
        iso.firstWeekday = 2
        return iso.date(from: DateComponents(
            weekday: 2, weekOfYear: week % 100, yearForWeekOfYear: week / 100
        ))
    }

    /// How many real weeks apart two `weekNumber(for:)` values are.
    public static func weeksElapsed(from earlier: Int, to later: Int, calendar: Calendar = .current) -> Int {
        guard let earlierDate = date(forWeek: earlier, calendar: calendar),
              let laterDate = date(forWeek: later, calendar: calendar)
        else { return later - earlier }
        let days = calendar.dateComponents([.day], from: earlierDate, to: laterDate).day ?? 0
        return days / 7
    }

    /// This week's artist, or nothing.
    public static func pick(
        for week: Int,
        from candidates: [Candidate],
        usingCriticRating: Bool,
        recentlyShown: [Appearance] = []
    ) -> Candidate? {
        let threshold = usingCriticRating ? minimumMeanCriticRating : minimumMeanStarRating
        let score: (Album) -> Double? = usingCriticRating
            ? { $0.criticRating }
            : { $0.rating?.value }

        let eligible = candidates.filter { candidate in
            candidate.topAlbums.count >= minimumRatedAlbums
                && (candidate.meanRating(score) ?? -1) >= threshold
        }
        guard !eligible.isEmpty else { return nil }

        // Strictly *before* this week — see `EditorsChoice.pick`'s own identical reasoning: an
        // appearance stamped with the current week is this very answer, already settled, not
        // history to steer away from.
        let recent = recentlyShown.filter { $0.week < week }
        let resting = Set(recent.filter { weeksElapsed(from: $0.week, to: week) < restWeeks }.map(\.artistName))
        // How often each has been featured at all, however long ago — the
        // part of the history that lasts beyond the rest.
        var features: [String: Int] = [:]
        for appearance in recent { features[appearance.artistName, default: 0] += 1 }

        // Rested artists first; if that empties the pool — a library with fewer than `restWeeks`
        // worth of eligible artists — the rest is ignored rather than the bar being lowered, the
        // same trade `EditorsChoice`'s own last tier makes.
        let pool = eligible.filter { !resting.contains($0.artistName.lowercased()) }
        let final = pool.isEmpty ? eligible : pool

        // A stable order for the draw to be deterministic over — candidates
        // arrive keyed from a Dictionary, whose own order is not guaranteed
        // the same twice.
        let ordered = final.sorted { $0.artistName.lowercased() < $1.artistName.lowercased() }

        // A weighted draw, not a uniform one: whoever has been featured
        // least is the most likely, so repeats only become likely once
        // everyone else has had about as many turns.
        let weights = ordered.map { candidate -> Double in
            let count = features[candidate.artistName.lowercased(), default: 0]
            return 1 / pow(1 + Double(count), repeatPenaltyPower)
        }
        let target = unitInterval(for: week) * weights.reduce(0, +)
        var running = 0.0
        for (index, weight) in weights.enumerated() {
            running += weight
            if target < running { return ordered[index] }
        }
        return ordered[ordered.count - 1]
    }

    /// A number in `[0, 1)` fixed by the week alone: FNV-1a over the week's digits and a salt, so
    /// it is the same on every launch and device and not the same number the daily Editors' Choice
    /// draws from the same digits.
    static func unitInterval(for week: Int) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "spotlight|\(week)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        // FNV-1a on its own leaves consecutive weeks, which differ only in
        // their last digits, close together in the high bits — a draw made
        // from them clustered. A finishing mix (splitmix64) spreads them.
        var mixed = hash &+ 0x9e37_79b9_7f4a_7c15
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        mixed ^= mixed >> 31
        // The top 53 bits, which is what a Double can hold exactly.
        return Double(mixed >> 11) / Double(1 << 53)
    }
}
