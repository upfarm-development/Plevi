import Testing
import Foundation
@testable import PleviPlexProvider
import PleviDomain

/// Loudness as Plex reports it, and what it becomes.
@Suite("Plex loudness")
struct PlexLoudnessTests {
    private func stream(
        gain: Double? = nil,
        peak: Double? = nil,
        loudness: Double? = nil,
        albumGain: Double? = nil,
        albumPeak: Double? = nil
    ) -> PlexStream {
        func number(_ value: Double?) -> String {
            guard let value else { return "null" }
            return String(value)
        }
        let json = """
        {"streamType": 2, "gain": \(number(gain)), "peak": \(number(peak)), \
        "loudness": \(number(loudness)), "albumGain": \(number(albumGain)), \
        "albumPeak": \(number(albumPeak))}
        """
        return try! JSONDecoder().decode(PlexStream.self, from: Data(json.utf8))
    }

    @Test("Track gain is the reference minus the measured loudness")
    func trackGainFromLoudness() throws {
        // -18 - (-7.20) = -10.80, the figure for All Around The World.
        let gain = try #require(PlexMapper.replayGain(from: stream(loudness: -7.20)))
        let trackGain = try #require(gain.trackGain)
        #expect(abs(trackGain - -10.80) < 0.001)
    }

    @Test("Album gain is read rather than derived")
    func albumGainIsRead() throws {
        let gain = try #require(
            PlexMapper.replayGain(from: stream(gain: -11.75, loudness: -6.25, albumGain: -11.75))
        )
        #expect(gain.albumGain == -11.75)
    }

    @Test("Peaks come through, the album's falling back to the track's")
    func peaks() throws {
        let both = try #require(
            PlexMapper.replayGain(from: stream(peak: 0.979492, loudness: -13.08, albumPeak: 0.979828))
        )
        #expect(both.trackPeak == 0.979492)
        #expect(both.albumPeak == 0.979828)

        let trackOnly = try #require(PlexMapper.replayGain(from: stream(peak: 0.5, loudness: -9)))
        #expect(trackOnly.albumPeak == 0.5)
    }

    @Test("A stream with no loudness at all yields nothing to level with")
    func unanalysed() {
        #expect(PlexMapper.replayGain(from: stream()) == nil)
        #expect(PlexMapper.replayGain(from: nil) == nil)
    }
}

/// Plex writes numbers both ways.
@Suite("Plex stream decoding")
struct PlexStreamDecodingTests {
    private func decode(_ json: String) throws -> PlexStream {
        try JSONDecoder().decode(PlexStream.self, from: Data(json.utf8))
    }

    @Test("Loudness written as numbers")
    func numbers() throws {
        let stream = try decode(#"{"streamType":2,"gain":-11.75,"peak":0.99,"loudness":-7.2}"#)
        #expect(stream.gain == -11.75)
        #expect(stream.loudness == -7.2)
    }

    @Test("Loudness written as quoted strings")
    func strings() throws {
        let stream = try decode(#"{"streamType":2,"gain":"-11.75","peak":"0.99","loudness":"-7.2"}"#)
        #expect(stream.gain == -11.75)
        #expect(stream.peak == 0.99)
        #expect(stream.loudness == -7.2)
    }

    @Test("A value in some third shape costs that field, not the track")
    func nonsense() throws {
        let stream = try decode(#"{"streamType":2,"codec":"flac","gain":{"unexpected":true}}"#)
        #expect(stream.gain == nil)
        #expect(stream.codec == "flac")
    }
}

/// A page of library rows must survive one bad row.
@Suite("Plex page decoding")
struct PlexPageDecodingTests {
    @Test("One unreadable row costs that row, not the page")
    func lossyRows() throws {
        let json = """
        {"MediaContainer": {"size": 3, "Metadata": [
            {"ratingKey": "1", "title": "Good"},
            {"ratingKey": "2", "title": "Odd", "Genre": "not-an-array"},
            {"ratingKey": "3", "title": "Also good"}
        ]}}
        """
        let decoded = try JSONDecoder().decode(PlexLibraryResponse.self, from: Data(json.utf8))
        let rows = try #require(decoded.mediaContainer.metadata)
        #expect(rows.count == 2)
        #expect(rows.map(\.title) == ["Good", "Also good"])
    }

    @Test("A page with nothing readable is empty rather than a thrown page")
    func allBad() throws {
        let json = """
        {"MediaContainer": {"size": 1, "Metadata": [{"Genre": "not-an-array", "ratingKey": {"o": 1}}]}}
        """
        let decoded = try JSONDecoder().decode(PlexLibraryResponse.self, from: Data(json.utf8))
        #expect(decoded.mediaContainer.metadata?.isEmpty == true)
    }
}
