import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The songs list reads whole tracks by stepping a cursor and taking each column by position,
/// rather than decoding a `TrackRecord` through Codable and mapping it.
@Suite("A whole song, read by column position")
struct WholeTrackReadTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    @Test("Every column arrives where it belongs")
    func everyColumn() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let played = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Track(
            id: id("t1"),
            title: "Only Song",
            albumName: "The Record",
            albumID: id("al1"),
            artistName: "The Artist",
            artistID: id("ar1"),
            trackNumber: 7,
            discNumber: 2,
            duration: 213.5,
            year: 1999,
            originalYear: 1997,
            genre: "Ambient",
            codec: "flac",
            contentType: "audio/flac",
            bitRateKbps: 1024,
            sampleRate: 48_000,
            bitDepth: 24,
            channelCount: 2,
            fileSize: 41_234_567,
            artwork: ArtworkID(server: server, rawValue: "art1"),
            replayGain: ReplayGain(trackGain: -6.5, albumGain: -5.5, trackPeak: 0.98, albumPeak: 0.99),
            isFavorite: true,
            rating: StarRating(4),
            playCount: 12,
            playedAt: played
        )
        try index.upsertTracks([original], generation: 1)
        try index.finishSync(generation: 1)

        let read = try #require(try index.tracks(order: .alphabeticalByTitle).first)

        #expect(read.id == original.id)
        #expect(read.title == original.title)
        #expect(read.albumName == original.albumName)
        #expect(read.albumID == original.albumID)
        #expect(read.artistName == original.artistName)
        #expect(read.artistID == original.artistID)
        #expect(read.trackNumber == original.trackNumber)
        #expect(read.discNumber == original.discNumber)
        #expect(read.duration == original.duration)
        #expect(read.year == original.year)
        #expect(read.originalYear == original.originalYear)
        #expect(read.genre == original.genre)
        #expect(read.codec == original.codec)
        #expect(read.contentType == original.contentType)
        #expect(read.bitRateKbps == original.bitRateKbps)
        #expect(read.sampleRate == original.sampleRate)
        #expect(read.bitDepth == original.bitDepth)
        #expect(read.channelCount == original.channelCount)
        #expect(read.fileSize == original.fileSize)
        #expect(read.artwork == original.artwork)
        #expect(read.replayGain?.trackGain == -6.5)
        #expect(read.replayGain?.albumGain == -5.5)
        #expect(read.replayGain?.trackPeak == 0.98)
        #expect(read.replayGain?.albumPeak == 0.99)
        #expect(read.isFavorite == true)
        #expect(read.rating == original.rating)
        #expect(read.playCount == 12)
        #expect(read.playedAt?.timeIntervalSince1970 == played.timeIntervalSince1970)
    }

    @Test("A song with nothing filled in stays empty rather than picking up a neighbour's value")
    func emptyColumns() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.upsertTracks([Track(id: id("t1"), title: "Bare")], generation: 1)
        try index.finishSync(generation: 1)

        let read = try #require(try index.tracks(order: .alphabeticalByTitle).first)
        #expect(read.title == "Bare")
        #expect(read.albumName == nil)
        #expect(read.albumID == nil)
        #expect(read.artistName == nil)
        #expect(read.artistID == nil)
        #expect(read.trackNumber == nil)
        #expect(read.duration == nil)
        #expect(read.genre == nil)
        #expect(read.codec == nil)
        #expect(read.fileSize == nil)
        #expect(read.artwork == nil)
        #expect(read.replayGain == nil)
        #expect(read.isFavorite == false)
        #expect(read.rating == nil)
        #expect(read.playedAt == nil)
    }
}
