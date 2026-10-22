import Foundation
import Testing
@testable import PleviAudio

@Suite("The extension a downloaded song carries (downloads-04)")
struct AudioContainerTests {
    @Test("Codec names, containers and MIME types map to a playable extension")
    func labels() {
        #expect(AudioContainer.fileExtension(for: "audio/mpeg") == "mp3")
        #expect(AudioContainer.fileExtension(for: "MP3") == "mp3")
        #expect(AudioContainer.fileExtension(for: "audio/flac") == "flac")
        #expect(AudioContainer.fileExtension(for: "audio/x-flac") == "flac")
        #expect(AudioContainer.fileExtension(for: "aac") == "m4a")
        #expect(AudioContainer.fileExtension(for: "alac") == "m4a")
        #expect(AudioContainer.fileExtension(for: "audio/mp4") == "m4a")
        #expect(AudioContainer.fileExtension(for: "opus") == "ogg")
        #expect(AudioContainer.fileExtension(for: "audio/ogg") == "ogg")
        #expect(AudioContainer.fileExtension(for: "audio/x-wav") == "wav")
        #expect(AudioContainer.fileExtension(for: "audio/x-aiff") == "aiff")
    }

    @Test("A label that names nothing playable gives nothing, not a made-up extension")
    func unknown() {
        #expect(AudioContainer.fileExtension(for: nil) == nil)
        #expect(AudioContainer.fileExtension(for: "") == nil)
        #expect(AudioContainer.fileExtension(for: "application/octet-stream") == nil)
        #expect(AudioContainer.fileExtension(for: "wma") == nil)
    }

    @Test("A URL extension is only trusted when AVFoundation opens it")
    func playableExtensions() {
        #expect(AudioContainer.playableExtensions.contains("flac"))
        #expect(!AudioContainer.playableExtensions.contains("view"))
        #expect(!AudioContainer.playableExtensions.contains("audio"))
    }

    @Test("The first bytes say what a file is, whatever it was called")
    func sniffing() {
        func head(_ bytes: [UInt8], pad: Int = 12) -> Data { Data(bytes + Array(repeating: 0, count: pad)) }
        #expect(AudioContainer.sniff(head(Array("ID3".utf8) + [4, 0])) == "mp3")
        #expect(AudioContainer.sniff(head([0xFF, 0xFB, 0x90, 0x00])) == "mp3")
        #expect(AudioContainer.sniff(head([0xFF, 0xF1, 0x50, 0x80])) == "aac")
        #expect(AudioContainer.sniff(head(Array("fLaC".utf8))) == "flac")
        #expect(AudioContainer.sniff(head(Array("OggS".utf8))) == "ogg")
        #expect(AudioContainer.sniff(head([0, 0, 0, 0x20] + Array("ftypM4A ".utf8))) == "m4a")
        #expect(AudioContainer.sniff(head(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8))) == "wav")
        #expect(AudioContainer.sniff(head(Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFF".utf8))) == "aiff")
        #expect(AudioContainer.sniff(head(Array("caff".utf8))) == "caf")
    }

    @Test("Markup, JSON and short heads are not audio")
    func sniffRefusals() {
        #expect(AudioContainer.sniff(Data("<html>".utf8)) == nil)
        #expect(AudioContainer.sniff(Data(#"{"subsonic-response""#.utf8)) == nil)
        #expect(AudioContainer.sniff(Data([0xFF])) == nil)
        #expect(AudioContainer.sniff(Data()) == nil)
    }
}
