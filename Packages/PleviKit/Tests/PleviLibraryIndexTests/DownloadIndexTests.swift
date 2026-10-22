import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// What the index remembers about downloads, and what a download request
/// expands to.
@Suite("Downloads in the index")
struct DownloadIndexTests {
    private let server = ServerID()

    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        let artist = id("ar1")
        try index.upsertArtists([Artist(id: artist, name: "Aurora Skies")], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Daybreak", artistName: "Aurora Skies", artistID: artist),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t2"), title: "Second", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist, trackNumber: 2, discNumber: 1),
            Track(id: id("t1"), title: "First", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist, trackNumber: 1, discNumber: 1),
            Track(id: id("t3"), title: "Elsewhere", albumName: "Nightfall", albumID: id("al2"),
                  artistName: "Aurora Skies", artistID: artist, trackNumber: 1, discNumber: 1),
        ], generation: 1)
        try index.finishSync(generation: 1)
        return index
    }

    @Test("A download survives a round trip, reasons and all")
    func roundTrip() throws {
        let index = try seeded()
        let record = DownloadRecord(
            trackId: "t1",
            state: .done,
            fileName: "abc-orig.flac",
            bytes: 1024,
            expectedBytes: 1024,
            addedAt: Date(timeIntervalSince1970: 100),
            requestedBy: ["album:al1", "track:t1"]
        )
        try index.saveDownload(record)

        let read = try #require(try index.download(forTrack: id("t1")))
        #expect(read.state == .done)
        #expect(read.fileName == "abc-orig.flac")
        #expect(read.bytes == 1024)
        #expect(read.reasons == ["album:al1", "track:t1"])
    }

    @Test("Saving again replaces rather than duplicates")
    func upsert() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .queued))
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done, fileName: "x.flac"))
        #expect(try index.downloads().count == 1)
        #expect(try index.download(forTrack: id("t1"))?.state == .done)
    }

    @Test("Removing one leaves the others")
    func delete() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done))
        try index.saveDownload(DownloadRecord(trackId: "t2", state: .done))
        try index.deleteDownload(forTrack: id("t1"))
        #expect(try index.downloads().map(\.trackId) == ["t2"])
    }

    @Test("An album expands to its tracks in playing order")
    func albumExpansion() throws {
        let index = try seeded()
        #expect(try index.tracks(inAlbum: id("al1")).map(\.title) == ["First", "Second"])
    }

    @Test("An artist expands to everything of theirs")
    func artistExpansion() throws {
        let index = try seeded()
        let tracks = try index.tracks(byArtist: id("ar1")).map(\.id.rawValue)
        #expect(Set(tracks) == ["t1", "t2", "t3"])
        // Album by album, and in order within each.
        #expect(tracks.firstIndex(of: "t1")! < tracks.firstIndex(of: "t2")!)
    }

    @Test("A sync that removes tracks does not remove what was downloaded")
    func syncKeepsDownloads() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done, fileName: "x.flac"))
        // A generation that reports nothing at all: every track row goes.
        _ = try index.beginSyncGeneration()
        try index.finishSync(generation: 2)
        #expect(try index.download(forTrack: id("t1"))?.fileName == "x.flac")
    }

    // MARK: Keeping what is downloaded current

    @Test("Albums with a finished download and no review are the ones asked about")
    func downloadedAlbumsLackingNotes() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done))
        try index.saveDownload(DownloadRecord(trackId: "t3", state: .done))
        // Not finished, so not yet a reason to ask.
        try index.saveDownload(DownloadRecord(trackId: "t2", state: .queued))

        let anytime = Date().addingTimeInterval(60)
        #expect(Set(try index.downloadedAlbumsLackingNotes(checkedBefore: anytime).map(\.rawValue)) == ["al1", "al2"])

        try index.storeAlbumNotes("A quiet record.", forAlbum: id("al1"))
        #expect(try index.downloadedAlbumsLackingNotes(checkedBefore: anytime).map(\.rawValue) == ["al2"])

        // Asked and nothing there: left alone until the recheck date passes,
        // and still reads as having no review.
        try index.noteAlbumHasNoNotes(forAlbum: id("al2"))
        #expect(try index.albumNotes(forAlbum: id("al2")) == nil)
        #expect(try index.downloadedAlbumsLackingNotes(checkedBefore: Date().addingTimeInterval(-60)).isEmpty)
        #expect(try index.downloadedAlbumsLackingNotes(checkedBefore: anytime).map(\.rawValue) == ["al2"])

        // A review that turns up later is kept over the empty answer, and
        // noting "nothing there" never takes one away.
        try index.storeAlbumNotes("Now there is one.", forAlbum: id("al2"))
        try index.noteAlbumHasNoNotes(forAlbum: id("al2"))
        #expect(try index.albumNotes(forAlbum: id("al2")) == "Now there is one.")
        #expect(try index.downloadedAlbumsLackingNotes(checkedBefore: anytime).isEmpty)
    }

    @Test("A download row follows the library's title and cover, and only those columns")
    func downloadDetailsFollowTheLibrary() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(
            trackId: "t1", state: .running, fileName: "f.flac", bytes: 10,
            title: "Old Title", artistName: "Aurora Skies", albumName: "Daybreak",
            artworkId: "cover-v1", duration: 100
        ))
        // The library has no record of this one: its row is left as it is.
        try index.saveDownload(DownloadRecord(
            trackId: "gone", state: .done, title: "Kept Name", artworkId: "kept-cover"
        ))

        let artist = id("ar1")
        try index.upsertTracks([
            Track(id: id("t1"), title: "First", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: artist, trackNumber: 1, discNumber: 1,
                  duration: 101, artwork: ArtworkID(server: server, rawValue: "cover-v2")),
        ], generation: 2)

        #expect(try index.refreshDownloadDetailsFromLibrary() == 1)
        let row = try #require(try index.download(forTrack: id("t1")))
        #expect(row.title == "First")
        #expect(row.artworkId == "cover-v2")
        #expect(row.duration == 101)
        // Nothing about the transfer moved.
        #expect(row.state == .running)
        #expect(row.fileName == "f.flac")
        #expect(row.bytes == 10)

        let kept = try #require(try index.download(forTrack: id("gone")))
        #expect(kept.title == "Kept Name")
        #expect(kept.artworkId == "kept-cover")

        // Already current: nothing to do.
        #expect(try index.refreshDownloadDetailsFromLibrary() == 0)
    }

    @Test("A library song without a cover does not blank the one the row has")
    func missingCoverIsNotBlanked() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(
            trackId: "t1", state: .done, title: "First", artistName: "Aurora Skies",
            albumName: "Daybreak", artworkId: "cover-v1"
        ))
        _ = try index.refreshDownloadDetailsFromLibrary()
        #expect(try index.download(forTrack: id("t1"))?.artworkId == "cover-v1")
    }

    @Test("The covers of downloaded albums are listed from the library as it is now")
    func downloadedAlbumCovers() throws {
        let index = try seeded()
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Daybreak", artistName: "Aurora Skies", artistID: id("ar1"),
                  artwork: ArtworkID(server: server, rawValue: "album-cover")),
        ], generation: 2)
        #expect(try index.artworkIDsOfDownloadedAlbums().isEmpty)
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done))
        #expect(try index.artworkIDsOfDownloadedAlbums() == ["album-cover"])
    }
}

