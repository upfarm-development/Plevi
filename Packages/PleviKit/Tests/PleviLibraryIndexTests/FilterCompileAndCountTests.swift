import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// How a filter compiles when parts of it say nothing, and what the counts
/// under the filter sheet are counting.
@Suite("Filter compile and counts")
struct FilterCompileAndCountTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded(artists artistCount: Int = 3) throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists((0..<artistCount).map {
            Artist(id: id("ar\($0)"), name: "Artist \($0)", albumCount: 1)
        }, generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Fav", artistName: "Artist 0", artistID: id("ar0"),
                  year: 1974, genre: "Folk", isFavorite: true),
            Album(id: id("al2"), name: "Plain", artistName: "Artist 1", artistID: id("ar1"),
                  year: 1994, genre: "Jazz"),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "One", albumName: "Fav", albumID: id("al1"),
                  artistName: "Artist 0", artistID: id("ar0"), codec: "flac"),
            Track(id: id("t2"), title: "Two", albumName: "Plain", albumID: id("al2"),
                  artistName: "Artist 1", artistID: id("ar1"), codec: "mp3"),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    private func rule(_ field: FilterField, _ op: FilterOperator, _ value: FilterValue = .none) -> FilterNode {
        .rule(FilterRule(field: field, op: op, value: value))
    }

    // MARK: settings-filters-11

    @Test("A blank rule inside an 'any' sub-group does not make the parent match everything")
    func blankSubGroupIsLeftOut() throws {
        let index = try seeded()
        let filter = LibraryFilter(subject: .songs, root: FilterGroup(match: .any, children: [
            rule(.codec, .matches, .text("flac")),
            .group(FilterGroup(match: .all, children: [rule(.title, .contains, .text("   "))])),
        ]))
        #expect(try index.tracks(matching: filter).map(\.title) == ["One"])
        #expect(try index.count(matching: filter) == 1)
    }

    @Test("A sub-group that says nothing at all leaves an 'all' parent alone")
    func blankSubGroupInAll() throws {
        let index = try seeded()
        let filter = LibraryFilter(subject: .songs, root: FilterGroup(match: .all, children: [
            rule(.codec, .matches, .text("mp3")),
            .group(FilterGroup(match: .any, children: [rule(.title, .contains, .text(""))])),
        ]))
        #expect(try index.count(matching: filter) == 1)
    }

    @Test("A filter of only blank rules is still the whole library")
    func allBlankIsEverything() throws {
        let index = try seeded()
        let filter = LibraryFilter(subject: .songs, root: FilterGroup(children: [
            .group(FilterGroup(children: [rule(.title, .contains, .text(" "))])),
        ]))
        #expect(try index.count(matching: filter) == 2)
    }

    @Test("An 'any' filter offline is bounded to what is downloaded")
    func anyRootRespectsDownloadedOnly() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t2", state: .done, fileName: "b.mp3"))
        let filter = LibraryFilter(subject: .songs, root: FilterGroup(match: .any, children: [
            rule(.codec, .matches, .text("flac")),
            rule(.codec, .matches, .text("mp3")),
        ]))
        #expect(try index.tracks(matching: filter, downloadedOnly: true).map(\.title) == ["Two"])
        #expect(try index.count(matching: filter, downloadedOnly: true) == 1)
    }

    @Test("A record's play count has no 'is set' question, like a song's")
    func albumPlayCountOperators() {
        #expect(!FilterOperator.operators(for: .albumPlayCount).contains(.isSet))
        #expect(!FilterOperator.operators(for: .albumPlayCount).contains(.isNotSet))
        #expect(FilterOperator.operators(for: .albumPlayCount).contains(.atLeast))
    }

    // MARK: settings-filters-05 / network-offline-29

    @Test("A filtered artist list is not cut at 500")
    func artistsFilterNotCapped() throws {
        let index = try seeded(artists: 650)
        let all = LibraryFilter(subject: .artists, root: FilterGroup(children: [
            rule(.favourite, .isFalse),
        ]))
        let count = try index.count(matching: all)
        #expect(count == 650)
        #expect(try index.artists(matching: all).count == 650)
        #expect(try index.artists(matching: all, limit: 10).count == 10)
    }

    @Test("Offline, a filtered artist list leaves out artists with nothing downloaded")
    func artistsFilterOffline() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done, fileName: "a.flac"))
        let all = LibraryFilter(subject: .artists, root: FilterGroup(children: [
            rule(.favourite, .isFalse),
        ]))
        #expect(try index.artists(matching: all, downloadedOnly: true).map(\.name) == ["Artist 0"])
        #expect(try index.count(matching: all, downloadedOnly: true) == 1)
        #expect(try index.count(matching: all) == 3)
    }

    // MARK: settings-filters-12

    @Test("An album filter's count can be scoped to the page it filters")
    func albumCountScopedToPage() throws {
        let index = try seeded()
        let anyYear = LibraryFilter(subject: .albums, root: FilterGroup(children: [
            rule(.year, .atLeast, .number(1900)),
        ]))
        #expect(try index.count(matching: anyYear) == 2)
        #expect(try index.count(matching: anyYear, page: .favorites) == 1)
        #expect(try index.count(matching: anyYear, within: [id("al2")]) == 1)
        #expect(try index.count(matching: anyYear, within: []) == 0)
    }

    // MARK: settings-filters-13

    @Test("A span typed as a huge count is clamped, not trapped on")
    func spanIsClamped() throws {
        let huge = FilterValue.days(count: Int.max, unit: .years)
        guard case .days(let days) = huge else { Issue.record("not days"); return }
        #expect(days <= FilterValue.maximumDays)
        #expect(FilterValue.days(count: -5, unit: .weeks) == .days(0))
        #expect(FilterValue.days(count: 3, unit: .months) == .days(90))
        // And a rule that already holds an absurd number still compiles and runs.
        let index = try seeded()
        let filter = LibraryFilter(subject: .songs, root: FilterGroup(children: [
            rule(.lastPlayed, .notInTheLast, .days(Int.max)),
        ]))
        #expect(try index.count(matching: filter) == 2)
    }

    // MARK: perf-scale-07 / perf-scale-11

    @Test("hasGenres agrees with genres().isEmpty")
    func hasGenresMatches() throws {
        let index = try seeded()
        #expect(try index.hasGenres() == !(try index.genres().isEmpty))
        #expect(try index.hasGenres() == false)
        try index.upsertTracks([
            Track(id: id("t9"), title: "Nine", albumID: id("al1"), genre: "Folk"),
        ], generation: 2)
        #expect(try index.hasGenres() == true)
        #expect(try index.hasGenres() == !(try index.genres().isEmpty))
    }

    @Test("Artist genre tags are cached until the albums change")
    func genreTagsCached() throws {
        let index = try seeded()
        let first = try index.cachedGenreTagsByArtist()
        #expect(first["artist 0"] == ["Folk"])
        try index.upsertAlbums([
            Album(id: id("al3"), name: "New", artistName: "Artist 0", artistID: id("ar0"), genre: "Jazz"),
        ], generation: 2)
        #expect(try index.cachedGenreTagsByArtist()["artist 0"] == ["Folk", "Jazz"])
        #expect(try index.cachedGenreTagsByArtist() == (try index.genreTagsByArtist()))
    }

    // MARK: settings-filters-07

    @Test("'Not played in the last N days' is refused as a smart playlist, 'added in the last' is not")
    func neverPlayedNotCarriedAcross() {
        let notPlayed = LibraryFilter(subject: .songs, root: FilterGroup(children: [
            rule(.lastPlayed, .notInTheLast, .days(365)),
        ]))
        guard case .failure(.unsupportedTest) = notPlayed.smartQuery() else {
            Issue.record("should be refused")
            return
        }
        let recent = LibraryFilter(subject: .songs, root: FilterGroup(children: [
            rule(.dateAdded, .inTheLast, .days(30)),
        ]))
        guard case .success = recent.smartQuery() else {
            Issue.record("should be carried across")
            return
        }
    }
}
