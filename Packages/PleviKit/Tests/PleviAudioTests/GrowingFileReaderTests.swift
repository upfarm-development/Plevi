import AVFoundation
import Foundation
import Testing
@testable import PleviAudio

/// playback-02: reading a file that is still arriving delivers what the bytes
/// on disk hold, never what the header declares — on real truncated files.
@Suite("Reading a file that is still arriving")
struct GrowingFileReaderTests {
    struct Format: Sendable {
        var name: String
        var ext: String
        var settings: [String: Sendable]
    }

    static let formats: [Format] = [
        Format(name: "FLAC", ext: "flac", settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
        ]),
        Format(name: "CAF", ext: "caf", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]),
        Format(name: "AIFF", ext: "aiff", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true,
        ]),
    ]

    private static let seconds = 12
    private static let rate = 44_100

    /// Noise that is the same every time, so the decoded samples can be
    /// compared with what was written.
    private static func sample(_ frame: Int) -> Float {
        var x = UInt64(truncatingIfNeeded: frame) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        x ^= x >> 33
        return Float(Int16(truncatingIfNeeded: x)) / 32_768 * 0.5
    }

    private static func makeFile(_ format: Format) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString).\(format.ext)")
        let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for second in 0..<seconds {
            let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(rate))!
            buffer.frameLength = AVAudioFrameCount(rate)
            let data = buffer.floatChannelData![0]
            for i in 0..<rate { data[i] = sample(second * rate + i) }
            try file.write(from: buffer)
        }
        return url
    }

    private static func cut(_ url: URL, fraction: Double) throws -> URL {
        let full = try Data(contentsOf: url)
        let cut = FileManager.default.temporaryDirectory
            .appendingPathComponent("cut-\(UUID().uuidString).\(url.pathExtension)")
        try full.prefix(Int(Double(full.count) * fraction)).write(to: cut)
        return cut
    }

    @Test("A truncated lossless file delivers no more than its bytes hold, however much its header declares", arguments: formats)
    func neverPastTheBytes(_ format: Format) throws {
        let whole = try Self.makeFile(format)
        defer { try? FileManager.default.removeItem(at: whole) }
        let declared = Int64(Self.seconds * Self.rate)
        for fraction in [0.1, 0.4, 0.75] {
            let part = try Self.cut(whole, fraction: fraction)
            defer { try? FileManager.default.removeItem(at: part) }
            let read = try #require(GrowingFileReader.read(url: part, from: 0, limit: { declared, _ in declared }))
            #expect(read.declaredLength == declared, "\(format.name): the header still says the whole song")
            #expect(read.needsMoreData, "\(format.name) at \(fraction): the end of the bytes is found")
            // Never more than the fraction of the file that is there (these
            // are constant-rate or noise-filled files), and most of it.
            let ceiling = Int64(Double(declared) * fraction)
            #expect(read.frames <= ceiling, "\(format.name) at \(fraction): \(read.frames) frames > \(ceiling)")
            #expect(read.frames >= ceiling - Int64(Self.rate), "\(format.name) at \(fraction): at most a second is left for the next look")
            #expect(read.frames == read.buffers.reduce(0) { $0 + Int64($1.frameLength) })
        }
    }

    @Test("What is read is the song, sample for sample, not padding", arguments: formats)
    func readsTheRealAudio(_ format: Format) throws {
        let whole = try Self.makeFile(format)
        defer { try? FileManager.default.removeItem(at: whole) }
        let part = try Self.cut(whole, fraction: 0.4)
        defer { try? FileManager.default.removeItem(at: part) }
        let read = try #require(GrowingFileReader.read(url: part, from: 0, limit: { declared, _ in declared }))
        var frame = 0
        var worst: Float = 0
        for buffer in read.buffers {
            let data = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                worst = max(worst, abs(data[i] - Self.sample(frame)))
                frame += 1
            }
        }
        #expect(frame > 0)
        // 16-bit quantisation for the PCM containers; FLAC is exact at 16 bit.
        #expect(worst < 0.001, "\(format.name): the last frame read is as written (error \(worst))")
    }

    @Test("Reading on from where the last look stopped picks up the new bytes", arguments: formats)
    func growsAsBytesArrive(_ format: Format) throws {
        let whole = try Self.makeFile(format)
        defer { try? FileManager.default.removeItem(at: whole) }
        let bytes = try Data(contentsOf: whole)
        let growing = FileManager.default.temporaryDirectory
            .appendingPathComponent("growing-\(UUID().uuidString).\(format.ext)")
        defer { try? FileManager.default.removeItem(at: growing) }

        var cursor: Int64 = 0
        var lastFrames: Int64 = -1
        for fraction in [0.2, 0.5, 0.8, 1.0] {
            try bytes.prefix(Int(Double(bytes.count) * fraction)).write(to: growing)
            let read = try #require(GrowingFileReader.read(url: growing, from: cursor, limit: { declared, _ in declared }))
            cursor += read.frames
            #expect(cursor > lastFrames)
            lastFrames = cursor
            if fraction == 1.0 {
                #expect(cursor == Int64(Self.seconds * Self.rate), "the whole song once the whole file is here")
                #expect(!read.needsMoreData)
            }
        }
    }

    @Test("The limit bounds a read even when far more could be decoded")
    func limitBounds() throws {
        let whole = try Self.makeFile(Self.formats[0])
        defer { try? FileManager.default.removeItem(at: whole) }
        let read = try #require(GrowingFileReader.read(url: whole, from: 0, limit: { _, rate in Int64(rate) * 3 }))
        #expect(read.frames == Int64(Self.rate) * 3)
        #expect(!read.needsMoreData, "stopped by the limit, not by the bytes")
    }

    @Test("A file whose header has not all arrived cannot be read yet")
    func headerNotHereYet() throws {
        let whole = try Self.makeFile(Self.formats[0])
        defer { try? FileManager.default.removeItem(at: whole) }
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: stub) }
        try Data(contentsOf: whole).prefix(10).write(to: stub)
        #expect(GrowingFileReader.read(url: stub, from: 0, limit: { d, _ in d }) == nil)
    }

    @Test("A WAV reports what has arrived, so reading and measuring agree")
    func wavIsMeasurable() throws {
        let format = Format(name: "WAV", ext: "wav", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ])
        let whole = try Self.makeFile(format)
        defer { try? FileManager.default.removeItem(at: whole) }
        let part = try Self.cut(whole, fraction: 0.4)
        defer { try? FileManager.default.removeItem(at: part) }
        let read = try #require(GrowingFileReader.read(url: part, from: 0, limit: { d, _ in d }))
        #expect(read.declaredLength == read.frames || read.declaredLength - read.frames < Int64(Self.rate))
        #expect(read.declaredLength < Int64(Self.seconds * Self.rate))
    }

    @Test("Bytes on disk are read fresh")
    func bytesOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 10).write(to: url)
        #expect(GrowingFileReader.bytesOnDisk(url) == 10)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 90))
        try handle.close()
        #expect(GrowingFileReader.bytesOnDisk(url) == 100)
        #expect(GrowingFileReader.bytesOnDisk(url.appendingPathExtension("missing")) == 0)
    }
}
