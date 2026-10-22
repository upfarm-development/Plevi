import Testing
import Foundation
@testable import PleviPlexProvider
import PleviDomain

/// Finding a track's lyric file in what Plex sends back.
@Suite("Plex lyrics")
struct PlexLyricsTests {
    private func metadata(_ streams: String) throws -> PlexMetadata {
        let json = """
        {"ratingKey": "41231", "title": "These Words", "type": "track",
         "Media": [{"id": 1, "audioCodec": "flac", "bitrate": "1005",
                    "Part": [{"id": 2, "key": "/library/parts/1/2/file.flac",
                              "container": "flac", "Stream": [\(streams)]}]}]}
        """
        return try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    private let audio = """
    {"id": 100, "streamType": 2, "codec": "flac", "samplingRate": 44100,
     "bitDepth": 16, "channels": 2, "loudness": "-7.20"}
    """

    @Test("The lyric stream is found beside the audio")
    func findsTheLyricStream() throws {
        let lyric = """
        {"id": 101, "streamType": 4, "format": "lrc",
         "key": "/library/streams/101"}
        """
        let row = try metadata("\(audio), \(lyric)")
        #expect(PlexMapper.lyricStreamKey(in: row) == "/library/streams/101")
    }

    /// The usual case, and the one that decides whether the button is shown
    /// at all: a track with nothing but its audio.
    @Test("A track with no lyric stream has no key")
    func noLyricStream() throws {
        #expect(PlexMapper.lyricStreamKey(in: try metadata(audio)) == nil)
    }

    /// A listing gives `Media` and `Part` but no `Stream` at all, which is
    /// why this is asked of a full metadata request and not of the track the
    /// app already has.
    @Test("A track from a listing has no streams to look through")
    func noStreamsAtAll() throws {
        let json = """
        {"ratingKey": "41231", "title": "These Words", "type": "track",
         "Media": [{"id": 1, "audioCodec": "flac",
                    "Part": [{"id": 2, "key": "/library/parts/1/2/file.flac"}]}]}
        """
        let row = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        #expect(PlexMapper.lyricStreamKey(in: row) == nil)
    }

    /// A stream of the right kind with nowhere to fetch it from is no use,
    /// and must not be mistaken for one that is.
    @Test("A lyric stream with no key is passed over")
    func lyricStreamWithoutKey() throws {
        let row = try metadata("""
        \(audio), {"id": 101, "streamType": 4, "format": "txt"},
        {"id": 102, "streamType": 4, "format": "lrc", "key": "/library/streams/102"}
        """)
        #expect(PlexMapper.lyricStreamKey(in: row) == "/library/streams/102")
    }

    /// The audio stream is still read correctly with a lyric stream beside
    /// it — the badge takes its figures from the same list.
    @Test("Adding lyrics does not disturb the audio stream")
    func audioStillReads() throws {
        let row = try metadata("""
        \(audio), {"id": 101, "streamType": 4, "format": "lrc", "key": "/library/streams/101"}
        """)
        let track = try #require(PlexMapper.track(row, server: ServerID(rawValue: UUID())))
        #expect(track.sampleRate == 44100)
        #expect(track.bitDepth == 16)
    }
}
