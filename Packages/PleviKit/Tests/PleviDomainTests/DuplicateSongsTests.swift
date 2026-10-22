import Foundation
import Testing
@testable import PleviDomain

@Suite("One song, once")
struct DuplicateSongsTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func copy(
        _ raw: String,
        _ title: String,
        album: String? = nil,
        rating: Double? = nil,
        hearted: Bool = false,
        plays: Int? = nil,
        collection: Bool = false,
        year: Int? = nil
    ) -> DuplicateSongs.Copy {
        DuplicateSongs.Copy(
            track: Track(
                id: id(raw),
                title: title,
                albumName: album,
                isFavorite: hearted,
                rating: rating.flatMap { StarRating($0) },
                playCount: plays
            ),
            isFromCollection: collection,
            recordYear: year
        )
    }

    // MARK: What counts as the same song

    @Test("The plain case: the same title on two records")
    func sameTitleIsTheSameSong() {
        #expect(DuplicateSongs.key(for: "Marquee Moon") == DuplicateSongs.key(for: "marquee  moon"))
    }

    @Test("A remaster is the same recording, whatever it is called")
    func remastersFold() {
        let plain = DuplicateSongs.key(for: "Marquee Moon")
        for spelling in [
            "Marquee Moon (Remastered)",
            "Marquee Moon (2003 Remaster)",
            "Marquee Moon (Remastered 2003)",
            "Marquee Moon - 2003 Remaster",
            "Marquee Moon - Remastered",
            "Marquee Moon [2003 Remastered Version]",
            "Marquee Moon (Deluxe Edition)",
            "Marquee Moon (Album Version)",
            "Marquee Moon (Original Mix)",
            "Marquee Moon (Mono)",
        ] {
            #expect(DuplicateSongs.key(for: spelling) == plain, "\(spelling)")
        }
    }

    @Test("Several layers of noise peel off")
    func noisePeelsRepeatedly() {
        #expect(
            DuplicateSongs.key(for: "Marquee Moon (2003 Remaster) [Deluxe Edition]")
                == DuplicateSongs.key(for: "Marquee Moon")
        )
    }

    @Test("A year on its own is a date, and a date names a performance")
    func datedTakesStayApart() {
        // How a great many live libraries are tagged. Folding these would
        // lose every performance but one.
        #expect(
            DuplicateSongs.key(for: "Whipping Post (1971)")
                != DuplicateSongs.key(for: "Whipping Post (1973)")
        )
        #expect(
            DuplicateSongs.key(for: "Dark Star (Live) (1972)")
                != DuplicateSongs.key(for: "Dark Star (Live) (1977)")
        )
        #expect(
            DuplicateSongs.key(for: "Essential Mix - 1998-05-31")
                != DuplicateSongs.key(for: "Essential Mix - 2002-11-17")
        )
        // A year beside a word that *is* noise still says nothing.
        #expect(
            DuplicateSongs.key(for: "Whipping Post (1971 Remaster)")
                == DuplicateSongs.key(for: "Whipping Post")
        )
    }

    @Test("Every number that is not a year means something")
    func numbersAreNotNoise() {
        let plain = DuplicateSongs.key(for: "Relax")
        // The single mixes, which only look like edition words once their
        // digits have been thrown away.
        #expect(DuplicateSongs.key(for: "Relax (12\" Version)") != plain)
        #expect(DuplicateSongs.key(for: "Relax - 7\" Mix") != plain)
        #expect(DuplicateSongs.key(for: "Relax (12 Inch Version)") != plain)
        // Takes and parts, with or without the word.
        #expect(DuplicateSongs.key(for: "Blue Monk (1)") != DuplicateSongs.key(for: "Blue Monk (2)"))
        #expect(DuplicateSongs.key(for: "Blue Monk (Take 1)") != DuplicateSongs.key(for: "Blue Monk (Take 2)"))
    }

    @Test("A guest credit is a credit, not a different recording")
    func creditsFold() {
        let plain = DuplicateSongs.key(for: "Under Pressure")
        #expect(DuplicateSongs.key(for: "Under Pressure (feat. David Bowie)") == plain)
        #expect(DuplicateSongs.key(for: "Under Pressure - featuring David Bowie") == plain)
        #expect(DuplicateSongs.key(for: "Under Pressure [ft. David Bowie]") == plain)
    }

    @Test("\"With\" is left alone, because it also names a different recording")
    func withIsNotACredit() {
        // The whole qualifier is thrown away unread, so there is no length
        // of detail that could save an orchestral re-recording. Better an
        // extra row than a missing song.
        #expect(
            DuplicateSongs.key(for: "Wichita Lineman (with the Royal Philharmonic Orchestra)")
                != DuplicateSongs.key(for: "Wichita Lineman")
        )
    }

    @Test("A different performance stays a different song")
    func performancesStayApart() {
        let plain = DuplicateSongs.key(for: "Marquee Moon")
        for spelling in [
            "Marquee Moon (Live)",
            "Marquee Moon (Live at the Old Waldorf)",
            "Marquee Moon - Live",
            "Marquee Moon (Acoustic)",
            "Marquee Moon (Demo)",
            "Marquee Moon (Radio Edit)",
            "Marquee Moon (Instrumental)",
            "Marquee Moon (Club Mix)",
            "Marquee Moon (Extended Version)",
            "Marquee Moon (1977)",
            "Marquee Moon (Live) (Remastered)",
        ] {
            #expect(DuplicateSongs.key(for: spelling) != plain, "\(spelling)")
        }
    }

    @Test("Peeling stops at the first thing that means something")
    func peelingStopsAtMeaning() {
        // The remaster comes off; the live take does not, so this is still
        // the live recording and not the studio one.
        #expect(
            DuplicateSongs.key(for: "Marquee Moon (Live) (Remastered)")
                == DuplicateSongs.key(for: "Marquee Moon (Live)")
        )
    }

    @Test("Apostrophes and accents do not make two songs")
    func punctuationFolds() {
        #expect(DuplicateSongs.key(for: "Don't Stop") == DuplicateSongs.key(for: "Don’t Stop"))
        #expect(DuplicateSongs.key(for: "Café Bleu") == DuplicateSongs.key(for: "Cafe Bleu"))
    }

    @Test("A hyphen inside a word is not a qualifier")
    func hyphenatedWordsSurvive() {
        #expect(DuplicateSongs.key(for: "Re-Do") == "re do")
        #expect(DuplicateSongs.key(for: "Song - Part Two") == "song part two")
    }

    @Test("A title with nothing in it cannot be spoken for")
    func emptyTitleHasNoKey() {
        #expect(DuplicateSongs.key(for: "   ").isEmpty)
        #expect(DuplicateSongs.key(for: "!!!") .isEmpty)
    }

    // MARK: Which copy is kept

    @Test("Duplicates collapse and the order is kept")
    func duplicatesCollapse() {
        let pruned = DuplicateSongs.pruned([
            copy("a", "Marquee Moon", rating: 5),
            copy("b", "Venus", rating: 4),
            copy("c", "Marquee Moon (2003 Remaster)", rating: 5, collection: true),
        ])
        #expect(pruned.map(\.title) == ["Marquee Moon", "Venus"])
    }

    @Test("The listener's own rating decides first")
    func theBestRatingWins() {
        let pruned = DuplicateSongs.pruned([
            // Comes second in the list but is the one the listener rated up.
            copy("album", "Marquee Moon", rating: 3),
            copy("hits", "Marquee Moon", rating: 5, collection: true),
        ])
        #expect(pruned.map(\.id.rawValue) == ["hits"])
    }

    @Test("Otherwise the record beats the collection")
    func theRecordBeatsTheCollection() {
        let pruned = DuplicateSongs.pruned([
            copy("hits", "Marquee Moon", rating: 4, collection: true),
            copy("album", "Marquee Moon", rating: 4, collection: false),
        ])
        #expect(pruned.map(\.id.rawValue) == ["album"])
    }

    @Test("Then the first pressing, and a missing year never displaces a known one")
    func theEarlierPressingWins() {
        #expect(
            DuplicateSongs.pruned([
                copy("reissue", "Marquee Moon", rating: 4, year: 2003),
                copy("first", "Marquee Moon", rating: 4, year: 1977),
            ]).map(\.id.rawValue) == ["first"]
        )
        #expect(
            DuplicateSongs.pruned([
                copy("dated", "Marquee Moon", rating: 4, year: 1977),
                copy("undated", "Marquee Moon", rating: 4, year: nil),
            ]).map(\.id.rawValue) == ["dated"]
        )
        #expect(
            DuplicateSongs.pruned([
                copy("undated", "Marquee Moon", rating: 4, year: nil),
                copy("dated", "Marquee Moon", rating: 4, year: 1977),
            ]).map(\.id.rawValue) == ["dated"]
        )
    }

    @Test("Then the copy actually played")
    func thePlayedCopyWins() {
        let pruned = DuplicateSongs.pruned([
            copy("quiet", "Marquee Moon", rating: 4, plays: 0, year: 1977),
            copy("worn", "Marquee Moon", rating: 4, plays: 40, year: 1977),
        ])
        #expect(pruned.map(\.id.rawValue) == ["worn"])
    }

    @Test("A hearted copy beats an unrated one at the same rating")
    func heartsBreakTies() {
        let pruned = DuplicateSongs.pruned([
            copy("plain", "Marquee Moon"),
            copy("hearted", "Marquee Moon", hearted: true),
        ])
        #expect(pruned.map(\.id.rawValue) == ["hearted"])
    }

    @Test("Nothing is left to the order rows came back in")
    func theChoiceIsStable() {
        let one = copy("zz", "Marquee Moon", rating: 4, year: 1977)
        let two = copy("aa", "Marquee Moon", rating: 4, year: 1977)
        #expect(DuplicateSongs.pruned([one, two]).map(\.id.rawValue) == ["aa"])
        #expect(DuplicateSongs.pruned([two, one]).map(\.id.rawValue) == ["aa"])
    }

    @Test("Two different pieces that share a title are told apart by their length")
    func lengthGuardsTheTitle() {
        // "Intro" on two records is two pieces, not one filed twice.
        let short = DuplicateSongs.Copy(
            track: Track(id: id("a"), title: "Intro", duration: 45, rating: StarRating(4))
        )
        let long = DuplicateSongs.Copy(
            track: Track(id: id("b"), title: "Intro", duration: 130, rating: StarRating(4))
        )
        #expect(DuplicateSongs.pruned([short, long]).count == 2)

        // A fade trimmed off the compilation cut is still one recording.
        let album = DuplicateSongs.Copy(
            track: Track(id: id("c"), title: "Venus", duration: 218, rating: StarRating(4))
        )
        let hits = DuplicateSongs.Copy(
            track: Track(id: id("d"), title: "Venus", duration: 214, rating: StarRating(4))
        )
        #expect(DuplicateSongs.pruned([album, hits]).count == 1)
    }

    @Test("An untagged length cannot object")
    func unknownLengthsStillFold() {
        let known = DuplicateSongs.Copy(
            track: Track(id: id("a"), title: "Venus", duration: 218, rating: StarRating(4))
        )
        let unknown = DuplicateSongs.Copy(
            track: Track(id: id("b"), title: "Venus", rating: StarRating(4))
        )
        #expect(DuplicateSongs.pruned([known, unknown]).count == 1)
    }

    @Test("The copy on the phone is the one kept")
    func theDownloadedCopyWins() {
        let streamed = DuplicateSongs.Copy(
            track: Track(id: id("streamed"), title: "Venus", rating: StarRating(4)),
            isFromCollection: false,
            recordYear: 1977
        )
        let kept = DuplicateSongs.Copy(
            track: Track(id: id("kept"), title: "Venus", rating: StarRating(4)),
            isFromCollection: true,
            recordYear: 2003,
            isDownloaded: true
        )
        // Beats even the artist's own first pressing: a shelf that needs the
        // network to play a downloaded song is the worse answer.
        #expect(DuplicateSongs.pruned([streamed, kept]).map(\.id.rawValue) == ["kept"])
    }

    @Test("Songs that cannot be keyed are all shown")
    func unkeyableSongsSurvive() {
        let pruned = DuplicateSongs.pruned([
            copy("a", "!!!"),
            copy("b", "???"),
        ])
        #expect(pruned.count == 2)
    }

    @Test("The album-name reading of a collection, for callers without the record")
    func trackOnlyPruningReadsTheAlbumName() {
        let pruned = DuplicateSongs.pruned([
            Track(id: id("hits"), title: "Marquee Moon", albumName: "Greatest Hits", rating: StarRating(4)),
            Track(id: id("album"), title: "Marquee Moon", albumName: "Marquee Moon", rating: StarRating(4)),
        ])
        #expect(pruned.map(\.id.rawValue) == ["album"])
    }
}
