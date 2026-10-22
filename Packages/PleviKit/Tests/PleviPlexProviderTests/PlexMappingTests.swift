import Foundation
import Testing
import PleviDomain
import PleviTransport
@testable import PleviPlexProvider

@Suite struct PlexMappingTests {
    private let server = ServerID()

    private func rows(_ json: String) throws -> [PlexMetadata] {
        try JSONDecoder().decode(PlexMediaContainerResponse.self, from: Data(json.utf8)).items
    }

    // MARK: Ratings

    /// Plex stores a five-star rating doubled. Getting this wrong would show
    /// every rating at half or double what the user set.
    @Test func halvesPlexRatingsOntoTheFiveStarScale() {
        #expect(PlexMapper.starRating(fromPlex: 10)?.value == 5)
        #expect(PlexMapper.starRating(fromPlex: 8)?.value == 4)
        #expect(PlexMapper.starRating(fromPlex: 5)?.value == 2.5)
        #expect(PlexMapper.starRating(fromPlex: 2)?.value == 1)
    }

    @Test func treatsNoRatingAndZeroAsUnrated() {
        #expect(PlexMapper.starRating(fromPlex: nil) == nil)
        #expect(PlexMapper.starRating(fromPlex: 0) == nil)
    }

    @Test func doublesBackWhenWritingARating() {
        #expect(PlexMapper.plexRating(from: StarRating(5)) == 10)
        #expect(PlexMapper.plexRating(from: StarRating(2.5)) == 5)
        #expect(PlexMapper.plexRating(from: nil) == 0)
    }

    /// A rating set in Plex must read back identically, and one set here must
    /// show the same in Plex.
    @Test func ratingsSurviveARoundTrip() {
        for plex in stride(from: 1.0, through: 10.0, by: 1.0) {
            let rating = PlexMapper.starRating(fromPlex: plex)
            #expect(PlexMapper.plexRating(from: rating) == plex, "\(plex)")
        }
    }

    // MARK: Units

    /// Every duration Plex reports is in milliseconds. Treating them as
    /// seconds would make a four-minute song look like eleven hours.
    @Test func convertsMillisecondDurationsToSeconds() {
        #expect(PlexMapper.duration(fromMilliseconds: 240_000) == 240)
        #expect(PlexMapper.duration(fromMilliseconds: 1_500) == 1.5)
        #expect(PlexMapper.duration(fromMilliseconds: 0) == nil)
        #expect(PlexMapper.duration(fromMilliseconds: nil) == nil)
    }

    @Test func readsEpochSecondsAsDates() {
        #expect(PlexMapper.date(fromEpochSeconds: 1_700_000_000) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(PlexMapper.date(fromEpochSeconds: 0) == nil)
        #expect(PlexMapper.date(fromEpochSeconds: nil) == nil)
    }

    // MARK: Objects

