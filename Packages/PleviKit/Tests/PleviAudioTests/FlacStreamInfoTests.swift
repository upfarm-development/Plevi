import Foundation
import Testing
@testable import PleviAudio

@Suite("FLAC STREAMINFO")
struct FlacStreamInfoTests {
    /// A FLAC header with the given rate, channels and depth, and nothing after.
    private func header(rate: Int, channels: Int, bits: Int, id3: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 42)
        bytes[0...3] = [0x66, 0x4C, 0x61, 0x43]
        bytes[4] = 0x00            // STREAMINFO, not the last block
        bytes[7] = 34
        bytes[18] = UInt8((rate >> 12) & 0xFF)
        bytes[19] = UInt8((rate >> 4) & 0xFF)
        bytes[20] = UInt8(((rate & 0x0F) << 4) | (((channels - 1) & 0x07) << 1) | (((bits - 1) >> 4) & 0x01))
        bytes[21] = UInt8(((bits - 1) & 0x0F) << 4)
        guard id3 > 0 else { return Data(bytes) }
        var tag: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0,
                            UInt8((id3 >> 21) & 0x7F), UInt8((id3 >> 14) & 0x7F),
                            UInt8((id3 >> 7) & 0x7F), UInt8(id3 & 0x7F)]
        tag += [UInt8](repeating: 0, count: id3)
        return Data(tag + bytes)
    }

    @Test("48 kHz, 16 bit, stereo")
    func fortyEightSixteen() {
        #expect(FlacStreamInfo.read(from: header(rate: 48_000, channels: 2, bits: 16))
                == .init(sampleRate: 48_000, channels: 2, bitsPerSample: 16))
    }

    @Test("96 kHz, 24 bit, stereo")
    func hiRes() {
        #expect(FlacStreamInfo.read(from: header(rate: 96_000, channels: 2, bits: 24))
                == .init(sampleRate: 96_000, channels: 2, bitsPerSample: 24))
    }

    @Test("44.1 kHz, 16 bit behind an ID3 tag")
    func behindATag() {
        #expect(FlacStreamInfo.read(from: header(rate: 44_100, channels: 2, bits: 16, id3: 300))?.bitsPerSample == 16)
    }

    @Test("not FLAC, or too short to say, is nil")
    func notFlac() {
        #expect(FlacStreamInfo.read(from: Data("OggS".utf8)) == nil)
        #expect(FlacStreamInfo.read(from: Data()) == nil)
        #expect(FlacStreamInfo.read(from: Data([0x66, 0x4C, 0x61, 0x43, 0x00])) == nil)
    }
}
