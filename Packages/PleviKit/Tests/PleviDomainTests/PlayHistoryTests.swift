import Foundation
import Testing
@testable import PleviDomain

@Suite("What has been put on lately")
struct PlayHistoryTests {
    private static let server = ServerID()
    private static func id(_ raw: String) -> MediaID {
        MediaID(server: server, rawValue: raw)
    }

    private static func album(_ raw: String) -> PlayedSource {
        PlayedSource(kind: .album, mediaID: id(raw), title: "Album \(raw)")
    }

    private static func playlist(_ raw: String) -> PlayedSource {
        PlayedSource(kind: .playlist, mediaID: id(raw), title: "Playlist \(raw)")
    }

    private static func at(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    @Test("The newest thing put on comes first")
    func newestFirst() {
        var history: [PlayedEntry] = []
        history = PlayHistory.recording(Self.album("a"), at: Self.at(100), in: history)
        history = PlayHistory.recording(Self.album("b"), at: Self.at(200), in: history)
        #expect(history.map(\.source.title) == ["Album b", "Album a"])
    }

    @Test("Playing something again moves it rather than listing it twice")
    func replayingMoves() {
        var history: [PlayedEntry] = []
        history = PlayHistory.recording(Self.album("a"), at: Self.at(100), in: history)
        history = PlayHistory.recording(Self.album("b"), at: Self.at(200), in: history)
        history = PlayHistory.recording(Self.album("a"), at: Self.at(300), in: history)
        #expect(history.count == 2, "the same record twice is one answer, not two")
        #expect(history.map(\.source.title) == ["Album a", "Album b"])
        #expect(history.first?.playedAt == Self.at(300), "and it carries the newer time")
    }

    @Test("A record and a playlist sharing a raw value are different things")
    func kindsDoNotCollide() {
        var history: [PlayedEntry] = []
        history = PlayHistory.recording(Self.album("same"), at: Self.at(100), in: history)
        history = PlayHistory.recording(Self.playlist("same"), at: Self.at(200), in: history)
        #expect(history.count == 2)
        #expect(history.map(\.source.kind) == [.playlist, .album])
    }

    @Test("The oldest falls off the end once it is full")
    func capped() {
        var history: [PlayedEntry] = []
        for n in 0..<(PlayHistory.kept + 5) {
            history = PlayHistory.recording(
                Self.album("a\(n)"), at: Self.at(Double(n)), in: history
            )
        }
        #expect(history.count == PlayHistory.kept)
        #expect(history.first?.source.title == "Album a\(PlayHistory.kept + 4)")
        // The first five put on are gone, not merely pushed down.
        #expect(history.contains { $0.source.title == "Album a0" } == false)
        #expect(history.contains { $0.source.title == "Album a4" } == false)
        #expect(history.contains { $0.source.title == "Album a5" })
    }

    @Test("A seed arrives in any order and comes back newest first")
    func seeding() {
        let entries = [
            PlayedEntry(source: Self.album("old"), playedAt: Self.at(100)),
            PlayedEntry(source: Self.album("new"), playedAt: Self.at(900)),
            PlayedEntry(source: Self.album("mid"), playedAt: Self.at(500)),
        ]
        #expect(PlayHistory.seeded(entries).map(\.source.title)
                == ["Album new", "Album mid", "Album old"])
    }

    @Test("A seed holding the same thing twice keeps only the newer")
    func seedingDedupes() {
        let entries = [
            PlayedEntry(source: Self.album("a"), playedAt: Self.at(100)),
            PlayedEntry(source: Self.album("a"), playedAt: Self.at(900)),
        ]
        let seeded = PlayHistory.seeded(entries)
        #expect(seeded.count == 1)
        #expect(seeded.first?.playedAt == Self.at(900))
    }

    @Test("A seed is capped the same way the history is")
    func seedingIsCapped() {
        let entries = (0..<(PlayHistory.kept + 10)).map { n in
            PlayedEntry(source: Self.album("a\(n)"), playedAt: Self.at(Double(n)))
        }
        #expect(PlayHistory.seeded(entries).count == PlayHistory.kept)
    }
}

/// Holding a playlist at the top of the list.
@Suite("Playlists held at the top")
struct PlaylistTopPinSortingTests {
    private static let server = ServerID()

    private static func playlist(_ name: String, smart: Bool = false) -> Playlist {
        Playlist(
            id: MediaID(server: server, rawValue: name.lowercased()),
            name: name,
            isSmart: smart
        )
    }

    private static let all = [
        Self.playlist("Alpha"),
        Self.playlist("Bravo"),
        Self.playlist("Charlie"),
        Self.playlist("Delta"),
    ]

    @Test("Nothing pinned sorts exactly as it always did")
    func unpinnedIsUnchanged() {
        #expect(PlaylistSorting.together.sorted(Self.all).map(\.name)
                == ["Alpha", "Bravo", "Charlie", "Delta"])
    }

    @Test("A pinned playlist goes to the top wherever its name falls")
    func pinnedGoesFirst() {
        let sorted = PlaylistSorting.together.sorted(Self.all, pinnedToTop: ["delta"])
        #expect(sorted.map(\.name) == ["Delta", "Alpha", "Bravo", "Charlie"])
    }

    @Test("Several pinned sort among themselves the way the list does")
    func severalPinnedSortAlphabetically() {
        let sorted = PlaylistSorting.together.sorted(Self.all, pinnedToTop: ["delta", "bravo"])
        #expect(sorted.map(\.name) == ["Bravo", "Delta", "Alpha", "Charlie"])
    }

    @Test("Being pinned outranks the smart-first split, both above and below")
    func pinnedOutranksSmartFirst() {
        let mixed = [
            Self.playlist("Smart One", smart: true),
            Self.playlist("Smart Two", smart: true),
            Self.playlist("Plain One"),
        ]
        // A plain playlist pinned sits above the smart ones, which is the
        // point of pinning it; the smart ones keep their own order below.
        #expect(PlaylistSorting.smartFirst.sorted(mixed, pinnedToTop: ["plain one"]).map(\.name)
                == ["Plain One", "Smart One", "Smart Two"])
        // And with nothing pinned the split is untouched.
        #expect(PlaylistSorting.smartFirst.sorted(mixed).map(\.name)
                == ["Smart One", "Smart Two", "Plain One"])
    }

    @Test("An id that matches nothing changes nothing")
    func staleIdIsHarmless() {
        #expect(PlaylistSorting.together.sorted(Self.all, pinnedToTop: ["deleted"]).map(\.name)
                == ["Alpha", "Bravo", "Charlie", "Delta"])
    }
}
