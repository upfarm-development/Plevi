import Foundation
import Testing
import PleviDomain
import PleviTransport
import PleviProviderContract
@testable import PleviSubsonicProvider

private func makeProvider(
    credentials: SubsonicCredentials = .usernamePassword(username: "demo", password: "sesame")
) -> (SubsonicProvider, FakeSubsonicServer) {
    let fake = FakeSubsonicServer()
    let config = ServerConfig(
        name: "Fake",
        addresses: .remote(URL(string: "https://fake.example")!)
    )
    let provider = SubsonicProvider(config: config, credentials: credentials, transport: fake)
    return (provider, fake)
}

// MARK: - Contract

@Suite struct SubsonicContractTests {
    @Test func subsonicProviderPassesEveryContractCheck() async throws {
        let (provider, _) = makeProvider()
        // Probe first so capability-gated checks (lyrics) run un-skipped.
        _ = try await provider.testConnection()
        let results = await ProviderContract.run(against: provider)

        let failures = results.filter {
            if case .failed = $0.outcome { return true }
            return false
        }
        let skips = results.filter {
            if case .skipped = $0.outcome { return true }
            return false
        }
        #expect(
            failures.isEmpty,
            "failed checks: \(failures.map { "\($0.name): \($0.outcome)" }.joined(separator: "; "))"
        )
        // The fake advertises songLyrics + transcodeOffset, so after probing
        // nothing the suite gates on is missing except capabilities Subsonic
        // genuinely lacks (none today).
        #expect(skips.isEmpty, "unexpected skips: \(skips.map(\.name).joined(separator: "; "))")
    }

    @Test func apiKeyAuthenticatedProviderAlsoPassesContract() async throws {
        let (provider, _) = makeProvider(credentials: .apiKey("key-123"))
        _ = try await provider.testConnection()
        let results = await ProviderContract.run(against: provider)
        let failures = results.filter {
            if case .failed = $0.outcome { return true }
            return false
        }
        #expect(
            failures.isEmpty,
            "failed checks: \(failures.map { "\($0.name): \($0.outcome)" }.joined(separator: "; "))"
        )
    }
}

// MARK: - Auth primitives

@Suite struct SubsonicAuthTests {
    @Test func saltedTokenMatchesSubsonicDocumentationVector() {
        // From the Subsonic API docs: password "sesame", salt "c19b2d".
        #expect(
            SubsonicClient.saltedToken(password: "sesame", salt: "c19b2d")
                == "26719a1196d2a940705a59634eb18eab"
        )
    }

    @Test func saltIsHexAndLongEnough() {
        let salt = SubsonicClient.randomSalt()
        #expect(salt.count == 16)
        #expect(salt.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(SubsonicClient.randomSalt() != SubsonicClient.randomSalt())
    }

    @Test func wrongPasswordSurfacesAsWrongCredentials() async throws {
        let (provider, _) = makeProvider(
            credentials: .usernamePassword(username: "demo", password: "wrong")
        )
        await #expect(throws: ProviderError.notAuthenticated(.wrongCredentials)) {
            _ = try await provider.artists()
        }
    }

    @Test func invalidAPIKeySurfacesTyped() async throws {
        let (provider, _) = makeProvider(credentials: .apiKey("not-the-key"))
        await #expect(throws: ProviderError.notAuthenticated(.invalidAPIKey)) {
            _ = try await provider.artists()
        }
    }
}

// MARK: - Security invariants

@Suite struct SubsonicSecurityTests {
    private func requestText(_ request: URLRequest) -> String {
        var text = request.url?.absoluteString ?? ""
        if let body = request.httpBody, let bodyText = String(data: body, encoding: .utf8) {
            text += "\n" + bodyText
        }
        return text
    }

    @Test func passwordNeverAppearsInAnyRequest() async throws {
        let (provider, fake) = makeProvider()
        _ = try await provider.testConnection()
        _ = try await provider.artists()
        _ = try await provider.search("light", limit: 5)
        let requests = await fake.recordedRequests()
        #expect(!requests.isEmpty)
        for request in requests {
            let text = requestText(request)
            #expect(!text.contains("sesame"), "password leaked into request: \(Redactor.redacted(request))")
            #expect(!text.contains("p="), "plaintext password parameter present")
        }
    }

