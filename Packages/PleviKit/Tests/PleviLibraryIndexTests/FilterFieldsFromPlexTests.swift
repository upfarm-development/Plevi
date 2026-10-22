import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The fields Plex offers in its own smart-playlist editor that this app did
/// not, and the one that was being offered to servers that cannot answer it.
@Suite("Catching up with Plex's own filter list")
struct FilterFieldsFromPlexTests {
    @Test("A record's release date can be asked about, not only its year")
    func releaseDateIsOffered() {
        // The column has been there and filled since the shelf that reads it
        // was written; only the rule was missing.
        #expect(FilterField.fields(for: .songs).contains(.albumReleaseDate))
        #expect(FilterField.fields(for: .albums).contains(.albumReleaseDate))
        #expect(!FilterField.fields(for: .artists).contains(.albumReleaseDate))
        #expect(FilterField.albumReleaseDate.kind == .date)
    }

    @Test("A decade is one rule rather than two")
    func decadeIsOffered() {
        #expect(FilterField.fields(for: .albums).contains(.albumDecade))
        #expect(FilterField.albumDecade.kind == .number)
    }

    @Test("An artist can be asked what their records are filed under")
    func artistsHaveGenresNow() {
        let fields = FilterField.fields(for: .artists)
        #expect(fields.contains(.artistGenre))
        // Only the questions that make sense of a run of them — the same
        // rule playlist names follow, and the reason this is its own field
        // rather than `genre` stretched to cover artists.
        #expect(FilterOperator.operators(for: .artistGenre) == [.contains, .doesNotContain])
        #expect(!FilterField.fields(for: .songs).contains(.artistGenre))
        #expect(!FilterField.fields(for: .albums).contains(.artistGenre))
    }

    @Test("An artist has a date added and a last played, off their records")
    func artistsHaveDatesNow() {
        let fields = FilterField.fields(for: .artists)
        #expect(fields.contains(.dateAdded))
        #expect(fields.contains(.lastPlayed))
        #expect(FilterField.dateAdded.title(for: .artists) == "Artist date added")
        #expect(FilterField.lastPlayed.title(for: .artists) == "Artist last played")
        // Still the record's on the other two subjects.
        #expect(FilterField.dateAdded.title(for: .songs) == "Album date added")
        #expect(FilterField.lastPlayed.title(for: .albums) == "Album last played")
    }

    @Test("A rule about the artist's records compiles to a subquery, not a column")
    func artistRulesReachTheirRecords() {
        for (field, fragment) in [
            (FilterField.artistGenre, "album.genre"),
            (.dateAdded, "MIN(album.addedAt)"),
            (.lastPlayed, "MAX(album.playedAt)"),
        ] {
            let filter = LibraryFilter(
                subject: .artists,
                root: FilterGroup(children: [
                    .rule(FilterRule(field: field, op: .isSet)),
                ])
            )
            let sql = filter.compile().sql
            #expect(sql.contains(fragment), "\(field.rawValue): \(sql)")
            #expect(sql.contains("album.artistId = artist.id"), "\(field.rawValue)")
        }
    }

    @Test("A record with no year is not a record from the year nought")
    func decadeDoesNotInventTheFirstDecade() {
        let filter = LibraryFilter(
            subject: .albums,
            root: FilterGroup(children: [
                .rule(FilterRule(field: .albumDecade, op: .equals, value: .number(1980))),
            ])
        )
        // Servers store a missing year as zero as often as as null, and
        // (0 / 10) * 10 is a perfectly good nought.
        #expect(filter.compile().sql.contains("NULLIF"))
    }

    @Test("A field its server cannot answer is not offered")
    func theCriticsScoreIsPlexOnly() {
        // Offered to everyone until now: a Navidrome sync never fills that
        // column, so the rule was accepted and the shelf was empty for ever
        // with nothing to say why.
        let plex = ServerCapabilities.criticRatings
        let navidrome = ServerCapabilities()
        #expect(FilterField.fields(for: .albums, on: plex).contains(.criticRating))
        #expect(!FilterField.fields(for: .albums, on: navidrome).contains(.criticRating))
        // And nothing else is gated, because nothing else differs: every
        // other field is answered out of the local index from data both
        // backends supply.
        let onlyDifference = Set(FilterField.fields(for: .songs, on: plex))
            .subtracting(FilterField.fields(for: .songs, on: navidrome))
        #expect(onlyDifference == [.criticRating])
    }
}
