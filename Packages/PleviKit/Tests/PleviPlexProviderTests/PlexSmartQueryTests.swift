import Foundation
import Testing
import PleviDomain
@testable import PleviPlexProvider

@Suite("Writing a filter the way Plex writes one")
struct PlexSmartQueryTests {
    private func items(_ query: SmartQuery) -> [String] {
        (PlexSmartQuery.queryItems(for: query) ?? []).map { "\($0.name)=\($0.value ?? "")" }
    }

    @Test("Songs and albums are different kinds of thing")
    func kinds() {
        #expect(PlexSmartQuery.type(for: .songs) == 10)
        #expect(PlexSmartQuery.type(for: .albums) == 9)
    }

    @Test("Stars become Plex's marks out of ten")
    func ratingScale() {
        // The app counts in stars out of five and the server out of ten, so a
        // rule about four stars asked for eight would quietly fetch the
        // two-star songs.
        let query = SmartQuery(subject: .songs, matchesAll: true, rules: [
            SmartRule(field: .rating, comparison: .atLeast, value: .stars(4)),
        ])
        #expect(items(query) == ["type=10", "userRating>>==8"])
    }

    @Test("Half a star survives the trip")
    func halfStars() {
        let query = SmartQuery(subject: .songs, matchesAll: true, rules: [
            SmartRule(field: .rating, comparison: .atLeast, value: .stars(2.5)),
        ])
        #expect(items(query).contains("userRating>>==5"))
    }

    @Test("In the last so many days is a negative period")
    func relativeDates() {
        let query = SmartQuery(subject: .songs, matchesAll: true, rules: [
            SmartRule(field: .dateAdded, comparison: .inTheLastDays, value: .days(30)),
        ])
        #expect(items(query) == ["type=10", "addedAt>>==-30d"])
    }

    @Test("Any of these joins the rules with an or, all of these does not")
    func matching() {
        let rules = [
            SmartRule(field: .genre, comparison: .isExactly, value: .text("Jazz")),
            SmartRule(field: .genre, comparison: .isExactly, value: .text("Blues")),
        ]
        let any = items(SmartQuery(subject: .songs, matchesAll: false, rules: rules))
        // Rendered as name=value here, and the name itself ends in the
        // operator — so "genre=" plus "Jazz" reads as genre==Jazz.
        #expect(any == ["type=10", "genre==Jazz", "or=1", "genre==Blues"])

        let all = items(SmartQuery(subject: .songs, matchesAll: true, rules: rules))
        #expect(!all.contains("or=1"))
    }

    @Test("A song is filed under its album, an album is not")
    func albumNameOnlyMakesSenseForSongs() {
        let rule = SmartRule(field: .albumName, comparison: .contains, value: .text("Blue"))
        #expect(PlexSmartQuery.name(for: .albumName, subject: .songs) == "album.title")
        #expect(PlexSmartQuery.name(for: .albumName, subject: .albums) == nil)
        // And a query that cannot be written comes back as nothing rather
        // than as a query missing one of its rules.
        #expect(PlexSmartQuery.queryItems(
            for: SmartQuery(subject: .albums, matchesAll: true, rules: [rule])
        ) == nil)
    }

    @Test("Whole numbers do not arrive with a decimal point")
    func numberFormatting() {
        let query = SmartQuery(subject: .albums, matchesAll: true, rules: [
            SmartRule(field: .year, comparison: .atLeast, value: .number(1974)),
        ])
        #expect(items(query).contains("year>>==1974"))
    }

    /// UNVERIFIED against a live Plex server (settings-filters-07).
    @Test("Text comparisons are pinned as they are written today")
    func textOperatorsPinned() {
        func written(_ comparison: SmartRule.Comparison) -> [String] {
            items(SmartQuery(subject: .songs, matchesAll: true, rules: [
                SmartRule(field: .title, comparison: comparison, value: .text("Yellow")),
            ]))
        }
        #expect(written(.isExactly) == ["type=10", "title==Yellow"])
        #expect(written(.contains) == ["type=10", "title==Yellow"])
        #expect(written(.isNot) == ["type=10", "title!==Yellow"])
        #expect(written(.doesNotContain) == ["type=10", "title!==Yellow"])
    }
}