    @Test func mapsAnArtistRow() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "101", "type": "artist", "title": "Coldplay",
           "titleSort": "Coldplay", "childCount": 12, "thumb": "/library/metadata/101/thumb/1",
           "userRating": 8}
        ]}}
        """
        let row = try #require(rows(json).first)
        let artist = try #require(PlexMapper.artist(row, server: server))
        #expect(artist.id.rawValue == "101")
        #expect(artist.name == "Coldplay")
        #expect(artist.albumCount == 12)
        #expect(artist.artwork?.rawValue == "/library/metadata/101/thumb/1")
        #expect(artist.rating?.value == 4)
    }

    @Test func aMatchedArtistCarriesItsMusicBrainzID() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "101", "type": "artist", "title": "Coldplay",
           "Guid": [
             {"id": "imdb://nm1682433"},
             {"id": "mbid://cc197bad-dc9c-440d-a5b5-d52ba2e14234"}
           ]}
        ]}}
        """
        let row = try #require(rows(json).first)
        let artist = try #require(PlexMapper.artist(row, server: server))
        #expect(artist.musicBrainzID == "cc197bad-dc9c-440d-a5b5-d52ba2e14234")
    }

    @Test func anUnmatchedArtistHasNoMusicBrainzID() throws {
        // No `Guid` array at all — either the request didn't ask for it
        // with `includeGuids=1`, or Plex never matched this artist.
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "101", "type": "artist", "title": "Unmatched Artist"}
        ]}}
        """
        let row = try #require(rows(json).first)
        let artist = try #require(PlexMapper.artist(row, server: server))
        #expect(artist.musicBrainzID == nil)
    }

    @Test func onlyTheMbidGuidIsRead() throws {
        // A `Guid` array with no `mbid://` entry at all — Plex matched the
        // artist to some other service but not to MusicBrainz.
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "101", "type": "artist", "title": "Partly Matched",
           "Guid": [{"id": "imdb://nm1682433"}]}
        ]}}
        """
        let row = try #require(rows(json).first)
        let artist = try #require(PlexMapper.artist(row, server: server))
        #expect(artist.musicBrainzID == nil)
    }

    @Test func mapsAnAlbumRowIncludingItsArtistLink() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "202", "type": "album", "title": "Parachutes",
           "parentRatingKey": "101", "parentTitle": "Coldplay", "year": 2000,
           "leafCount": 10, "duration": 2400000, "addedAt": 1700000000,
           "lastViewedAt": 1700100000, "viewCount": 4,
           "thumb": "/library/metadata/202/thumb/2",
           "Genre": [{"tag": "Alternative"}, {"tag": "Rock"}]}
        ]}}
        """
        let row = try #require(rows(json).first)
        let album = try #require(PlexMapper.album(row, server: server))
        #expect(album.name == "Parachutes")
        #expect(album.artistID?.rawValue == "101")
        #expect(album.artistName == "Coldplay")
        #expect(album.year == 2000)
        #expect(album.trackCount == 10)
        #expect(album.duration == 2400)
        #expect(album.genre == "Alternative")
        #expect(album.playCount == 4)
        #expect(album.addedAt != nil)
        #expect(album.playedAt != nil)
    }

    /// Plex nests a track two deep: its parent is the album and its
    /// grandparent the artist. Reading the parent as the artist would put
    /// the album's name where the artist belongs on every row in the app.
    @Test func mapsATrackWithItsAlbumAsParentAndArtistAsGrandparent() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "303", "type": "track", "title": "Yellow",
           "parentRatingKey": "202", "parentTitle": "Parachutes", "parentIndex": 1,
           "grandparentRatingKey": "101", "grandparentTitle": "Coldplay",
           "index": 5, "duration": 269000, "userRating": 10, "viewCount": 3,
           "ratingCount": 4826,
           "Media": [{"audioCodec": "flac", "bitrate": 900, "audioChannels": 2,
             "Part": [{"id": 9, "key": "/library/parts/9/1/file.flac", "size": 30000000}]}]}
        ]}}
        """
        let row = try #require(rows(json).first)
        let track = try #require(PlexMapper.track(row, server: server))
        #expect(track.title == "Yellow")
        #expect(track.albumID?.rawValue == "202")
        #expect(track.albumName == "Parachutes")
        #expect(track.artistID?.rawValue == "101")
        #expect(track.artistName == "Coldplay")
        #expect(track.trackNumber == 5)
        #expect(track.discNumber == 1)
        #expect(track.duration == 269)
        #expect(track.codec == "flac")
        #expect(track.bitRateKbps == 900)
        #expect(track.channelCount == 2)
        #expect(track.fileSize == 30000000)
        #expect(track.rating?.value == 5)
        // The audience's own figure, not the personal rating a few lines up
        // — the two are read from entirely different keys and must not be
        // confused with one another.
        #expect(track.popularity == 4826)
    }

    /// Most rows in a real library have no figure at all: Plex only carries one for an item its
    /// metadata agent matched.
    @Test func aTrackWithNoAudiencePopularityHasNilNotZero() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "303", "type": "track", "title": "Yellow",
           "grandparentRatingKey": "101", "grandparentTitle": "Coldplay"}
        ]}}
        """
        let row = try #require(rows(json).first)
        let track = try #require(PlexMapper.track(row, server: server))
        #expect(track.popularity == nil)
    }

    @Test func fallsBackThroughParentArtworkWhenATrackHasNone() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "303", "type": "track", "title": "Yellow",
           "parentThumb": "/album/thumb", "grandparentThumb": "/artist/thumb"}
        ]}}
        """
        let row = try #require(rows(json).first)
        let track = try #require(PlexMapper.track(row, server: server))
        #expect(track.artwork?.rawValue == "/album/thumb")
    }

    @Test func skipsRowsWithNoIdentity() throws {
        let json = #"{"MediaContainer": {"Metadata": [{"type": "track", "title": "Orphan"}]}}"#
        let row = try #require(rows(json).first)
        #expect(PlexMapper.track(row, server: server) == nil)
    }

    @Test func survivesAnEmptyLibrary() throws {
        #expect(try rows(#"{"MediaContainer": {"size": 0}}"#).isEmpty)
    }

    // MARK: Release types

    @Test func mapsPlexFormatTagsOntoReleaseTypes() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "Live at Wembley",
           "Format": [{"tag": "Album"}], "Subformat": [{"tag": "Live"}]}
        ]}}
        """
        let row = try #require(rows(json).first)
        let album = try #require(PlexMapper.album(row, server: server))
        #expect(album.releaseTypes.contains(.live))
        // The specific tag decides the section, not the general "Album" that
        // Plex lists alongside it.
        #expect(album.primaryReleaseType == .live)
    }

    @Test func marksACompilationFromItsTag() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "Now 64", "Subformat": [{"tag": "Compilation"}]}
        ]}}
        """
        let row = try #require(rows(json).first)
        let album = try #require(PlexMapper.album(row, server: server))
        #expect(album.isCompilation)
        #expect(album.primaryReleaseType == .compilation)
    }

    /// `ReleaseType` treats anything it does not recognise as an album, which
    /// is right for a server stating a release type and wrong for a loose
    /// Plex tag — it would file every record under Albums.
    @Test func ignoresPlexTagsThatAreNotReleaseTypes() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "Something", "Subformat": [{"tag": "Field Recording"}]}
        ]}}
        """
        let row = try #require(rows(json).first)
        let album = try #require(PlexMapper.album(row, server: server))
        #expect(album.releaseTypes.isEmpty)
        #expect(album.primaryReleaseType == .album)
    }

    @Test func doesNotRepeatAReleaseTypeListedTwice() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "EP", "Format": [{"tag": "EP"}], "Subformat": [{"tag": "eps"}]}
        ]}}
        """
        let row = try #require(rows(json).first)
        let album = try #require(PlexMapper.album(row, server: server))
        #expect(album.releaseTypes == [.ep])
    }
}