    @Test func formPostMovesAuthOutOfURLs() async throws {
        let (provider, fake) = makeProvider()
        _ = try await provider.testConnection()
        _ = try await provider.artists()
        let requests = await fake.recordedRequests()
        // After probing, API calls must be POSTs with auth in the body, not
        // the URL — keeps tokens out of reverse-proxy access logs.
        let apiCalls = requests.filter { $0.url?.lastPathComponent == "getArtists" }
        #expect(!apiCalls.isEmpty)
        for request in apiCalls {
            #expect(request.httpMethod == "POST")
            let url = request.url?.absoluteString ?? ""
            #expect(!url.contains("t="), "token in URL despite formPost")
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            #expect(body.contains("t=") && body.contains("s="))
        }
    }

    @Test func apiKeyRequestsOmitUsername() async throws {
        let (provider, fake) = makeProvider(credentials: .apiKey("key-123"))
        _ = try await provider.artists()
        let requests = await fake.recordedRequests()
        for request in requests {
            let params = FakeSubsonicServer.parameters(of: request)
            #expect(params["u"] == nil, "u parameter sent alongside apiKey")
        }
    }

    @Test func mediaRequestsCarrySaltedTokenNotPassword() async throws {
        let (provider, _) = makeProvider()
        _ = try await provider.testConnection()
        let trackID = MediaID(server: provider.serverID, rawValue: "t2")
        let request = try await provider.streamRequest(
            for: trackID,
            options: StreamOptions(maxBitRateKbps: 320, transcodeTo: .mp3)
        )
        let url = request.url?.absoluteString ?? ""
        #expect(url.contains("format=mp3"))
        #expect(url.contains("maxBitRate=320"))
        #expect(url.contains("t=") && url.contains("s="))
        #expect(!url.contains("sesame"))
    }

    @Test func rawStreamRequestDisablesTranscoding() async throws {
        let (provider, _) = makeProvider()
        let trackID = MediaID(server: provider.serverID, rawValue: "t1")
        let request = try await provider.streamRequest(for: trackID, options: .original)
        #expect(request.url?.absoluteString.contains("format=raw") == true)
    }

    @Test func foreignServerIDsAreRejected() async throws {
        let (provider, _) = makeProvider()
        let foreign = MediaID(server: ServerID(), rawValue: "t1")
        await #expect(throws: ProviderError.notFound) {
            _ = try await provider.streamRequest(for: foreign, options: .original)
        }
    }
}

// MARK: - Decoding and error mapping

@Suite struct SubsonicDecodingTests {
    @Test func errorEnvelopeMapsToTypedErrors() {
        let cases: [(Int, ProviderError)] = [
            (40, .notAuthenticated(.wrongCredentials)),
            (41, .notAuthenticated(.tokenAuthUnsupported)),
            (44, .notAuthenticated(.invalidAPIKey)),
            (50, .notAuthorized),
            (70, .notFound),
        ]
        for (code, expected) in cases {
            let mapped = SubsonicClient.mapError(
                SubsonicErrorDTO(code: code, message: nil, helpUrl: nil)
            )
            #expect(mapped == expected)
        }
    }

    @Test func htmlLoginPageBecomesMalformedResponse() {
        let html = Data("<html><body>Sign in</body></html>".utf8)
        #expect(throws: ProviderError.malformedResponse(details: "response was not a Subsonic JSON envelope")) {
            _ = try SubsonicClient.decodePayload(html, httpStatus: 200)
        }
    }

    @Test func proxyStatusCodesBecomeTypedErrors() {
        #expect(throws: ProviderError.notAuthenticated(.wrongCredentials)) {
            _ = try SubsonicClient.decodePayload(Data(), httpStatus: 401)
        }
        #expect(throws: ProviderError.notAuthorized) {
            _ = try SubsonicClient.decodePayload(Data(), httpStatus: 403)
        }
    }

    @Test func lenientDatesParseBothPrecisions() {
        #expect(SubsonicDates.parse("2026-08-16T10:00:00Z") != nil)
        #expect(SubsonicDates.parse("2026-08-16T10:00:00.123Z") != nil)
        #expect(SubsonicDates.parse("not a date") == nil)
        #expect(SubsonicDates.parse(nil) == nil)
    }

    @Test func playlistEntryEncodingRoundTrips() {
        let encoded = SubsonicProvider.encodeEntry(index: 7, songID: "song#weird/id")
        let decoded = SubsonicProvider.decodeEntry(encoded)
        #expect(decoded?.index == 7)
        #expect(decoded?.songID == "song#weird/id")
        #expect(SubsonicProvider.decodeEntry("garbage") == nil)
    }

    @Test func lyricsMapMillisecondsToSeconds() async throws {
        let (provider, _) = makeProvider()
        _ = try await provider.testConnection()
        let lyrics = try await provider.lyrics(
            for: MediaID(server: provider.serverID, rawValue: "t1")
        )
        let unwrapped = try #require(lyrics)
        #expect(unwrapped.synced)
        #expect(unwrapped.offset == 0.1)
        #expect(unwrapped.lines.first?.start == 0.5)
    }
}

