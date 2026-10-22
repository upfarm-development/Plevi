import Foundation
import Testing
import PleviDomain
@testable import PleviSubsonicProvider

@Suite struct ProxyInterceptionTests {
    private let url = URL(string: "https://music.example.com/rest/ping.view")!

    private func html(_ body: String) -> Data { Data(body.utf8) }

    @Test func htmlContentTypeIsTreatedAsAnAuthWall() {
        #expect(SubsonicClient.isInterceptedByProxy(
            mimeType: "text/html",
            data: html("<!DOCTYPE html><html><body>Sign in</body></html>")
        ))
    }

    @Test func htmlWithACharsetParameterIsStillHTML() {
        #expect(SubsonicClient.isInterceptedByProxy(
            mimeType: "text/html; charset=utf-8",
            data: Data()
        ))
    }

    /// Some proxies omit or mislabel the content type; the body still says.
    @Test func anHTMLBodyIsRecognisedWithoutAContentType() {
        #expect(SubsonicClient.isInterceptedByProxy(
            mimeType: nil,
            data: html("\n  <!doctype html>\n<html>")
        ))
    }

    @Test func aSubsonicJSONResponseIsNotAnAuthWall() {
        #expect(!SubsonicClient.isInterceptedByProxy(
            mimeType: "application/json",
            data: html(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#)
        ))
    }

    @Test func binaryArtworkIsNotAnAuthWall() {
        #expect(!SubsonicClient.isInterceptedByProxy(
            mimeType: "image/jpeg",
            data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        ))
    }

    /// The whole point: a login page must not surface as "wrong password",
    /// which would send the user off changing credentials that are fine.
    @Test func aLoginPageSurfacesAsSignInRequiredRatherThanBadCredentials() throws {
        #expect(throws: ProviderError.proxySignInRequired(url: url)) {
            try SubsonicClient.decodePayload(
                html("<!DOCTYPE html><html><body>Pangolin</body></html>"),
                httpStatus: 401,
                mimeType: "text/html",
                url: url
            )
        }
    }

    @Test func aRealSubsonicErrorStillSurfacesNormally() {
        #expect(throws: ProviderError.notAuthenticated(.wrongCredentials)) {
            try SubsonicClient.decodePayload(
                html(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#),
                httpStatus: 200,
                mimeType: "application/json",
                url: url
            )
        }
    }
}

/// What a song and a record actually carry about *when*, and what the rating
/// floor makes of what they carry about *how good*.
@Suite struct SubsonicEraAndRatingTests {
    private let server = ServerID()

    private func song(_ json: String) throws -> ChildDTO {
        try JSONDecoder().decode(ChildDTO.self, from: Data(json.utf8))
    }

    // MARK: Dates

    /// The item date is specified as an object, and is not always sent as
    /// one. Decoded strictly, a string here does not cost the date — it
    /// costs the entire response, and the library looks empty.
    @Test("An item date survives whatever shape the server sent it in")
    func lenientItemDates() throws {
        func year(_ raw: String) throws -> Int? {
            try JSONDecoder().decode(ItemDateDTO.self, from: Data(raw.utf8)).year
        }
        #expect(try year(#"{"year":1973,"month":5,"day":16}"#) == 1973)
        #expect(try year(#"{"year":1973}"#) == 1973)
        #expect(try year(#""1973-05-16""#) == 1973)
        #expect(try year(#""1973""#) == 1973)
        #expect(try year("1973") == 1973)
        // Unrecognisable is an absent date, not a thrown response.
        #expect(try year(#""sometime""#) == nil)
        #expect(try year("{}") == nil)
    }

    @Test("A song carries its own original year where the server tags one")
    func songOriginalYear() throws {
        let tagged = try song(#"""
        {"id":"1","title":"Soul Gold Opener","year":2011,
         "originalReleaseDate":{"year":1973,"month":1,"day":1}}
        """#)
        #expect(tagged.domain(server: server).originalYear == 1973)

        // The plain-integer spelling some servers use instead.
        let plain = try song(#"{"id":"2","title":"Other","year":2011,"originalYear":1975}"#)
        #expect(plain.domain(server: server).originalYear == 1975)

        // And the ordinary case: no such tag at all.
        let bare = try song(#"{"id":"3","title":"Bare","year":1994}"#)
        #expect(bare.domain(server: server).originalYear == nil)
        #expect(bare.domain(server: server).year == 1994)
    }

    // MARK: Tempo

    /// OpenSubsonic carries `bpm` where the file itself was tagged with one, which is what a
    /// library tagged for DJing already has.
    @Test("A song carries the tempo its server read off the file")
    func songBpm() throws {
        let tagged = try song(#"{"id":"1","title":"Four On The Floor","bpm":128}"#)
        #expect(tagged.domain(server: server).bpm == 128)

        let bare = try song(#"{"id":"2","title":"Untagged"}"#)
        #expect(bare.domain(server: server).bpm == nil)
    }

    // MARK: Ratings

    /// Navidrome sends whole stars, so the floor falls between two of them: three stars is in, two
    /// is out, and there is no half-star value on this backend that could land exactly on the line
    /// from the server's side.
    @Test("Whole stars land either side of the floor where they should")
    func floorOnSubsonicScale() throws {
        func rating(_ stars: Int) throws -> Double? {
            let dto = try song(#"{"id":"1","title":"T","userRating":\#(stars)}"#)
            return dto.domain(server: server).rating?.value
        }
        #expect(try rating(3) == 3.0)
        #expect(try (rating(3) ?? 0) >= 2.5)
        #expect(try rating(2) == 2.0)
        #expect(try (rating(2) ?? 0) < 2.5)
        // Nothing sent at all is unrated, which the floor lets through.
        let bare = try song(#"{"id":"1","title":"T"}"#)
        #expect(bare.domain(server: server).rating == nil)
    }
}