@Suite struct PlexReleaseTypeCompletionTests {
    private let server = ServerID()

    private func rows(_ json: String) throws -> [PlexMetadata] {
        try JSONDecoder().decode(PlexMediaContainerResponse.self, from: Data(json.utf8)).items
    }

    /// Plex's own clients shelve an artist's singles, EPs and live records
    /// separately, so the server knows the types even when a listing does not
    /// carry them. These check the shape the batched refetch relies on.
    @Test func aListingWithNoReleaseTagsIsRecognisable() throws {
        let listing = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "A Rush of Blood"},
          {"ratingKey": "2", "title": "Live 2012"}
        ]}}
        """
        let items = try rows(listing)
        #expect(items.allSatisfy { ($0.format?.isEmpty ?? true) && ($0.subformat?.isEmpty ?? true) })
    }

    @Test func aFullRecordCarriesTheTagsTheListingLacked() throws {
        let full = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "A Rush of Blood", "Format": [{"tag": "Album"}]},
          {"ratingKey": "2", "title": "Live 2012", "Format": [{"tag": "Album"}], "Subformat": [{"tag": "Live"}]}
        ]}}
        """
        let items = try rows(full)
        let live = try #require(items.last)
        let album = try #require(PlexMapper.album(live, server: server))
        #expect(album.primaryReleaseType == .live)
    }

    /// Merging by key rather than position: a batched fetch may drop an item,
    /// and pairing by index would then mislabel every album after it.
    @Test func mergingByKeyToleratesAMissingRecord() throws {
        let listing = try rows("""
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "One"},
          {"ratingKey": "2", "title": "Two"},
          {"ratingKey": "3", "title": "Three"}
        ]}}
        """)
        let full = try rows("""
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "3", "title": "Three", "Subformat": [{"tag": "Live"}]}
        ]}}
        """)
        let byKey = Dictionary(
            full.compactMap { row in row.ratingKey.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )
        let merged = listing.map { row -> PlexMetadata in
            guard let key = row.ratingKey, let detailed = byKey[key] else { return row }
            return detailed
        }
        #expect(merged.count == 3)
        #expect(merged[0].title == "One")
        let third = try #require(PlexMapper.album(merged[2], server: server))
        #expect(third.primaryReleaseType == .live)
    }
}

@Suite struct PlexTrackCreditTests {
    private let server = ServerID()

    private func track(_ json: String) throws -> Track {
        let items = try JSONDecoder()
            .decode(PlexMediaContainerResponse.self, from: Data(json.utf8)).items
        let item = try #require(items.first)
        return try #require(PlexMapper.track(item, server: server))
    }

