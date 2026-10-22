import Foundation

/// Mixes worked out from what someone has actually been listening to.
public enum MadeForYou {
    /// How many mixes `mixes(from:shape:limit:)` offers when nobody says.
    public static let mixCount = 5

    /// How many mixes the shelf carries once it has been running a while.
    public static let carouselSize = 14

    /// How often a new mix joins the front of the shelf.
    public static let rotationDays = 1

    /// How many of an artist's songs are kept to seed from.
    public static let seedsPerMix = 9

    /// The fewest plays an artist needs before they are worth a mix.
    public static let minimumPlays = 2

    /// The fewest songs a mix may have behind it.
    ///
    /// Below this it is not a mix, it is a short playlist that repeats.
    public static let minimumDepth = 120

    /// The most of the library a mix may be.
    public static let maximumShare = 0.20

    /// How much a genre needs before it is worth cutting into decades.
    public static let decadesNeedGenreOf = minimumDepth * 12

    /// How many of each kind may be on the shelf at once, so one kind of card
    /// cannot take the whole thing.
    public static let artistsAtMost = 3
    public static let tagsAtMost = 3

    /// A mix, as chosen. What it holds is not decided until it is played.
    public struct Mix: Hashable, Sendable, Codable, Identifiable {
        public enum Kind: Hashable, Sendable, Codable {
            /// Songs the server says sound like this artist, blended from
            /// several of their own.
            case artist(name: String, artistID: MediaID?, seeds: [MediaID])
            /// Everything the library has of a genre, and of one decade of it where the genre is
            /// big enough to be worth cutting up.
            case tag(genre: String, decade: Int?, members: [String])
        }

        public var kind: Kind
        /// The sleeve to draw it with.
        public var artwork: ArtworkID?
        /// Several sleeves, for a mix that is not about one record.
        public var artworks: [ArtworkID] = []
        /// Who the mix is mostly made of, biggest first.
        public var artists: [String] = []

        public init(
            kind: Kind,
            artwork: ArtworkID? = nil,
            artworks: [ArtworkID] = [],
            artists: [String] = []
        ) {
            self.kind = kind
            self.artwork = artwork
            self.artworks = artworks
            self.artists = artists
        }

        public var id: String {
            switch kind {
            case .artist(let name, _, _): "artist:\(name.lowercased())"
            case .tag(let genre, let decade, _):
                "tag:\(genre.lowercased()):\(decade.map(String.init) ?? "all")"
            }
        }

        public var title: String {
            switch kind {
            case .artist(let name, _, _): name
            case .tag(let genre, let decade, _):
                decade.map { "\($0)s \(genre)" } ?? genre
            }
        }

        public var subtitle: String {
            guard artists.isEmpty else {
                return ListFormatter.plain(artists)
            }
            return switch kind {
            case .artist: "and songs like them"
            case .tag: "from your library"
            }
        }

        public var isArtist: Bool {
            if case .artist = kind { return true }
            return false
        }
    }

    /// The mixes to offer, from the songs most recently played.
    public static func mixes(
        from history: [Track],
        shape: LibraryShape = LibraryShape(),
        limit: Int = mixCount
    ) -> [Mix] {
        guard limit > 0 else { return [] }
        let artists = artistMixes(from: history).prefix(artistsAtMost)
        let tags = tagMixes(from: history, shape: shape).prefix(tagsAtMost)
        // Artists first: they are the more personal of the two, and a shelf
        // that opens with a name you recognise reads as yours.
        return Array((artists + tags).prefix(limit))
    }

    /// Everything the listening could justify a mix about, best first.
    public static func candidates(
        from history: [Track],
        shape: LibraryShape = LibraryShape(),
        limit: Int = carouselSize * 4
    ) -> [Mix] {
        guard limit > 0 else { return [] }
        var artists = artistMixes(from: history)[...]
        var tags = tagMixes(from: history, shape: shape)[...]
        var out: [Mix] = []
        // Artists lead, for the reason they lead the weekly shelf: a name you
        // recognise reads as yours in a way a genre does not.
        while out.count < limit, !artists.isEmpty || !tags.isEmpty {
            if let next = artists.popFirst() { out.append(next) }
            guard out.count < limit else { break }
            if let next = tags.popFirst() { out.append(next) }
        }
        return out
    }

    /// A shelf as it was left, and which rotation it was brought up to.
    public struct Shelf: Hashable, Sendable, Codable {
        public var mixes: [Mix]
        public var period: Int
        /// The ids of artist mixes whose line of names is still the local guess because the server
        /// could not be asked when they arrived — no connection yet on a cold launch, Offline Mode,
        /// a request that failed.
        public var awaitingSonic: [String]

