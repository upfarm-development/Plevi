import Foundation
import Testing
@testable import PleviDomain

/// Which year a song is filed under, and why.
@Suite("Track era")
struct TrackEraTests {
    // MARK: The precedence chain

    @Test("A song's own original tag beats everything else")
    func trackTagWins() {
        let era = TrackEra.resolve(
            TrackEra.Signals(
                trackOriginalYear: 1972,
                albumOriginalYear: 2011,
                albumYear: 2011,
                trackYear: 2011,
                isCompilation: true,
                artistEstimate: 1990
            )
        )
        #expect(era.year == 1972)
        #expect(era.source == .trackTag)
        #expect(era.decade == 1970)
        #expect(!era.isLowConfidence)
    }

    @Test("A reissue is dated by its original release, not its pressing")
    func albumOriginalDate() {
        let era = TrackEra.resolve(
            TrackEra.Signals(albumOriginalYear: 1966, albumYear: 2015, isCompilation: false)
        )
        #expect(era.year == 1966)
        #expect(era.source == .albumOriginalDate)
    }

    @Test("An original date equal to the filed year is not evidence of anything")
    func matchingOriginalDateIsIgnored() {
        // Both fields say 2011 — the server knows of no reissue, so this is
        // the same fact written twice and cannot rescue a compilation.
        let era = TrackEra.resolve(
            TrackEra.Signals(
                albumOriginalYear: 2011,
                albumYear: 2011,
                isCompilation: true,
                artistEstimate: 1975
            )
        )
        #expect(era.year == 1975)
        #expect(era.source == .artistEstimate)
    }

    @Test("A compilation with no original date falls to the artist's own era")
    func compilationUsesArtistEstimate() {
        let era = TrackEra.resolve(
            TrackEra.Signals(albumYear: 2010, isCompilation: true, artistEstimate: 1974)
        )
        #expect(era.year == 1974)
        #expect(era.source == .artistEstimate)
        #expect(era.decade == 1970)
        #expect(!era.isLowConfidence)
    }

    @Test("A compilation by an artist we know nothing else about is low confidence")
    func compilationWithUnknownArtist() {
        let era = TrackEra.resolve(
            TrackEra.Signals(albumYear: 2010, isCompilation: true, artistEstimate: nil)
        )
        // The year is handed back, but flagged: it is the pressing year, and
        // the caller is expected to decide whether that is good enough.
        #expect(era.year == 2010)
        #expect(era.isLowConfidence)
    }

    @Test("An ordinary album is dated by its year")
    func plainAlbum() {
        let era = TrackEra.resolve(TrackEra.Signals(albumYear: 1994, isCompilation: false))
        #expect(era.year == 1994)
        #expect(era.source == .albumYear)
        #expect(!era.isLowConfidence)
    }

    @Test("A song's own year is preferred to its record's")
    func trackYearBeatsAlbumYear() {
        let era = TrackEra.resolve(
            TrackEra.Signals(albumYear: 1994, trackYear: 1991, isCompilation: false)
        )
        #expect(era.year == 1991)
    }

    @Test("Nothing known at all resolves to nothing")
    func unresolvable() {
        let era = TrackEra.resolve(TrackEra.Signals())
        #expect(era.year == nil)
        #expect(era.decade == nil)
        #expect(era.source == nil)
    }

    @Test("A decade is the ten years starting at its own zero")
    func decadeBucketing() {
        #expect(TrackEra.resolve(TrackEra.Signals(albumYear: 1970)).decade == 1970)
        #expect(TrackEra.resolve(TrackEra.Signals(albumYear: 1979)).decade == 1970)
        #expect(TrackEra.resolve(TrackEra.Signals(albumYear: 1980)).decade == 1980)
        #expect(TrackEra.resolve(TrackEra.Signals(albumYear: 2000)).decade == 2000)
    }
}

/// What counts as a collection rather than a record.
@Suite("Compilation heuristics")
struct CompilationHeuristicsTests {
    @Test("The server's own flag is taken at its word")
    func serverFlag() {
        #expect(CompilationHeuristics.isCompilation(serverFlag: true))
    }

    @Test("A various-artists credit is a compilation whatever the server said")
    func variousArtists() {
        #expect(CompilationHeuristics.isVariousArtists("Various Artists"))
        #expect(CompilationHeuristics.isVariousArtists("various artists"))
        #expect(CompilationHeuristics.isVariousArtists("  VA "))
        #expect(CompilationHeuristics.isVariousArtists("Verschiedene Interpreten"))
        // Not a substring test: this is a real band.
        #expect(!CompilationHeuristics.isVariousArtists("Various Production"))
        #expect(!CompilationHeuristics.isVariousArtists("Pink Floyd"))
    }

    @Test("Titles that name a kind of collection")
    func collectionTitles() {
        #expect(CompilationHeuristics.titleSuggestsCollection("Greatest Hits"))
        #expect(CompilationHeuristics.titleSuggestsCollection("The Best of Fleetwood Mac"))
        #expect(CompilationHeuristics.titleSuggestsCollection("NOW That's What I Call Music! 101"))
        #expect(CompilationHeuristics.titleSuggestsCollection("Anthology"))
        #expect(CompilationHeuristics.titleSuggestsCollection("The Ultimate Collection"))
        // An ordinary record is not one.
        #expect(!CompilationHeuristics.titleSuggestsCollection("Rumours"))
        #expect(!CompilationHeuristics.titleSuggestsCollection("The Dark Side of the Moon"))
    }

    @Test("Titles that name a decade")
    func decadeTitles() {
        #expect(CompilationHeuristics.titleSuggestsCollection("70s Soul Classics"))
        #expect(CompilationHeuristics.titleSuggestsCollection("1970s Disco"))
        #expect(CompilationHeuristics.titleSuggestsCollection("Hits of the '80s"))
        // A year is not a decade, and a catalogue number is neither.
        #expect(!CompilationHeuristics.titleSuggestsCollection("1971"))
        #expect(!CompilationHeuristics.titleSuggestsCollection("Catalogue 4780"))
    }

    @Test("A plain album by a real artist is left alone")
    func plainAlbumIsNotACompilation() {
        #expect(!CompilationHeuristics.isCompilation(
            serverFlag: false,
            releaseTypes: [.album],
            albumTitle: "Rumours",
            albumArtist: "Fleetwood Mac"
        ))
    }

    @Test("A compilation release type counts even with no flag")
    func releaseTypeCounts() {
        #expect(CompilationHeuristics.isCompilation(
            serverFlag: false,
            releaseTypes: [.album, .compilation],
            albumTitle: "Odd Title",
            albumArtist: "Someone"
        ))
    }
}
