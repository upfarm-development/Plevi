import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// A broad search on a big library.
@Suite("Search on a library too big for one pool")
struct SearchPoolScaleTests {
    private let server = ServerID()

    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// 1,200 artists, 1,200 albums and 2,500 songs whose names all contain
    /// "the", with the song that is exactly called "The" written last.
    private func bigIndex() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        let artists = (0..<1_200).map { Artist(id: id("ar\($0)"), name: "The Artist \($0)") }
        let albums = (0..<1_200).map {
            Album(id: id("al\($0)"), name: "The Album \($0)", artistName: "The Artist \($0)", artistID: id("ar\($0)"))
        }
        var tracks = (0..<2_500).map {
            Track(
                id: id("t\($0)"), title: "The Song \($0)",
                albumID: id("al\($0 % 1_200)"), artistName: "The Artist \($0 % 1_200)",
                artistID: id("ar\($0 % 1_200)")
            )
        }
        tracks.append(Track(id: id("exact"), title: "The", albumID: id("al0"), artistID: id("ar0")))
        try index.upsertArtists(artists, generation: 1)
        try index.upsertAlbums(albums, generation: 1)
        try index.upsertTracks(tracks, generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("Songs are found when far more artists and albums match than one pool held")
    func songsSurviveManyArtists() throws {
        let index = try bigIndex()
        let results = try index.search("the", limit: 60)
        #expect(results.artists.count == 60)
        #expect(results.albums.count == 60)
        #expect(results.tracks.count == 60)
        // The song called exactly this ranks first, though it was inserted
        // after 2,500 others and 2,400 rows of other kinds.
        #expect(results.tracks.first?.title == "The")
    }

    @Test("Offline, every downloaded match is returned however many others there are")
    func offlineMatchesAreNotCutFirst() throws {
        let index = try bigIndex()
        // Five downloads, all late in the table.
        let downloaded = ["t2490", "t2491", "t2492", "t2493", "t2494"]
        for track in downloaded {
            try index.saveDownload(DownloadRecord(trackId: track, state: .done, fileName: "\(track).mp3"))
        }
        // A queued one is not downloaded.
        try index.saveDownload(DownloadRecord(trackId: "t2495", state: .queued, fileName: nil))

        let results = try index.search("the", limit: 60, downloadedOnly: true)
        #expect(Set(results.tracks.map(\.id.rawValue)) == Set(downloaded))
        // Their albums and artists come with them, and nothing else does.
        let albumIDs = Set(downloaded.compactMap { Int($0.dropFirst()) }.map { "al\($0 % 1_200)" })
        let artistIDs = Set(downloaded.compactMap { Int($0.dropFirst()) }.map { "ar\($0 % 1_200)" })
        #expect(Set(results.albums.map(\.id.rawValue)) == albumIDs)
        #expect(Set(results.artists.map(\.id.rawValue)) == artistIDs)
    }

    @Test("Offline with nothing downloaded finds nothing")
    func offlineWithNothingDownloaded() throws {
        let index = try bigIndex()
        let results = try index.search("the", limit: 60, downloadedOnly: true)
        #expect(results.tracks.isEmpty)
        #expect(results.albums.isEmpty)
        #expect(results.artists.isEmpty)
    }

    @Test("The one- and two-letter path gets a pool per kind as well")
    func shortQueryPoolsPerKind() throws {
        let index = try bigIndex()
        let results = try index.search("th", limit: 60)
        #expect(results.tracks.count == 60)
        #expect(results.albums.count == 60)
        #expect(results.artists.count == 60)
        #expect(results.tracks.first?.title == "The")
    }
}
