import Foundation
import Testing
@testable import PleviLibraryIndex

/// The order forty fields are offered in.
@Suite("Finding a field in the list of them")
struct FilterFieldOrderTests {
    /// The word a family's fields are named with, where it has one.
    private func word(_ family: FilterField.Family) -> String? {
        switch family {
        case .artist: "Artist"
        case .album: "Album"
        case .track: "Track"
        case .playlist: "Playlist"
        case .ours: nil
        }
    }

    @Test("Every field's family agrees with what it is called", arguments: LibraryFilter.Subject.allCases)
    func familyAgreesWithTheName(subject: LibraryFilter.Subject) {
        // The list is sorted into runs and the runs are named by the words at the front of their
        // rows.
        for field in FilterField.fields(for: subject) {
            guard let word = word(field.family(for: subject)) else { continue }
            let title = field.title(for: subject)
            #expect(
                title.hasPrefix(word + " ") || title == word,
                "\(field.rawValue) on \(subject) is \(word) family but called \"\(title)\""
            )
        }
    }

    @Test("Artist, then album, then track, then playlist", arguments: LibraryFilter.Subject.allCases)
    func familiesComeInOrder(subject: LibraryFilter.Subject) {
        let families = FilterField.fields(for: subject).map { $0.family(for: subject) }
        #expect(families == families.sorted(), "\(subject): \(families.map(\.rawValue))")
    }

    @Test("Alphabetical inside each run", arguments: LibraryFilter.Subject.allCases)
    func namesAreSortedWithinAFamily(subject: LibraryFilter.Subject) {
        let fields = FilterField.fields(for: subject)
        for (first, second) in zip(fields, fields.dropFirst())
        where first.family(for: subject) == second.family(for: subject) {
            let a = first.title(for: subject)
            let b = second.title(for: subject)
            #expect(
                a.localizedStandardCompare(b) != .orderedDescending,
                "\(subject): \"\(a)\" comes before \"\(b)\""
            )
        }
    }

    @Test("Sorting loses nothing and invents nothing")
    func everyFieldIsStillOffered() {
        for subject in LibraryFilter.Subject.allCases {
            let offered = Set(FilterField.fields(for: subject))
            let applicable = Set(FilterField.allCases.filter { $0.applies(to: subject) })
            #expect(offered == applicable)
            #expect(FilterField.fields(for: subject).count == applicable.count)
        }
    }

    @Test("Playlists come after the music, and Downloaded after everything")
    func theTailOfTheList() {
        // "Playlist last last", and the one field that is ours rather than
        // the server's after even that.
        let songs = FilterField.fields(for: .songs)
        let playlist = songs.firstIndex(of: .playlistName)
        let downloaded = songs.firstIndex(of: .downloaded)
        let lastTrack = songs.lastIndex { $0.family(for: .songs) == .track }
        #expect(playlist != nil)
        #expect(downloaded != nil)
        #expect(lastTrack! < playlist!)
        #expect(playlist! < downloaded!)
        #expect(downloaded == songs.count - 1)
    }
}