// MARK: - What a sync asks for

@Suite("Subsonic, syncing")
struct SubsonicSyncTests {
    @Test("A page of songs asks for songs alone")
    func songsWithoutTheRestOfTheLibrary() async throws {
        let (provider, fake) = makeProvider()
        let songs = try await provider.tracks(offset: 0, limit: 500)
        let asked = FakeSubsonicServer.parameters(of: try #require(await fake.requests.last))

        // The saving is in the request, not in what comes back: the same round trip, carrying songs
        // instead of songs plus the whole artist list plus the whole album list, on every one of
        // the 124 pages a large library takes.
        #expect(asked["artistCount"] == ["0"])
        #expect(asked["albumCount"] == ["0"])
        #expect(asked["songCount"] == ["500"])

        let everything = try await provider.search("", limit: 500, offset: 0)
        #expect(songs.map(\.id) == everything.tracks.map(\.id))
        #expect(!everything.artists.isEmpty)
    }

    @Test("A later page asks for a later slice of the songs")
    func pagingAsksForTheRightSlice() async throws {
        let (provider, fake) = makeProvider()
        let all = try await provider.tracks(offset: 0, limit: 500)
        let second = try await provider.tracks(offset: 1, limit: 2)
        let asked = FakeSubsonicServer.parameters(of: try #require(await fake.requests.last))

        #expect(asked["songOffset"] == ["1"])
        #expect(second.map(\.id) == Array(all.dropFirst().prefix(2)).map(\.id))
    }

    @Test("The song count comes from the server's own scan")
    func countsComeFromTheScan() async throws {
        let (provider, _) = makeProvider()
        let counts = try await provider.libraryCounts()
        let songs = try await provider.tracks(offset: 0, limit: 500)

        #expect(counts.tracks == songs.count)
        // Nothing invented for the two the Subsonic contract cannot answer.
        #expect(counts.artists == nil)
        #expect(counts.albums == nil)
    }

    @Test("The change token is the last scan, as the server wrote it")
    func theTokenIsTheLastScan() async throws {
        let (provider, _) = makeProvider()
        #expect(try await provider.libraryChangeToken() == "subsonic:\(FakeSubsonicServer.lastScan)")
    }

    @Test("A MusicBrainz-matched artist carries its id; an unmatched one carries none")
    func musicBrainzIDIsCarriedThrough() async throws {
        let (provider, fake) = makeProvider()
        await fake.setMusicBrainzID("70248960-cb53-4ea4-943a-edb18f9c0ce9", forArtist: "ar1")

        let artists = try await provider.artists()
        let matched = try #require(artists.first { $0.id.rawValue == "ar1" })
        let unmatched = try #require(artists.first { $0.id.rawValue == "ar2" })

        #expect(matched.musicBrainzID == "70248960-cb53-4ea4-943a-edb18f9c0ce9")
        #expect(unmatched.musicBrainzID == nil)
    }

    @Test("A server part way through a scan says so, and is not vouched for")
    func aScanningServerIsReportedAsSuch() async throws {
        let (provider, fake) = makeProvider()
        await fake.setScanning(true)

        // The count is climbing towards the truth and the library behind it is moving, so the sync
        // must be told — a walk that matched this number would look complete and would take
        // everything the scan has not reached yet with it.
        #expect(try await provider.libraryCounts().isRescanning)
        // And the token is withheld: the last scan's date has not moved yet,
        // so it would say "nothing has changed" about a library that is
        // changing as it is read.
        #expect(try await provider.libraryChangeToken() == nil)

        await fake.setScanning(false)
        #expect(try await provider.libraryCounts().isRescanning == false)
        #expect(try await provider.libraryChangeToken() != nil)
    }
}
