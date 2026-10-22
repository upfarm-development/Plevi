import AVFoundation
import Foundation
import Testing
@testable import PleviAudio

@Suite("Ogg Vorbis")
struct VorbisDecoderTests {
    /// The first page of an Ogg Vorbis stream: "OggS", a header whose segment
    /// table is one entry long, then "\u{1}vorbis" and the rest.
    private func oggHead(_ marker: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 27)
        bytes[0...3] = [0x4F, 0x67, 0x67, 0x53]
        bytes[26] = 1
        bytes.append(30)
        bytes += marker
        bytes += [UInt8](repeating: 0, count: 40)
        return Data(bytes)
    }

    @Test("a Vorbis identification header is recognised")
    func vorbisHead() {
        #expect(VorbisFile.isVorbis(head: oggHead([0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73])))
    }

    @Test("Ogg Opus, which iOS plays, is not Vorbis")
    func opusHead() {
        #expect(!VorbisFile.isVorbis(head: oggHead(Array("OpusHead".utf8))))
    }

    @Test("anything else, and anything too short, is not Vorbis")
    func notVorbis() {
        #expect(!VorbisFile.isVorbis(head: Data("fLaC".utf8)))
        #expect(!VorbisFile.isVorbis(head: Data()))
        #expect(!VorbisFile.isVorbis(head: Data([0x4F, 0x67, 0x67, 0x53])))
    }

    @Test("a file that is not Vorbis does not decode")
    func garbage() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "x.ogg")
        try Data(repeating: 7, count: 4096).write(to: source)
        #expect(throws: VorbisDecoder.DecodeError.self) {
            try VorbisDecoder.decode(source, to: dir.appending(path: "x.caf"))
        }
    }

    @Test("the cache hands back a file it cannot decode as it is")
    func cacheFallsBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "x.ogg")
        try oggHead([0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]).write(to: source)
        let cache = DecodedAudioCache(directory: dir.appending(path: "decoded"))
        let result = await cache.playable(source)
        #expect(result.url == source)
        #expect(result.source == nil)
    }

    /// A real file, when one is named: `PLEVI_VORBIS_SAMPLE=/path/to.ogg swift test`.
    @Test("a real Vorbis file decodes to PCM of the right length")
    func realFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLEVI_VORBIS_SAMPLE"] else { return }
        let source = URL(fileURLWithPath: path)
        let cache = DecodedAudioCache(directory: FileManager.default.temporaryDirectory.appending(path: "PleviDecodedTest-\(UUID().uuidString)"))
        let result = await cache.playable(source)
        let info = try #require(result.source)
        #expect(result.url.pathExtension == "caf")
        #expect(info.channels == 2)
        #expect(info.frames > 0)
        let again = await cache.playable(source)
        #expect(again.url == result.url)
        print("DECODED", info, result.url.path)
    }

    /// As above, for the progressive path: a file readable while still being
    /// written, and whole at the end.
    @Test("a real Vorbis file decodes progressively into a readable CAF")
    func realFileProgressively() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLEVI_VORBIS_SAMPLE"] else { return }
        let source = URL(fileURLWithPath: path)
        let cache = DecodedAudioCache(directory: FileManager.default.temporaryDirectory.appending(path: "PleviDecodedTest-\(UUID().uuidString)"))
        let finished = LockedFlag()
        let begun = Date()
        let early = await cache.playableEarly(source) { ok in finished.set(ok) }
        let firstSound = Date().timeIntervalSince(begun)
        let info = try #require(early.playable.source)
        // Readable at once, while the decode may still be running.
        let reader = try AVAudioFile(forReading: early.playable.url)
        #expect(reader.length > 0)
        #expect(reader.processingFormat.channelCount == 2)
        print("EARLY first audio after \(Int(firstSound * 1000)) ms, complete=\(early.isComplete), readable frames=\(reader.length), whole=\(info.frames)")
        // Wait for the rest, then the copy must be the whole song.
        for _ in 0..<600 where !early.isComplete && !finished.isSet { try await Task.sleep(for: .milliseconds(50)) }
        let whole = try AVAudioFile(forReading: early.playable.url)
        print("DONE total \(Int(Date().timeIntervalSince(begun) * 1000)) ms, frames=\(whole.length)")
        #expect(whole.length == info.frames || info.frames == 0 || abs(whole.length - info.frames) < 4096)
        // And a second ask is answered from the finished copy.
        let again = await cache.playable(source)
        #expect(again.url == early.playable.url)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ ok: Bool) { lock.lock(); value = ok; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
}
