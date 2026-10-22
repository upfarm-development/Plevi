import Foundation
import Testing
import PleviDomain

@Suite("Playlist order")
struct PlaylistSortingTests {
    private let server = ServerID()

    private func playlist(_ name: String, smart: Bool = false) -> Playlist {
        Playlist(
            id: MediaID(server: server, rawValue: name),
            name: name,
            isSmart: smart
        )
    }

    private var mixed: [Playlist] {
        [
            playlist("Road trip"),
            playlist("5 Star", smart: true),
            playlist("Beyond Skyrim"),
            playlist("80s Hits", smart: true),
        ]
    }

    @Test("All together is one list by name")
    func together() {
        #expect(PlaylistSorting.together.sorted(mixed).map(\.name)
            == ["5 Star", "80s Hits", "Beyond Skyrim", "Road trip"])
    }

    @Test("Smart first keeps the two kinds apart, each by name")
    func smartFirst() {
        #expect(PlaylistSorting.smartFirst.sorted(mixed).map(\.name)
            == ["5 Star", "80s Hits", "Beyond Skyrim", "Road trip"])

        // With a smart playlist late in the alphabet the grouping shows.
        let list = [
            playlist("Alpha"),
            playlist("Zulu", smart: true),
        ]
        #expect(PlaylistSorting.smartFirst.sorted(list).map(\.name) == ["Zulu", "Alpha"])
        #expect(PlaylistSorting.together.sorted(list).map(\.name) == ["Alpha", "Zulu"])
    }

    @Test("Numbers read as numbers")
    func naturalOrder() {
        let list = [playlist("Now 10"), playlist("Now 9"), playlist("Now 100")]
        #expect(PlaylistSorting.together.sorted(list).map(\.name)
            == ["Now 9", "Now 10", "Now 100"])
    }

    @Test("Two playlists with one name keep a stable order")
    func duplicates() {
        let a = Playlist(id: MediaID(server: server, rawValue: "a"), name: "Mix")
        let b = Playlist(id: MediaID(server: server, rawValue: "b"), name: "Mix")
        #expect(PlaylistSorting.together.sorted([b, a]).map(\.id.rawValue) == ["a", "b"])
    }
}
