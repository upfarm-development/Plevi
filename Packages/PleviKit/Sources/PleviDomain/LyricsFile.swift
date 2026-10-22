import Foundation

/// Reads a lyric file into `Lyrics`.
public enum LyricsFile {
    /// `nil` when there is nothing in the file worth showing — which includes
    /// a file of nothing but LRC metadata tags, since a screen of `[ar:…]` is
    /// worse than saying there are no lyrics.
    public static func parse(_ text: String) -> Lyrics? {
        var offset: TimeInterval = 0
        var language: String?
        var timed: [Lyrics.Line] = []
        var plain: [String] = []

        // By newline-ness, not by "\n".
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                // Kept, so the verses of an unsynced sheet stay apart. Synced
                // lyrics have no use for them — the timing does that job.
                plain.append("")
                continue
            }

            let (tags, remainder) = leadingTags(of: line)
            guard !tags.isEmpty else {
                plain.append(line)
                continue
            }

            var stamps: [TimeInterval] = []
            /// Whether the brackets were anything the format defines. Without
            /// this a line that is nothing but `[ar:…]` — every line at the
            /// head of an LRC file — was read as words and put on screen.
            var recognised = false
            for tag in tags {
                if let stamp = timestamp(tag) {
                    stamps.append(stamp)
                    recognised = true
                } else if let (key, value) = metadata(tag) {
                    recognised = true
                    switch key {
                    // Milliseconds, applied to every line. Taken as written —
                    // added to each start — which is what `Lyrics.offset`
                    // means and what the Subsonic mapping already does.
                    case "offset": offset = (Double(value) ?? 0) / 1000
                    case "la", "lang": language = value
                    default: break
                    }
                }
            }

            if stamps.isEmpty {
                if !recognised {
                    // Bracketed but not a stamp and not a tag we know — the
                    // line is words that happen to start with a bracket.
                    plain.append(line)
                } else if !remainder.isEmpty {
                    // A tag with words after it: the tag goes, the words stay.
                    plain.append(remainder)
                }
            } else if !remainder.isEmpty {
                // One line can carry several stamps, which is how an LRC file
                // says a chorus is sung more than once.
                for stamp in stamps {
                    timed.append(Lyrics.Line(start: stamp, text: remainder))
                }
            }
        }

        if !timed.isEmpty {
            return Lyrics(
                synced: true,
                language: language,
                offset: offset,
                lines: timed.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
            )
        }

        let words = trimmed(plain)
        guard !words.isEmpty else { return nil }
        return Lyrics(
            synced: false,
            language: language,
            offset: 0,
            lines: words.map { Lyrics.Line(text: $0) }
        )
    }

    /// The `[…]` groups a line opens with, and whatever follows them.
    private static func leadingTags(of line: String) -> (tags: [String], remainder: String) {
        var tags: [String] = []
        var rest = Substring(line)
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            tags.append(String(rest[rest.index(after: rest.startIndex)..<close]))
            rest = rest[rest.index(after: close)...]
            // A stamp may be followed by a space before the words.
            while rest.first == " " { rest = rest.dropFirst() }
        }
        return (tags, String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// `mm:ss.cc`, `mm:ss:cc` or `mm:ss`, in seconds. Nil for anything else,
    /// which is how a metadata tag is told from a stamp.
    private static func timestamp(_ tag: String) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Double(parts[0]), minutes >= 0
        else { return nil }

        if parts.count == 2 {
            // `ss.cc` or `ss` — the fraction is part of the seconds.
            guard let seconds = Double(parts[1]), seconds >= 0, seconds < 60 else { return nil }
            return minutes * 60 + seconds
        }
        guard let seconds = Double(parts[1]), seconds >= 0, seconds < 60,
              let fraction = Double("0." + parts[2]), fraction >= 0
        else { return nil }
        return minutes * 60 + seconds + fraction
    }

    /// `key:value`, lowercased key.
    private static func metadata(_ tag: String) -> (key: String, value: String)? {
        guard let colon = tag.firstIndex(of: ":") else { return nil }
        let key = tag[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter }) else { return nil }
        return (key, String(tag[tag.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    /// Blank lines off both ends, and never more than one in a row.
    private static func trimmed(_ lines: [String]) -> [String] {
        var kept: [String] = []
        for line in lines where !(line.isEmpty && kept.last?.isEmpty != false) {
            kept.append(line)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return kept
    }
}
