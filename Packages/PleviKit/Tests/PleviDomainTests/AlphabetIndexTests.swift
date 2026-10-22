import Foundation
import Testing
import PleviDomain

@Suite struct AlphabetIndexTests {
    // MARK: Bar order

    @Test func barStartsWithTheNonLetterBucket() {
        #expect(AlphabetIndex.allSections.first == "#")
    }

    /// The whole reason this exists: these three are letters in their own
    /// right in Norwegian and Danish, and they come after Z.
    @Test func barEndsWithAeOeAaInThatOrder() {
        #expect(AlphabetIndex.allSections.suffix(3) == ["Æ", "Ø", "Å"])
    }

    @Test func barHasEveryBucketExactlyOnce() {
        #expect(AlphabetIndex.allSections.count == 30)
        #expect(Set(AlphabetIndex.allSections).count == 30)
    }

    @Test func rankOrdersTheBarFromHashToAa() {
        #expect(AlphabetIndex.rank(ofSection: "#") < AlphabetIndex.rank(ofSection: "A"))
        #expect(AlphabetIndex.rank(ofSection: "Z") < AlphabetIndex.rank(ofSection: "Æ"))
        #expect(AlphabetIndex.rank(ofSection: "Æ") < AlphabetIndex.rank(ofSection: "Ø"))
        #expect(AlphabetIndex.rank(ofSection: "Ø") < AlphabetIndex.rank(ofSection: "Å"))
    }

    // MARK: Filing

    @Test func filesPlainTitlesUnderTheirFirstLetter() {
        #expect(AlphabetIndex.section(for: "Coldplay") == "C")
        #expect(AlphabetIndex.section(for: "coldplay") == "C")
    }

    @Test func filesNumbersAndSymbolsUnderHash() {
        for title in ["2015 Grammy Nominees", "1989", "!!!", "+", "…and Justice for All"] {
            #expect(AlphabetIndex.section(for: title) == "#", "\(title)")
        }
    }

    @Test func filesTitlesWithNoLatinLetterUnderHash() {
        #expect(AlphabetIndex.section(for: "東京事変") == "#")
        #expect(AlphabetIndex.section(for: "Мумий Тролль") == "#")
        #expect(AlphabetIndex.section(for: "") == "#")
        #expect(AlphabetIndex.section(for: "   ") == "#")
    }

    // MARK: The three that matter

    @Test func filesAeOeAaUnderThemselvesRatherThanAOrO() {
        #expect(AlphabetIndex.section(for: "Ærøskøbing") == "Æ")
        #expect(AlphabetIndex.section(for: "ærøskøbing") == "Æ")
        #expect(AlphabetIndex.section(for: "Ørsted") == "Ø")
        #expect(AlphabetIndex.section(for: "ørsted") == "Ø")
        #expect(AlphabetIndex.section(for: "Åge Aleksandersen") == "Å")
        #expect(AlphabetIndex.section(for: "åge") == "Å")
    }

    /// Swedish and Finnish spellings of the same sounds.
    @Test func filesSwedishVowelsWithTheirNorwegianEquivalents() {
        #expect(AlphabetIndex.section(for: "Ärger") == "Æ")
        #expect(AlphabetIndex.section(for: "Öland") == "Ø")
    }

    /// Ordinary accents *are* just accents and belong under the plain letter.
    @Test func foldsOrdinaryAccentsOntoTheirLetter() {
        #expect(AlphabetIndex.section(for: "Édith Piaf") == "E")
        #expect(AlphabetIndex.section(for: "Ñu") == "N")
        #expect(AlphabetIndex.section(for: "Üdo") == "U")
        #expect(AlphabetIndex.section(for: "Àlex") == "A")
    }

    // MARK: Grouping

    @Test func groupsInBarOrderAndSkipsEmptyBuckets() {
        let names = ["Åge", "Coldplay", "2015 Grammy", "Ørsted", "Beatles", "Ærø"]
        let groups = AlphabetIndex.group(names) { $0 }
        #expect(groups.map(\.section) == ["#", "B", "C", "Æ", "Ø", "Å"])
        #expect(groups.first?.values == ["2015 Grammy"])
        #expect(groups.last?.values == ["Åge"])
    }

    @Test func groupingKeepsTheOrderItWasGiven() {
        let names = ["Coldplay", "Cure", "Cardigans"]
        let groups = AlphabetIndex.group(names) { $0 }
        #expect(groups.count == 1)
        #expect(groups[0].values == ["Coldplay", "Cure", "Cardigans"])
    }

    @Test func groupingAnEmptyListGivesNoSections() {
        #expect(AlphabetIndex.group([String]()) { $0 }.isEmpty)
    }
}

@Suite struct ReleaseTypeGroupingTests {
    private func album(_ types: [ReleaseType], compilation: Bool = false) -> Album {
        Album(
            id: MediaID(server: ServerID(), rawValue: "1"),
            name: "Record",
            releaseTypes: types,
            isCompilation: compilation
        )
    }

    /// Servers list the general type first — a live record is tagged
    /// "album, live" — so taking the first entry filed every one of them
    /// under Albums and the Live section never appeared.
    @Test func theSpecificTypeWinsOverAGeneralOneListedFirst() {
        #expect(album([.album, .live]).primaryReleaseType == .live)
        #expect(album([.album, .soundtrack]).primaryReleaseType == .soundtrack)
        #expect(album([.album, .ep]).primaryReleaseType == .ep)
    }

    @Test func orderWithinTheListDoesNotMatter() {
        #expect(album([.live, .album]).primaryReleaseType == .live)
        #expect(album([.ep, .soundtrack]).primaryReleaseType == .ep)
    }

    @Test func aPlainAlbumIsStillAnAlbum() {
        #expect(album([.album]).primaryReleaseType == .album)
        #expect(album([]).primaryReleaseType == .album)
    }

    /// A server may tag a compilation simply as "Album", so the flag wins.
    @Test func theCompilationFlagBeatsTheTypeList() {
        #expect(album([.album], compilation: true).primaryReleaseType == .compilation)
        #expect(album([.album, .live], compilation: true).primaryReleaseType == .compilation)
    }
}

@Suite struct AlbumDisplayNameTests {
    private func album(name: String, artistName: String? = nil) -> Album {
        Album(id: MediaID(server: ServerID(), rawValue: "1"), name: name, artistName: artistName)
    }

    @Test func aNamedAlbumKeepsItsName() {
        #expect(album(name: "Human", artistName: "OneRepublic").displayName == "Human")
    }

    /// Some singles arrive from the server with no album name at all — the
    /// track and the "album" are the same release, and nothing filled the
    /// latter in. A blank row helps nobody, so the artist stands in.
    @Test func aBlankNameFallsBackToTheArtist() {
        #expect(album(name: "", artistName: "Jakubi").displayName == "Jakubi")
    }

    @Test func whitespaceOnlyCountsAsBlank() {
        #expect(album(name: "   ", artistName: "Jakubi").displayName == "Jakubi")
    }

    /// No artist either — as blank an answer as the data can give — keeps
    /// the empty string rather than inventing a placeholder here; callers
    /// showing this to a person are the right place for "Unknown Album".
    @Test func aBlankNameWithNoArtistStaysBlank() {
        #expect(album(name: "").displayName == "")
    }
}
