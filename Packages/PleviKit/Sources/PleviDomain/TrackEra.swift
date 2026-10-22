import Foundation

/// When a song was *made*, as opposed to when the copy in the library was published.
public enum TrackEra {
    /// Which signal actually decided, so a wrong answer can be traced back
    /// to the thing that gave it.
    public enum Source: String, Sendable, Hashable {
        /// The song's own original-date tag — the best answer there is,
        /// because it is per-song and cannot be wrong about a compilation.
        case trackTag = "track-tag"
        /// The record's original release date, where that is genuinely
        /// different from the year it was published under.
        case albumOriginalDate = "album-original-date"
        /// The middle year of everything else this artist has in the
        /// library — a guess, used only when a compilation has left us
        /// nothing better.
        case artistEstimate = "artist-estimate"
        /// The record's own year, which for anything that is not a
        /// compilation is very nearly always right.
        case albumYear = "album-year"
    }

    /// What a backend was able to find out about one song.
    public struct Signals: Sendable, Hashable {
        /// The song's own original year, where the server tags songs
        /// individually. Navidrome can surface `ORIGINALDATE`; Plex sends
        /// `originallyAvailableAt` on some track rows.
        public var trackOriginalYear: Int?
        /// The year on the record's original release date — `originalReleaseDate` on Navidrome,
        /// `originallyAvailableAt` on Plex.
        public var albumOriginalYear: Int?
        /// The year the record is filed under.
        public var albumYear: Int?
        /// The song's own year tag, where it has one distinct from the
        /// record's.
        public var trackYear: Int?
        public var isCompilation: Bool
        /// The middle year of this artist's own records elsewhere in the
        /// library, for when the record itself cannot be trusted.
        public var artistEstimate: Int?

        public init(
            trackOriginalYear: Int? = nil,
            albumOriginalYear: Int? = nil,
            albumYear: Int? = nil,
            trackYear: Int? = nil,
            isCompilation: Bool = false,
            artistEstimate: Int? = nil
        ) {
            self.trackOriginalYear = trackOriginalYear
            self.albumOriginalYear = albumOriginalYear
            self.albumYear = albumYear
            self.trackYear = trackYear
            self.isCompilation = isCompilation
            self.artistEstimate = artistEstimate
        }
    }

    /// What was decided, and on what grounds.
    public struct Classification: Sendable, Hashable {
        /// `nil` when nothing could be established — which for a decade
        /// radio means the song is left out rather than guessed at.
        public let year: Int?
        public let source: Source?
        /// Set when the answer is a fallback standing in for a signal that should have existed: a
        /// compilation whose artist has no other record here, left with the pressing year and
        /// nothing to check it against.
        public let isLowConfidence: Bool

        public var decade: Int? {
            guard let year else { return nil }
            return (year / 10) * 10
        }
    }

    /// How far an original date has to sit from the filed year before it is worth believing.
    private static let reissueGapYears = 0

    /// Whether a song's "own" original year is really its record's, copied onto it.
    private static func isEchoedPressing(_ year: Int, _ signals: Signals) -> Bool {
        signals.isCompilation && signals.albumYear == year
    }

    /// The precedence, in one place.
    public static func resolve(_ signals: Signals) -> Classification {
        if let year = signals.trackOriginalYear, !isEchoedPressing(year, signals) {
            return Classification(year: year, source: .trackTag, isLowConfidence: false)
        }

        if let original = signals.albumOriginalYear {
            if let filed = signals.albumYear {
                if abs(original - filed) > reissueGapYears {
                    return Classification(
                        year: original,
                        source: .albumOriginalDate,
                        isLowConfidence: false
                    )
                }
            } else if !signals.isCompilation {
                // Nothing filed to compare it against.
                return Classification(
                    year: original,
                    source: .albumOriginalDate,
                    isLowConfidence: false
                )
            }
        }

        if signals.isCompilation {
            if let estimate = signals.artistEstimate {
                return Classification(
                    year: estimate,
                    source: .artistEstimate,
                    isLowConfidence: false
                )
            }
            // Nothing else by this artist here to measure against.
            guard let filed = signals.albumYear ?? signals.trackYear else {
                return Classification(year: nil, source: nil, isLowConfidence: true)
            }
            return Classification(year: filed, source: .albumYear, isLowConfidence: true)
        }

        // A song's own year first: on a normal album the two agree, and
        // where they do not it is usually the song that is right.
        guard let year = signals.trackYear ?? signals.albumYear else {
            return Classification(year: nil, source: nil, isLowConfidence: false)
        }
        return Classification(year: year, source: .albumYear, isLowConfidence: false)
    }
}

extension TrackEra.Signals {
    /// Assembled from a single already-fetched track and its album — for resolving one anchor
    /// track's era on demand (a DJ activating, anchored on whatever is currently playing), as
    /// opposed to `LibraryIndex`'s own `settledEraSQL`/`decadeTracks`…
    public init(track: Track, album: Album?, artistEstimate: Int?) {
        let isCompilation = CompilationHeuristics.isCompilation(
            serverFlag: album?.isCompilation ?? false,
            releaseTypes: album?.releaseTypes ?? [],
            albumTitle: album?.name,
            albumArtist: album?.artistName
        )
        self.init(
            trackOriginalYear: track.originalYear,
            albumOriginalYear: album?.releaseDate.map { Self.utcYear(of: $0) },
            albumYear: album?.year,
            trackYear: track.year,
            isCompilation: isCompilation,
            artistEstimate: artistEstimate
        )
    }

    /// The year component in UTC — matching `strftime('%Y', album.releaseDate)`, which
    /// `settledEraSQL` uses and which SQLite always reads as UTC.
    private static func utcYear(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.year, from: date)
    }
}