    /// Plex puts the album's artist in `grandparentTitle` and the track's own credit in
    /// `originalTitle`, filling the latter in only when they differ.
    @Test func prefersTheTrackCreditOverTheAlbumArtist() throws {
        let credited = try track(#"""
        {"MediaContainer": {"Metadata": [{
            "ratingKey": "1", "type": "track", "title": "Blue Monday",
            "grandparentTitle": "Various Artists", "originalTitle": "New Order"
        }]}}
        """#)
        #expect(credited.artistName == "New Order")
    }

    @Test func fallsBackToTheAlbumArtistWhenThereIsNoOwnCredit() throws {
        let plain = try track(#"""
        {"MediaContainer": {"Metadata": [{
            "ratingKey": "2", "type": "track", "title": "Yellow",
            "grandparentTitle": "Coldplay"
        }]}}
        """#)
        #expect(plain.artistName == "Coldplay")
    }

    private func creditedTrackItem() throws -> PlexMetadata {
        let items = try JSONDecoder().decode(PlexMediaContainerResponse.self, from: Data(#"""
        {"MediaContainer": {"Metadata": [{
            "ratingKey": "1", "type": "track", "title": "Blue Monday",
            "grandparentRatingKey": "various", "grandparentTitle": "Various Artists",
            "originalTitle": "New Order"
        }]}}
        """#.utf8)).items
        return try #require(items.first)
    }

    /// The name being right was never the whole of the earlier fix — reading `originalTitle` for
    /// `artistName` and then reaching for `grandparentRatingKey` regardless, for `artistID`, is
    /// exactly how a compilation's *name* read correctly while…
    @Test func resolvesTheCreditedArtistsOwnIDWhenKnown() throws {
        let newOrder = MediaID(server: server, rawValue: "new-order")
        let credited = try #require(PlexMapper.track(
            creditedTrackItem(), server: server,
            resolvingArtistIDByName: ["new order": newOrder]
        ))
        #expect(credited.artistID == newOrder)
    }

    /// A credited artist with no other presence in the library — nothing in
    /// the resolver to find them by. Left on the album's own artist rather
    /// than guessing, exactly what every row did before this existed.
    @Test func staysOnTheAlbumArtistIDWhenTheCreditMatchesNoKnownArtist() throws {
        let various = MediaID(server: server, rawValue: "various")
        let credited = try #require(PlexMapper.track(
            creditedTrackItem(), server: server,
            resolvingArtistIDByName: [:]
        ))
        #expect(credited.artistID == various)
    }
}

@Suite struct PlexArtworkRequestTests {
    private func provider() -> PlexProvider {
        PlexProvider(
            serverID: ServerID(),
            config: PlexServerConfig(
                baseURL: URL(string: "https://203-0-113-7.abc.plex.direct:32400")!,
                token: "tok",
                sectionKey: "17"
            ),
            identity: PlexIdentity(clientIdentifier: "client-1"),
            transport: PlainHTTPTransport()
        )
    }

    /// Plex's photo transcoder fetches this parameter itself.
    @Test func transcodeTakesTheThumbAsARelativePath() async throws {
        let request = try await provider().artworkRequest(
            for: ArtworkID(server: ServerID(), rawValue: "/library/metadata/301334/thumb/1786968622"),
            size: 300
        )
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let url = try #require(components.queryItems?.first { $0.name == "url" }?.value)
        #expect(url == "/library/metadata/301334/thumb/1786968622")
        #expect(!url.contains("https://"))
        #expect(components.path == "/photo/:/transcode")
    }

    /// Without a size there is nothing to transcode, so the image itself is
    /// asked for directly.
    @Test func fullSizeArtworkSkipsTheTranscoder() async throws {
        let request = try await provider().artworkRequest(
            for: ArtworkID(server: ServerID(), rawValue: "/library/metadata/301334/thumb/1786968622"),
            size: nil
        )
        #expect(request.url?.path() == "/library/metadata/301334/thumb/1786968622")
    }
}

/// What the radio's rating floor means once a Plex rating has crossed into the app's own scale.
@Suite struct PlexRatingFloorMappingTests {
    private let floor = 2.5

    @Test("Plex's own scale lands either side of the floor where it should")
    func floorOnPlexScale() {
        // Plex 5 of 10 is exactly the line, and is kept.
        #expect(PlexMapper.starRating(fromPlex: 5)?.value == floor)
        // Plex 4 of 10 is two stars — under it, and dropped.
        let below = PlexMapper.starRating(fromPlex: 4)
        #expect(below?.value == 2.0)
        #expect((below?.value ?? 0) < floor)
        // Plex 6 is three stars, comfortably over.
        #expect((PlexMapper.starRating(fromPlex: 6)?.value ?? 0) > floor)
    }

    @Test("An unrated song is not a badly rated one")
    func unratedIsNotBelowTheFloor() {
        #expect(PlexMapper.starRating(fromPlex: nil) == nil)
        #expect(PlexMapper.starRating(fromPlex: 0) == nil)
    }

    @Test("Original years are read off Plex's date, whatever precision it sent")
    func originalYearParsing() {
        #expect(PlexMapper.originalYear(from: "1973-05-16") == 1973)
        #expect(PlexMapper.originalYear(from: "1973") == 1973)
        #expect(PlexMapper.originalYear(from: nil) == nil)
        #expect(PlexMapper.originalYear(from: "") == nil)
        #expect(PlexMapper.originalYear(from: "not-a-date") == nil)
    }
}
