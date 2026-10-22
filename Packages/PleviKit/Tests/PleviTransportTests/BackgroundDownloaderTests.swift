import Foundation
import Testing
@testable import PleviTransport

/// What each background task carries with it.
@Suite("Background download task identity")
struct BackgroundDownloaderTests {
    private func roundTrip(id: String, path: String) -> (String?, URL?) {
        let description = BackgroundDownloader.describe(
            id: id,
            destination: URL(fileURLWithPath: path)
        )
        return (
            BackgroundDownloader.identifier(inDescription: description),
            BackgroundDownloader.destination(inDescription: description)
        )
    }

    @Test("An id and a destination survive the round trip")
    func plain() {
        let (id, destination) = roundTrip(id: "track-42|orig", path: "/tmp/downloads/abc.flac")
        #expect(id == "track-42|orig")
        #expect(destination?.path == "/tmp/downloads/abc.flac")
    }

    @Test("So does a path with spaces and punctuation in it")
    func awkwardPath() {
        let path = "/tmp/Plevi Downloads/Sgt. Pepper's (2019 Mix)/01 track.flac"
        let (id, destination) = roundTrip(id: "t1", path: path)
        #expect(id == "t1")
        #expect(destination?.path == path)
    }

    @Test("A description that is missing or malformed yields nothing")
    func malformed() {
        #expect(BackgroundDownloader.identifier(inDescription: nil) == nil)
        #expect(BackgroundDownloader.destination(inDescription: nil) == nil)
        #expect(BackgroundDownloader.destination(inDescription: "id-only") == nil)
        #expect(BackgroundDownloader.identifier(inDescription: "") == nil)
        // An id with nothing after it is not a usable task either.
        #expect(BackgroundDownloader.destination(inDescription: "id\n") == nil)
    }
}