        public init(mixes: [Mix], period: Int, awaitingSonic: [String] = []) {
            self.mixes = mixes
            self.period = period
            self.awaitingSonic = awaitingSonic
        }

        private enum CodingKeys: String, CodingKey { case mixes, period, awaitingSonic }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mixes = try container.decode([Mix].self, forKey: .mixes)
            period = try container.decode(Int.self, forKey: .period)
            awaitingSonic = try container.decodeIfPresent([String].self, forKey: .awaitingSonic) ?? []
        }
    }

    /// The mixes whose names are still owed to the server: those that have
    /// just arrived, and those a previous refresh could not finish. Only ids
    /// still on the shelf.
    public static func sonicTargets(assembly: Assembly, stored: Shelf?) -> Set<String> {
        let present = Set(assembly.mixes.map(\.id))
        return assembly.newlyArrived.union(stored?.awaitingSonic ?? []).intersection(present)
    }

    /// What a refresh should do.
    public struct Assembly: Hashable, Sendable {
        /// The shelf to show.
        public let mixes: [Mix]
        /// The ids of the mixes that have never been dressed — the ones whose sleeves and artist
        /// names still have to be looked up.
        public let newlyArrived: Set<String>

        public init(mixes: [Mix], newlyArrived: Set<String>) {
            self.mixes = mixes
            self.newlyArrived = newlyArrived
        }
    }

    /// Whether the stored shelf is already the one this rotation should show.
    public static func isUpToDate(_ stored: Shelf?, at period: Int) -> Bool {
        guard let stored else { return false }
        return stored.period >= period && !stored.mixes.isEmpty
    }

    /// The shelf after however many rotations have gone by, and what on it
    /// still needs looking up.
    public static func assemble(
        stored: Shelf?,
        candidates: [Mix],
        at period: Int,
        size: Int = carouselSize
    ) -> Assembly {
        // Bounded by the shelf's own length: a phone left in a drawer for a
        // month owes ten new mixes at most, because an eleventh would push
        // the first of them straight back off again.
        let owed = stored.map { min(max(period - $0.period, 0), size) } ?? 0
        let shelf = rotate(
            existing: stored?.mixes ?? [],
            candidates: candidates,
            adding: owed,
            size: size
        )
        let already = Set(stored?.mixes.map(\.id) ?? [])
        return Assembly(
            mixes: shelf,
            newlyArrived: Set(shelf.map(\.id)).subtracting(already)
        )
    }

    /// The shelf as it stands after a rotation.
    public static func rotate(
        existing: [Mix],
        candidates: [Mix],
        adding count: Int = 1,
        size: Int = carouselSize
    ) -> [Mix] {
        guard size > 0 else { return [] }
        // Nothing to shift yet: fill the shelf in one go rather than making
        // somebody wait a fortnight to see ten.
        guard !existing.isEmpty else { return Array(candidates.prefix(size)) }
        guard count > 0 else { return Array(existing.prefix(size)) }

        let seen = Set(existing.map(\.id))
        let arrivals = candidates.filter { !seen.contains($0.id) }.prefix(count)
        guard !arrivals.isEmpty else { return Array(existing.prefix(size)) }

        // Newest at the very front: the last of the arrivals is the one that
        // belongs to the rotation just gone.
        return Array((arrivals.reversed() + existing).prefix(size))
    }

    private static func artistMixes(from history: [Track]) -> [Mix] {
        var score: [String: Double] = [:]
        var plays: [String: Int] = [:]
        var seeds: [String: [MediaID]] = [:]
        var display: [String: String] = [:]
        var artistID: [String: MediaID] = [:]
        var artwork: [String: ArtworkID] = [:]

        for (position, track) in history.enumerated() {
            guard let name = track.artistName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { continue }
            let key = name.lowercased()

            score[key, default: 0] += weight(at: position)
            plays[key, default: 0] += 1
            display[key] = display[key] ?? name
            if artistID[key] == nil, let id = track.artistID { artistID[key] = id }
            if artwork[key] == nil, let art = track.artwork { artwork[key] = art }

            // Newest first, and never the same song twice: a mix seeded from
            // one song on Monday and the same song on Tuesday is the same
            // mix twice.
            if seeds[key, default: []].count < seedsPerMix,
               !seeds[key, default: []].contains(track.id) {
                seeds[key, default: []].append(track.id)
            }
        }

        return ranked(score, above: minimumPlays, by: plays).compactMap { key in
            guard let name = display[key], let songs = seeds[key], !songs.isEmpty else { return nil }
            return Mix(
                kind: .artist(name: name, artistID: artistID[key], seeds: songs),
                artwork: artwork[key]
            )
        }
    }

    /// Genre and decade mixes, from the genres the listening keeps returning to — and only where
    /// the library can actually fill one.
    private static func tagMixes(from history: [Track], shape: LibraryShape) -> [Mix] {
        var genreScore: [String: Double] = [:]
        var genrePlays: [String: Int] = [:]
        var comboScore: [String: Double] = [:]
        var comboPlays: [String: Int] = [:]
        var comboParts: [String: (genre: String, decade: Int)] = [:]

        for (position, track) in history.enumerated() {
            guard let raw = track.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { continue }
            // The family the library files it under, so four spellings of one
            // genre count as one genre rather than four too small to offer.
            let genre = shape.family(matching: raw)?.name ?? GenreFamily.canonical(raw)

            genreScore[genre, default: 0] += weight(at: position)
            genrePlays[genre, default: 0] += 1

            guard let year = track.year else { continue }
            let decade = (year / 10) * 10
            let key = LibraryShape.key(genre: genre, decade: decade)
            comboScore[key, default: 0] += weight(at: position)
            comboPlays[key, default: 0] += 1
            comboParts[key] = (genre, decade)
        }

        var mixes: [Mix] = []
        var spoken: Set<String> = []

        // The decade mixes first, where the library will carry them.
        for key in ranked(comboScore, above: minimumPlays, by: comboPlays) {
            guard let (genre, decade) = comboParts[key],
                  let family = shape.family(named: genre),
                  family.songs > decadesNeedGenreOf,
                  isWorthOffering(genre: genre, decade: decade, shape: shape),
                  !spoken.contains(genre)
            else { continue }
            spoken.insert(genre)
            mixes.append(Mix(kind: .tag(genre: genre, decade: decade, members: family.members)))
        }

        // Then whole genres, for the ones not already spoken for.
        for genre in ranked(genreScore, above: minimumPlays, by: genrePlays) {
            guard !spoken.contains(genre),
                  let family = shape.family(named: genre),
                  isWorthOffering(genre: genre, decade: nil, shape: shape)
            else { continue }
            spoken.insert(genre)
            mixes.append(Mix(kind: .tag(genre: genre, decade: nil, members: family.members)))
        }

        return mixes
    }

    /// Big enough to be a mix, small enough to still be one.
    private static func isWorthOffering(
        genre: String,
        decade: Int?,
        shape: LibraryShape
    ) -> Bool {
        shape.depth(genre: genre, decade: decade) >= minimumDepth
            && shape.share(genre: genre, decade: decade) <= maximumShare
    }

    /// How much a play counts for, by how far back it is.
    private static func weight(at position: Int) -> Double {
        pow(0.5, Double(position) / 100)
    }

    /// Scores in order, dropping anything played too few times to be a taste
    /// rather than a try. Ties break by name, so the same listening always
    /// gives the same shelf.
    private static func ranked(
        _ score: [String: Double],
        above floor: Int,
        by plays: [String: Int]
    ) -> [String] {
        score
            .filter { plays[$0.key, default: 0] >= floor }
            .sorted { first, second in
                if first.value != second.value { return first.value > second.value }
                return first.key < second.key
            }
            .map(\.key)
    }

    /// Which of a mix's songs start it today.
    public static func seeds(for mix: Mix, dayOfYear: Int, count: Int = 3) -> [MediaID] {
        guard case .artist(_, _, let songs) = mix.kind, !songs.isEmpty, count > 0 else { return [] }
        let start = ((dayOfYear % songs.count) + songs.count) % songs.count
        return (0..<min(count, songs.count)).map { offset in
            songs[(start + offset) % songs.count]
        }
    }

    /// Which day this is, counted from a fixed point.
    public static func dayNumber(for date: Date, calendar: Calendar = .current) -> Int {
        // The local calendar date, counted as if it were a UTC date.
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let civil = utc.date(from: DateComponents(
            year: parts.year, month: parts.month, day: parts.day, hour: 12
        )) ?? calendar.startOfDay(for: date)
        return Int((civil.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Which rotation of the shelf a date belongs to — one a day.
    public static func rotationPeriod(for date: Date, calendar: Calendar = .current) -> Int {
        Int((Double(dayNumber(for: date, calendar: calendar)) / Double(rotationDays)).rounded(.down))
    }

    /// The day of the year, for walking the seeds along.
    public static func dayOfYear(for date: Date, calendar: Calendar = .current) -> Int {
        calendar.ordinality(of: .day, in: .year, for: date) ?? 0
    }
}


enum ListFormatter {
    /// "Kenny G, Oscar Peterson and Bill Evans" — names separated the way a
    /// person writes them, because this is read as a sentence fragment
    /// rather than scanned as a list.
    static func plain(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
