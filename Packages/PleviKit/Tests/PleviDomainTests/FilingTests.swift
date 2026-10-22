import Foundation
import Testing
@testable import PleviDomain

/// `AlphabetIndex.file` has to answer exactly what `AlphabetIndex.group`
/// answers — same sections, same counts, same rows in the same order inside
/// each section — because it is replacing it on screen.
@Suite("Filing without copying")
struct FilingTests {

    private static func titles(_ count: Int) -> [String] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let awkward = ["Ærøskøbing", "Østen", "Åsa", "Ölandsvisan", "日本の歌", "123 Go",
                       "  spaced", "Édith", "Ñu", "Üdo", "", "   ", "!!!", "9 to 5", "œuf"]
        return (0..<count).map { i in
            if i % 7 == 0 { return awkward[(i / 7) % awkward.count] + " \(i)" }
            return "\(letters[i % letters.count])ong number \(i)"
        }
    }

    private static func tracks(_ titles: [String]) -> [Track] {
        let server = ServerID()
        var out: [Track] = []
        out.reserveCapacity(titles.count)
        for (i, title) in titles.enumerated() {
            var t = Track(id: MediaID(server: server, rawValue: "t\(i)"), title: title)
            t.artistName = "Artist \(i % 900)"
            t.duration = 210
            out.append(t)
        }
        return out
    }

    @Test("rank agrees with section, for everything section can decide")
    func rankAgreesWithSection() {
        var probes = Self.titles(4_000)
        probes += ["", " ", "\n\tØde", "   Waterloo", "ärger", "ÅSA", "æon", "Ölandsvisan",
                   "東京事変", "Мумий Тролль", "123", "-dash", "_under", "~tilde", "Ø"]
        for title in probes {
            #expect(
                AlphabetIndex.rank(for: title)
                    == AlphabetIndex.rank(ofSection: AlphabetIndex.section(for: title)),
                "\(title.debugDescription)"
            )
        }
    }

    @Test("file reproduces group exactly, on an unsorted list")
    func matchesGroupUnsorted() {
        let tracks = Self.tracks(Self.titles(5_000))
        let groups = AlphabetIndex.group(tracks) { $0.displayTitle }
        let filing = AlphabetIndex.file(tracks) { $0.displayTitle }

        #expect(filing.sections == groups.map(\.section))
        #expect(filing.ranges.map(\.count) == groups.map(\.values.count))
        for (j, group) in groups.enumerated() {
            let rows = filing.ranges[j].map { tracks[Int(filing.order[$0])].id }
            #expect(rows == group.values.map(\.id), "section \(group.section)")
        }
    }

    @Test("file reproduces group exactly, on a list already in title order")
    func matchesGroupSorted() {
        let sorted = Self.titles(5_000).sorted { $0.lowercased() < $1.lowercased() }
        let tracks = Self.tracks(sorted)
        let groups = AlphabetIndex.group(tracks) { $0.displayTitle }
        let filing = AlphabetIndex.file(tracks) { $0.displayTitle }

        #expect(filing.sections == groups.map(\.section))
        for (j, group) in groups.enumerated() {
            let rows = filing.ranges[j].map { tracks[Int(filing.order[$0])].id }
            #expect(rows == group.values.map(\.id), "section \(group.section)")
        }
    }

    @Test("the ranges cover every row exactly once")
    func rangesPartition() {
        let tracks = Self.tracks(Self.titles(3_000))
        let filing = AlphabetIndex.file(tracks) { $0.displayTitle }
        #expect(filing.ranges.map(\.count).reduce(0, +) == tracks.count)
        #expect(Set(filing.order).count == tracks.count)
        var expected = 0
        for range in filing.ranges {
            #expect(range.lowerBound == expected)
            expected = range.upperBound
        }
        #expect(expected == tracks.count)
    }

    @Test("an empty list files into nothing")
    func empty() {
        let filing = AlphabetIndex.file([String]()) { $0 }
        #expect(filing.isEmpty)
        #expect(filing.order.isEmpty)
    }

    @Test("what filing costs against grouping, at library scale")
    func cost() {
        let tracks = Self.tracks(Self.titles(61_287))
        func best(_ body: () -> Void) -> Double {
            var fastest = Double.infinity
            for _ in 0..<5 {
                let started = Date()
                body()
                fastest = min(fastest, Date().timeIntervalSince(started) * 1000)
            }
            return fastest
        }
        var sink = 0
        let groupMS = best { sink &+= AlphabetIndex.group(tracks) { $0.displayTitle }.count }
        let fileMS = best { sink &+= AlphabetIndex.file(tracks) { $0.displayTitle }.sections.count }
        print(String(format: "FILECOST group=%.1fms file=%.1fms (%.1fx)  [debug build; sink %d]",
                     groupMS, fileMS, groupMS / fileMS, sink))
        #expect(fileMS < groupMS)
    }
}

@Suite("Filing a list into bar order")
struct FiledTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
        let title: String
    }

    private func rows() -> [Row] {
        let titles = [
            "Åse's song", "banana", "Apple", "42", "Ærøskøbing", "zebra",
            "Ölandsvisan", "  spaced out", "日本の歌", "Apple pie", "Ø marks it",
        ]
        return titles.enumerated().map { Row(id: $0.offset, title: $0.element) }
    }

    @Test("The values come back in exactly the order group would have put them")
    func agreesWithGroup() {
        let values = rows()
        let (ordered, runs) = AlphabetIndex.filed(values) { $0.title }
        let grouped = AlphabetIndex.group(values) { $0.title }
        #expect(ordered == grouped.flatMap(\.values))
        #expect(runs.sections == grouped.map(\.section))
        #expect(runs.count == values.count)
    }

    @Test("Every run points at the rows filed under its own letter")
    func runsLineUp() {
        let values = rows()
        let (ordered, runs) = AlphabetIndex.filed(values) { $0.title }
        for (section, range) in zip(runs.sections, runs.ranges) {
            #expect(ordered[range].allSatisfy { AlphabetIndex.section(for: $0.title) == section },
                    "a row under \(section) does not belong there")
        }
        #expect(runs.ranges.map(\.count).reduce(0, +) == values.count)
    }

    @Test("A list already in bar order is not moved at all")
    func leavesSortedListsAlone() {
        let values = (0..<200).map { Row(id: $0, title: "\(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")[$0 / 8]) song \($0)") }
        let (ordered, _) = AlphabetIndex.filed(values) { $0.title }
        #expect(ordered == values)
    }

    @Test("Nothing in, nothing out")
    func empty() {
        let (ordered, runs) = AlphabetIndex.filed([Row]()) { $0.title }
        #expect(ordered.isEmpty)
        #expect(runs.isEmpty)
        #expect(runs.count == 0)
    }
}
