import Foundation
import Testing
@testable import PleviTransport

/// "This response is not audio": the check the download path (D-03) and the
/// play cache share.
@Suite("Response is not audio")
struct AudioResponseCheckTests {
    private let mp3 = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]) + Data(repeating: 0, count: 200)
    private let flac = Data("fLaC".utf8) + Data(repeating: 0, count: 200)

    private func verdict(
        type: String? = "audio/mpeg", announced: Int64? = nil, size: Int64? = nil, head: Data? = nil
    ) -> NotAudioReason? {
        let body = head ?? mp3
        return AudioResponseCheck.verdict(
            contentType: type, announcedLength: announced, size: size ?? Int64(body.count), head: body
        )
    }

    @Test("Audio in the usual containers passes, whatever it is labelled")
    func audioPasses() {
        #expect(verdict() == nil)
        for type in ["audio/flac", "audio/mp4", "audio/ogg", "video/mp4", "application/octet-stream",
                     "binary/octet-stream", "application/ogg", "audio/x-m4a", nil] {
            #expect(verdict(type: type, head: flac) == nil, "\(type ?? "no type")")
        }
    }

    @Test("Text, JSON and XML labels are never a song")
    func textualLabels() {
        for type in ["text/html", "text/html; charset=utf-8", "TEXT/PLAIN", "application/json",
                     "application/json; charset=utf-8", "application/xml", "text/xml",
                     "application/problem+json", "application/atom+xml", "application/xhtml+xml"] {
            #expect(verdict(type: type) == .textual(contentType: type), "\(type)")
        }
    }

    @Test("An empty body is not a song")
    func empty() {
        #expect(verdict(size: 0, head: Data()) == .empty)
    }

    @Test("Markup and server error envelopes are recognised by their first bytes, even labelled as audio")
    func sniffing() {
        for text in [
            "<html><body>Sign in</body></html>", "<!DOCTYPE html>", "<?xml version=\"1.0\"?><MediaContainer/>",
            "  \n\t<html>", "\u{FEFF}<html>",
            #"{"subsonic-response":{"status":"failed"}}"#, #"{"MediaContainer":{"size":0}}"#,
            #"{"error":"nope"}"#,
        ] {
            #expect(verdict(head: Data(text.utf8)) == .markup, "\(text)")
        }
    }

    @Test("Bytes that merely start like text but are not an envelope pass")
    func notEveryBraceIsAnError() {
        #expect(verdict(head: Data("{not json".utf8) + Data(repeating: 0, count: 100)) == nil)
        #expect(verdict(head: Data([0xFF, 0xFB, 0x90, 0x00]) + Data(repeating: 0, count: 100)) == nil)
    }

    @Test("A body the length the server announced passes; a different length is a damaged transfer")
    func lengthAgreement() {
        #expect(verdict(announced: Int64(mp3.count)) == nil)
        #expect(verdict(announced: 10_000) == .lengthMismatch(expected: 10_000, actual: Int64(mp3.count)))
        #expect(verdict(announced: 0) == nil, "no announced length is nothing to compare")
        #expect(verdict(announced: nil) == nil)
    }

    @Test("Only a web page reads as a sign-in wall")
    func wallReading() {
        #expect(NotAudioReason.markup.looksLikeAWebPage)
        #expect(NotAudioReason.textual(contentType: "text/html").looksLikeAWebPage)
        #expect(!NotAudioReason.textual(contentType: "application/json").looksLikeAWebPage)
        #expect(!NotAudioReason.empty.looksLikeAWebPage)
        #expect(!NotAudioReason.lengthMismatch(expected: 2, actual: 1).looksLikeAWebPage)
    }

    @Test("A file on disk is judged with the response that produced it")
    func fileVerdict() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ARC-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "f")
        let ok = URL(string: "https://a.example/x")!

        try mp3.write(to: url)
        let audio = HTTPURLResponse(url: ok, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "audio/mpeg", "Content-Length": "\(mp3.count)",
        ])
        #expect(AudioResponseCheck.verdict(forFileAt: url, response: audio) == nil)

        let short = HTTPURLResponse(url: ok, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "audio/mpeg", "Content-Length": "\(mp3.count * 4)",
        ])
        #expect(AudioResponseCheck.verdict(forFileAt: url, response: short) == .lengthMismatch(expected: Int64(mp3.count * 4), actual: Int64(mp3.count)))

        // A body the server compressed on the way is not comparable to its length.
        let gzipped = HTTPURLResponse(url: ok, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "audio/mpeg", "Content-Length": "\(mp3.count * 4)", "Content-Encoding": "gzip",
        ])
        #expect(AudioResponseCheck.verdict(forFileAt: url, response: gzipped) == nil)

        try Data("<html>".utf8).write(to: url)
        #expect(AudioResponseCheck.verdict(forFileAt: url, response: audio) == .markup)

        try Data().write(to: url)
        #expect(AudioResponseCheck.verdict(forFileAt: url, response: audio) == .empty)
    }
}
