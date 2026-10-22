import Foundation
import Testing
@testable import PleviTransport

@Suite("What the watch checks a fetched song file for (watch-03)")
struct WatchFetchCheckTests {
    /// The watch streams a fetch straight to a file with `download(to:)`,
    /// which hands back no response, so the check has to work from the file
    /// alone.
    private func file(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "watch-fetch-\(UUID().uuidString).audio")
        try bytes.write(to: url)
        return url
    }

    @Test("A Subsonic error envelope saved as a song is refused")
    func envelopeIsNotASong() throws {
        let url = try file(Data(#"{"subsonic-response":{"status":"failed"}}"#.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AudioResponseCheck.verdict(forFileAt: url, response: nil) == .markup)
    }

    @Test("A sign-in page saved as a song is refused as a web page")
    func loginPageIsNotASong() throws {
        let url = try file(Data("<!doctype html><html>Sign in</html>".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let verdict = AudioResponseCheck.verdict(forFileAt: url, response: nil)
        #expect(verdict == .markup)
        #expect(verdict?.looksLikeAWebPage == true)
    }

    @Test("An empty body is refused")
    func emptyBody() throws {
        let url = try file(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AudioResponseCheck.verdict(forFileAt: url, response: nil) == .empty)
    }

    @Test("A file that starts like an MP3 passes with no response to compare")
    func mp3Passes() throws {
        var bytes = Data("ID3".utf8)
        bytes.append(Data(count: 2_000))
        let url = try file(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AudioResponseCheck.verdict(forFileAt: url, response: nil) == nil)
    }
}
