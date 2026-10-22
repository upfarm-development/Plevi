import AVFoundation
import Foundation
import Testing
@testable import PleviAudio

/// playback-02 and playback-16: which files may be played while they are still
/// arriving, and how much of one has to be there first.
@Suite("Playing a file that is still arriving")
struct GrowingFileTests {
    private func head(_ bytes: [UInt8]) -> Data { Data(bytes) }
    private func ascii(_ text: String, at offset: Int = 0, padTo size: Int = 16) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(size, offset + text.utf8.count))
        for (i, byte) in text.utf8.enumerated() { bytes[offset + i] = byte }
        return Data(bytes)
    }

    // MARK: playback-02

    @Test("Containers that declare their whole length are recognised by their first bytes")
    func recognisesHeaderDeclaredContainers() {
        #expect(GrowingFile.container(of: ascii("fLaC")) == .flac)
        #expect(GrowingFile.container(of: ascii("FORM")) == .aiff)
        #expect(GrowingFile.container(of: ascii("caff")) == .caf)
        #expect(GrowingFile.container(of: ascii("ftyp", at: 4)) == .mp4)
    }

    @Test("Streams whose length is whatever has arrived are not mistaken for them")
    func leavesGrowingFormatsAlone() {
        #expect(GrowingFile.container(of: ascii("ID3")) == .other)
        #expect(GrowingFile.container(of: head([0xFF, 0xFB, 0x90, 0x00])) == .other)
        #expect(GrowingFile.container(of: head([0xFF, 0xF1, 0x50, 0x80])) == .other, "ADTS")
        #expect(GrowingFile.container(of: ascii("OggS")) == .other)
        #expect(GrowingFile.container(of: ascii("RIFF")) == .other)
        #expect(GrowingFile.container(of: Data()) == .other)
        #expect(GrowingFile.container(of: Data([0x66, 0x4C])) == .other, "a file too short to tell")
    }

    @Test("An original in a header-declared container cannot be measured while it arrives; it is read")
    func originalsDeclareTheirLength() {
        for magic in [ascii("fLaC"), ascii("FORM"), ascii("caff"), ascii("ftyp", at: 4)] {
            #expect(GrowingFile.declaresLength(head: magic, isConversion: false))
        }
        #expect(!GrowingFile.declaresLength(head: ascii("ID3"), isConversion: false))
        #expect(!GrowingFile.declaresLength(head: ascii("RIFF"), isConversion: false))
    }

    @Test("A conversion is measured whatever it is wrapped in: the server cannot declare a length it does not know")
    func conversionsAlwaysGrow() {
        // Plex delivers AAC in an MP4 wrapper, made as it goes.
        #expect(!GrowingFile.declaresLength(head: ascii("ftyp", at: 4), isConversion: true))
        #expect(!GrowingFile.declaresLength(head: ascii("OggS"), isConversion: true))
    }

    @Test("Premise: a FLAC cut off part-way still reports its whole length; a WAV reports what is there")
    func truncatedFilesReportDifferently() throws {
        let frames = 44_100 * 6
        let flac = try Self.write(frames: frames, ext: "flac", settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
        ])
        let wav = try Self.write(frames: frames, ext: "wav", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ])
        defer {
            try? FileManager.default.removeItem(at: flac)
            try? FileManager.default.removeItem(at: wav)
        }
        let flacHead = try Data(contentsOf: flac).prefix(16)
        #expect(GrowingFile.container(of: Data(flacHead)) == .flac)
        #expect(GrowingFile.declaresLength(head: Data(flacHead), isConversion: false))

        let flacFull = try AVAudioFile(forReading: flac).length
        let wavFull = try AVAudioFile(forReading: wav).length
        try Self.truncate(flac, toFraction: 0.4)
        try Self.truncate(wav, toFraction: 0.4)
        let flacCut = try AVAudioFile(forReading: flac).length
        let wavCut = try AVAudioFile(forReading: wav).length

        // This is why the FLAC is read rather than measured: its length is
        // the song's, not the file's.
        #expect(flacCut == flacFull)
        // A growing WAV can be measured: what the reader says is on disk is.
        #expect(wavCut < wavFull)
    }

    private static func write(frames: Int, ext: String, settings: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("growing-\(UUID().uuidString).\(ext)")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let chunk = 44_100
        var written = 0
        var generator = SystemRandomNumberGenerator()
        while written < frames {
            let count = min(chunk, frames - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let data = buffer.floatChannelData![0]
            // Noise, so a lossless encoder cannot shrink it to nothing and
            // "40% of the bytes" means something.
            for i in 0..<count { data[i] = Float.random(in: -0.5...0.5, using: &generator) }
            try file.write(from: buffer)
            written += count
        }
        return url
    }

    private static func truncate(_ url: URL, toFraction fraction: Double) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(Double(size.int64Value) * fraction))
    }

    // MARK: playback-16

    @Test("The start gate is a few seconds of the stream's own bit rate")
    func gateIsSizedInSeconds() {
        // 128 kbps is 16,000 bytes a second: eight seconds is 128 KB, not the
        // 1.5 MB (98 seconds) it used to wait for.
        #expect(GrowingFile.startBytes(kbps: 128) == 128_000)
        #expect(GrowingFile.startBytes(kbps: 320) == 320_000)
        #expect(GrowingFile.startBytes(kbps: 64) == 64_000)
    }

    @Test("Never more than the old fixed figure, never so little the handover is not worth it")
    func gateIsBounded() {
        #expect(GrowingFile.startBytes(kbps: 1_411) == 1_411_000, "CD-quality lossless: eight seconds, just under the ceiling")
        #expect(GrowingFile.startBytes(kbps: 2_000) == GrowingFile.maximumStartBytes)
        #expect(GrowingFile.startBytes(kbps: 9_216) == GrowingFile.maximumStartBytes)
        #expect(GrowingFile.startBytes(kbps: 8) == GrowingFile.minimumStartBytes)
        #expect(GrowingFile.startBytes(kbps: nil) == GrowingFile.maximumStartBytes)
        #expect(GrowingFile.startBytes(kbps: 0) == GrowingFile.maximumStartBytes)
        #expect(GrowingFile.startBytes(kbps: -5) == GrowingFile.maximumStartBytes)
    }

    @Test("A short conversion is announced after seconds of audio, not after 94 seconds' worth of bytes")
    func shortConversionsStartEarly() {
        // A 60-second Opus-128 conversion is about 960 KB in all. Under the old
        // gate (1,500,000) it never announced; now it does, at 128 KB.
        let total: Int64 = 960_000
        #expect(total < GrowingFile.maximumStartBytes)
        #expect(GrowingFile.startBytes(kbps: 128) < total)
    }

    @Test("A file that is nearly here is not handed over part-way; an unknown total is always worth it")
    func nearlyComplete() {
        #expect(GrowingFile.isNearlyComplete(total: 250_000, startBytes: 128_000))
        #expect(!GrowingFile.isNearlyComplete(total: 257_000, startBytes: 128_000))
        #expect(!GrowingFile.isNearlyComplete(total: nil, startBytes: 128_000))
    }
}
