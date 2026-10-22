import Foundation

/// Files titles into the buckets an A–Z jump bar offers.
public enum AlphabetIndex {
    /// Numbers, symbols, and any script without a Latin letter to file under.
    public static let other = "#"

    /// Æ, Ø, Å close the alphabet, in that order.
    public static let trailingLetters = ["Æ", "Ø", "Å"]

    public static let latinLetters: [String] = (UInt8(ascii: "A")...UInt8(ascii: "Z"))
        .map { String(UnicodeScalar($0)) }

    /// Every bucket, in bar order.
    public static let allSections: [String] = [other] + latinLetters + trailingLetters

    /// Sorting rank, so a list can be ordered to match the bar.
    public static func rank(ofSection section: String) -> Int {
        allSections.firstIndex(of: section) ?? 0
    }

    /// The bucket `title` belongs to.
    public static func section(for title: String) -> String {
        guard let first = title.first(where: { !$0.isWhitespace && !$0.isNewline }) else {
            return other
        }

        // The overwhelmingly common case, answered without touching ICU.
        if let ascii = first.asciiValue {
            if ascii >= UInt8(ascii: "A"), ascii <= UInt8(ascii: "Z") { return String(first) }
            if ascii >= UInt8(ascii: "a"), ascii <= UInt8(ascii: "z") {
                return String(first).uppercased()
            }
            return other
        }

        // Checked before any folding: `Å` folds to `A` and `Æ` expands to
        // `AE`, which would file all three under the wrong letter.
        for scalar in String(first).uppercased().unicodeScalars {
            switch scalar {
            case "Æ", "Ä": return "Æ"
            case "Ø", "Ö", "Œ": return "Ø"
            case "Å": return "Å"
            default: break
            }
        }

        let folded = String(first).foldingLatin().uppercased()
        guard let letter = folded.first, letter.isASCII, letter.isLetter else { return other }
        return String(letter)
    }

    /// The bucket's position in `allSections`, decided without building a `String` for it.
    @inlinable
    public static func rank(for title: String) -> Int {
        guard let first = title.utf8.first else { return 0 }
        if first >= 0x41, first <= 0x5A { return Int(first) - 0x40 }   // A–Z
        if first >= 0x61, first <= 0x7A { return Int(first) - 0x60 }   // a–z
        if first > 0x20, first < 0x80 { return 0 }                     // ASCII, not a letter
        // Leading whitespace, or anything outside ASCII: the careful path.
        return rank(ofSection: section(for: title))
    }

    /// Where each row goes and where each section starts, without moving a single value.
    public struct Filing: Sendable, Equatable {
        public var order: [Int32]
        public var sections: [String]
        public var ranges: [Range<Int>]

        public init(order: [Int32] = [], sections: [String] = [], ranges: [Range<Int>] = []) {
            self.order = order
            self.sections = sections
            self.ranges = ranges
        }

        public var isEmpty: Bool { sections.isEmpty }
    }

    /// Files titled values into bar order and returns only the shape of the filing — never a copy
    /// of the values.
    @inlinable
    public static func file<Value>(
        _ values: [Value],
        title: (Value) -> String
    ) -> Filing {
        let n = values.count
        guard n > 0 else { return Filing() }

        var ranks = [Int8](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: allSections.count)
        // A list arriving from `ORDER BY title COLLATE NOCASE` is very nearly in bar order already
        // — but only nearly, so this is checked rather than assumed.
        var alreadyFiled = true
        var previous: Int8 = 0
        for i in 0..<n {
            let r = Int8(rank(for: title(values[i])))
            ranks[i] = r
            counts[Int(r)] += 1
            if r < previous { alreadyFiled = false }
            previous = r
        }

        var starts = [Int](repeating: 0, count: counts.count)
        var running = 0
        for s in 0..<counts.count {
            starts[s] = running
            running += counts[s]
        }

        var order = [Int32](repeating: 0, count: n)
        if alreadyFiled {
            for i in 0..<n { order[i] = Int32(i) }
        } else {
            var cursor = starts
            for i in 0..<n {
                let s = Int(ranks[i])
                order[cursor[s]] = Int32(i)
                cursor[s] += 1
            }
        }

        var filing = Filing(order: order)
        filing.sections.reserveCapacity(counts.count)
        filing.ranges.reserveCapacity(counts.count)
        for s in 0..<counts.count where counts[s] > 0 {
            filing.sections.append(allSections[s])
            filing.ranges.append(starts[s]..<(starts[s] + counts[s]))
        }
        return filing
    }

    /// Where each letter's run sits in a list already in bar order.
    public struct SectionRuns: Sendable, Equatable {
        public var sections: [String]
        public var ranges: [Range<Int>]
        /// How many rows these runs were filed from.
        public var count: Int

        public init(sections: [String] = [], ranges: [Range<Int>] = [], count: Int = 0) {
            self.sections = sections
            self.ranges = ranges
            self.count = count
        }

        public var isEmpty: Bool { sections.isEmpty }

        /// One unnamed run over everything: draw it flat, and no bar.
        public static func flat(count: Int) -> SectionRuns {
            count == 0 ? SectionRuns() : SectionRuns(sections: [""], ranges: [0..<count], count: count)
        }
    }

    /// The values in bar order, and where each letter's run sits in them.
    public static func filed<Value>(
        _ values: [Value],
        title: (Value) -> String
    ) -> (values: [Value], runs: SectionRuns) {
        let filing = file(values, title: title)
        guard !filing.order.isEmpty else { return (values, SectionRuns()) }
        // A list that arrived from the database already sorted by the same
        // key usually needs no moving at all, and moving it would mean a
        // second copy of every song for nothing.
        var ordered = values
        if !filing.order.enumerated().allSatisfy({ Int($1) == $0 }) {
            ordered = []
            ordered.reserveCapacity(filing.order.count)
            for source in filing.order { ordered.append(values[Int(source)]) }
        }
        return (
            ordered,
            SectionRuns(sections: filing.sections, ranges: filing.ranges, count: ordered.count)
        )
    }

    /// Groups titled values into bar order, keeping each bucket's incoming
    /// order and dropping buckets nothing landed in.
    public static func group<Value>(
        _ values: [Value],
        title: (Value) -> String
    ) -> [(section: String, values: [Value])] {
        var buckets: [String: [Value]] = [:]
        for value in values {
            buckets[section(for: title(value)), default: []].append(value)
        }
        return allSections.compactMap { section in
            guard let values = buckets[section] else { return nil }
            return (section, values)
        }
    }
}

extension StringProtocol {
    /// `Å`→`A`, `Ø`/`Ö`→`O`, full-width Latin→plain — the fold `AlphabetIndex`
    /// files letters by and `DuplicateSongs` compares titles by, kept in one
    /// place so the two never drift apart on which marks count as noise.
    func foldingLatin() -> String {
        folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
    }
}
