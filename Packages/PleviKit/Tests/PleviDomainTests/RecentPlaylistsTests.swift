import Foundation
import Testing
@testable import PleviDomain

/// The list at the head of the add-to-playlist picker.
@Suite("The playlists songs were last added to")
struct RecentPlaylistsTests {
    private static let server = ServerID()

    private static func playlist(_ ratingKey: String, _ name: String, smart: Bool = false) -> Playlist {
        Playlist(
            id: MediaID(server: server, rawValue: ratingKey),
            name: name,
            trackCount: 42,
            isSmart: smart
        )
    }

    @Test("The one just added to comes first")
    func mostRecentFirst() {
        var remembered: [String] = []
        remembered = RecentPlaylists.recording("38112", in: remembered)
        remembered = RecentPlaylists.recording("41007", in: remembered)
        remembered = RecentPlaylists.recording("2295", in: remembered)

        #expect(remembered == ["2295", "41007", "38112"])
    }

    @Test("Adding to one already in the list moves it up rather than repeating it")
    func noDuplicates() {
        var remembered: [String] = []
        for key in ["38112", "41007", "2295"] {
            remembered = RecentPlaylists.recording(key, in: remembered)
        }
        remembered = RecentPlaylists.recording("41007", in: remembered)

        #expect(remembered == ["41007", "2295", "38112"])
        #expect(remembered.count == Set(remembered).count)
    }

    @Test("No more than the kept number are remembered, and the oldest is the one dropped")
    func boundedLength() {
        var remembered: [String] = []
        let keys = (1...(RecentPlaylists.kept + 4)).map(String.init)
        for key in keys {
            remembered = RecentPlaylists.recording(key, in: remembered)
        }

        #expect(remembered.count == RecentPlaylists.kept)
        #expect(remembered.first == keys.last)
        #expect(!remembered.contains("1"))
        #expect(!remembered.contains("4"))
        #expect(remembered.contains("5"))
    }

    @Test("The picker is given the newest few, in that order")
    func resolvesNewestFirst() {
        let all = [
            Self.playlist("38112", "Sunday Morning"),
            Self.playlist("41007", "Loud", smart: true),
            Self.playlist("2295", "Boxes"),
            Self.playlist("9911", "Never Touched"),
        ]
        let remembered = ["2295", "41007", "38112", "9911"]

        let recent = RecentPlaylists.resolve(remembered, among: all)

        #expect(recent.count == RecentPlaylists.shown)
        #expect(recent.map(\.name) == ["Boxes", "Loud", "Sunday Morning"])
    }

    /// The failure this is really about: a playlist deleted in the Plex desktop is still remembered
    /// here, and taking the first three identifiers before checking which of them exist would show
    /// two rows and a hole.
    @Test("One deleted on the server is skipped, and the next one takes its place")
    func skipsPlaylistsThatAreGone() {
        let all = [
            Self.playlist("38112", "Sunday Morning"),
            Self.playlist("2295", "Boxes"),
            Self.playlist("9911", "Late Night"),
        ]
        // 41007 was added to recently and has since been deleted on the
        // server, so it is remembered but not in the library any more.
        let remembered = ["2295", "41007", "38112", "9911"]

        let recent = RecentPlaylists.resolve(remembered, among: all)

        #expect(recent.map(\.name) == ["Boxes", "Sunday Morning", "Late Night"])
    }

    @Test("A library with nothing remembered yet gets no list at all")
    func nothingRemembered() {
        let all = [Self.playlist("38112", "Sunday Morning")]

        #expect(RecentPlaylists.resolve([], among: all).isEmpty)
    }

    @Test("Remembering fewer than three shows only those, not a padded three")
    func fewerThanShown() {
        let all = [
            Self.playlist("38112", "Sunday Morning"),
            Self.playlist("2295", "Boxes"),
        ]

        let recent = RecentPlaylists.resolve(["2295"], among: all)

        #expect(recent.map(\.name) == ["Boxes"])
    }
}