/// Browsing with the network gone: the same queries, narrowed to what is
/// really on the phone.
@Suite("Offline browsing")
struct OfflineBrowsingTests {
    private let server = ServerID()

    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    /// Two artists, two albums, three tracks — one of which is downloaded.
    private func seeded() throws -> LibraryIndex {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertArtists([
            Artist(id: id("ar1"), name: "Aurora Skies"),
            Artist(id: id("ar2"), name: "Cobalt Waves"),
        ], generation: 1)
        try index.upsertAlbums([
            Album(id: id("al1"), name: "Daybreak", artistName: "Aurora Skies", artistID: id("ar1")),
            Album(id: id("al2"), name: "Nightfall", artistName: "Cobalt Waves", artistID: id("ar2")),
        ], generation: 1)
        try index.upsertTracks([
            Track(id: id("t1"), title: "First Light", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: id("ar1"), trackNumber: 1),
            Track(id: id("t2"), title: "Second Light", albumName: "Daybreak", albumID: id("al1"),
                  artistName: "Aurora Skies", artistID: id("ar1"), trackNumber: 2),
            Track(id: id("t3"), title: "Cobalt Light", albumName: "Nightfall", albumID: id("al2"),
                  artistName: "Cobalt Waves", artistID: id("ar2"), trackNumber: 1),
        ], generation: 1)
        try index.finishSync(generation: 1)
        try index.saveDownload(DownloadRecord(trackId: "t1", state: .done, fileName: "a.flac"))
        return index
    }

    @Test("Only artists with something on the phone")
    func artists() throws {
        let index = try seeded()
        #expect(try index.artists().count == 2)
        #expect(try index.artists(downloadedOnly: true).map(\.name) == ["Aurora Skies"])
    }

    @Test("Only albums with something on the phone")
    func albums() throws {
        let index = try seeded()
        #expect(try index.albums(filter: .alphabeticalByName, offset: 0, limit: 50).count == 2)
        let offline = try index.albums(filter: .alphabeticalByName, offset: 0, limit: 50, downloadedOnly: true)
        #expect(offline.map(\.name) == ["Daybreak"])
    }

    @Test("And the same for an artist's own albums")
    func artistAlbums() throws {
        let index = try seeded()
        #expect(try index.albums(forArtist: id("ar1"), downloadedOnly: true).map(\.name) == ["Daybreak"])
        #expect(try index.albums(forArtist: id("ar2"), downloadedOnly: true).isEmpty)
    }

    @Test("Search answers only with what can be played")
    func search() throws {
        let index = try seeded()
        // Songs: three match, one is on the phone.
        #expect(try index.search("Light", limit: 20).tracks.count == 3)
        #expect(try index.search("Light", limit: 20, downloadedOnly: true).tracks.map(\.title)
            == ["First Light"])

        // An album with a downloaded song stays; one without it goes, and so
        // does its artist — offline, a result you cannot open is worse than
        // no result at all.
        #expect(try index.search("Daybreak", limit: 20, downloadedOnly: true).albums.map(\.name)
            == ["Daybreak"])
        #expect(try index.search("Nightfall", limit: 20).albums.map(\.name) == ["Nightfall"])
        #expect(try index.search("Nightfall", limit: 20, downloadedOnly: true).albums.isEmpty)
        #expect(try index.search("Cobalt", limit: 20, downloadedOnly: true).artists.isEmpty)
        #expect(try index.search("Aurora", limit: 20, downloadedOnly: true).artists.map(\.name)
            == ["Aurora Skies"])
    }

    @Test("A queued download is not a download")
    func queuedDoesNotCount() throws {
        let index = try seeded()
        try index.saveDownload(DownloadRecord(trackId: "t3", state: .queued))
        #expect(try index.artists(downloadedOnly: true).map(\.name) == ["Aurora Skies"])
        #expect(try index.downloadedTrackIDs() == ["t1"])
    }
}
