import Foundation
import Testing
@testable import PleviPlexProvider

/// What a rejected write tells you afterwards.
@Suite("What a Plex error says")
struct PlexErrorBodyTests {
    /// The bare HTML page Plex sends for a request it will not process. It
    /// carries no reason of its own, which is itself the useful signal — the
    /// request was rejected outright rather than by the API.
    private static let badRequestPage = """
        <html><head><title>Bad Request</title></head>\
        <body><h1>400 Bad Request</h1></body></html>
        """

    @Test("The server's own words are carried through")
    func repeatsTheBody() {
        let said = PlexClient.explanation(from: Data(Self.badRequestPage.utf8))

        #expect(said.contains("400 Bad Request"))
        #expect(said.hasPrefix(" — "))
    }

    @Test("An empty body adds nothing rather than a dangling dash")
    func emptyBody() {
        #expect(PlexClient.explanation(from: Data()).isEmpty)
        #expect(PlexClient.explanation(from: Data("   \n ".utf8)).isEmpty)
    }

    /// The one thing that must never come back out of an error, whatever
    /// route it took to get in. Error text is shown on screen, kept in the
    /// app's own list of recent problems, and pasted into bug reports.
    @Test("A token in the body never reaches the message")
    func redactsTokens() {
        let leaky = """
            <error>Invalid request to \
            /playlists/1/items?X-Plex-Token=FAKETOKENFAKETOKEN1&uri=server://x</error>
            """

        let said = PlexClient.explanation(from: Data(leaky.utf8))

        #expect(!said.contains("FAKETOKENFAKETOKEN1"))
        // Still says enough to be worth reading.
        #expect(said.contains("/playlists/1/items"))
    }

    @Test("A body long enough to be a whole page is cut short")
    func trimsLongBodies() {
        let huge = String(repeating: "x", count: 5_000)

        let said = PlexClient.explanation(from: Data(huge.utf8))

        #expect(said.count < 500)
    }
}
