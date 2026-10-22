import Foundation
import Testing
@testable import PleviDomain

@Suite struct StarRatingTests {
    @Test func acceptsHalfStepsInRange() {
        #expect(StarRating(0.5) != nil)
        #expect(StarRating(3.5) != nil)
        #expect(StarRating(5.0) != nil)
        #expect(StarRating(stars: 1) != nil)
        #expect(StarRating(stars: 5) != nil)
    }

    @Test func rejectsOutOfRangeAndOffGrid() {
        #expect(StarRating(0.0) == nil)
        #expect(StarRating(5.5) == nil)
        #expect(StarRating(0.7) == nil)
        #expect(StarRating(-1) == nil)
        #expect(StarRating(stars: 0) == nil)
        #expect(StarRating(stars: 6) == nil)
    }

    @Test func wholeStarsRoundsHalves() {
        #expect(StarRating(3.5)?.wholeStars == 4)
        #expect(StarRating(2.0)?.wholeStars == 2)
    }
}

@Suite struct CodableRoundTripTests {
    @Test func mediaIDRoundTrips() throws {
        let id = MediaID(server: ServerID(), rawValue: "al-42/étrange id")
        let decoded = try JSONDecoder().decode(
            MediaID.self,
            from: JSONEncoder().encode(id)
        )
        #expect(decoded == id)
    }

    @Test func albumFilterWithAssociatedValuesRoundTrips() throws {
        let filters: [AlbumFilter] = [
            .recentlyAdded, .genre("Ambient"), .yearRange(from: 1990, to: 1999),
        ]
        let decoded = try JSONDecoder().decode(
            [AlbumFilter].self,
            from: JSONEncoder().encode(filters)
        )
        #expect(decoded == filters)
    }

    @Test func trackRoundTrips() throws {
        let server = ServerID()
        let track = Track(
            id: MediaID(server: server, rawValue: "t9"),
            title: "First Light",
            trackNumber: 1,
            duration: 210,
            codec: "opus",
            replayGain: ReplayGain(trackGain: -6.5, trackPeak: 0.98),
            rating: StarRating(4.5)
        )
        let decoded = try JSONDecoder().decode(
            Track.self,
            from: JSONEncoder().encode(track)
        )
        #expect(decoded == track)
    }
}

@Suite struct CapabilityTests {
    @Test func descriptionListsContainedFlags() {
        let caps: ServerCapabilities = [.ratings, .syncedLyrics]
        #expect(caps.description.contains("ratings"))
        #expect(caps.description.contains("syncedLyrics"))
        #expect(!caps.description.contains("jukebox"))
    }

    @Test func unsupportedDefaultsThrowTyped() async {
        struct MinimalProvider: MusicServerProvider {
            let serverID = ServerID()
            let capabilities: ServerCapabilities = []
            func testConnection() async throws -> ServerInfo { ServerInfo() }
            func artists() async throws -> [Artist] { [] }
            func artist(id: MediaID) async throws -> ArtistDetail {
                throw ProviderError.notFound
            }
            func albums(filter: AlbumFilter, offset: Int, limit: Int) async throws -> [Album] { [] }
            func album(id: MediaID) async throws -> AlbumDetail {
                throw ProviderError.notFound
            }
            func track(id: MediaID) async throws -> Track {
                throw ProviderError.notFound
            }
            func search(_ query: String, limit: Int, offset: Int) async throws -> SearchResults { SearchResults() }
            func playlists() async throws -> [Playlist] { [] }
            func playlist(id: MediaID) async throws -> PlaylistDetail {
                throw ProviderError.notFound
            }
            func createPlaylist(name: String, trackIDs: [MediaID]) async throws -> Playlist {
                throw ProviderError.unsupportedOperation(needs: .playlists)
            }
            func renamePlaylist(id: MediaID, name: String) async throws {}
            func addToPlaylist(id: MediaID, trackIDs: [MediaID]) async throws {}
            func removeFromPlaylist(id: MediaID, entries: [PlaylistEntryID]) async throws {}
            func setFavorite(_ favorite: Bool, for id: MediaID, kind: MediaKind) async throws {}
            func scrobble(id: MediaID, at date: Date, submission: Bool) async throws {}
            func streamRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
                URLRequest(url: URL(string: "https://example.invalid")!)
            }
            func downloadRequest(for id: MediaID, options: StreamOptions) async throws -> URLRequest {
                URLRequest(url: URL(string: "https://example.invalid")!)
            }
            func artworkRequest(for id: ArtworkID, size: Int?) async throws -> URLRequest {
                URLRequest(url: URL(string: "https://example.invalid")!)
            }
        }

        let provider = MinimalProvider()
        await #expect(throws: ProviderError.unsupportedOperation(needs: .syncedLyrics)) {
            _ = try await provider.lyrics(for: MediaID(server: provider.serverID, rawValue: "x"))
        }
        await #expect(throws: ProviderError.unsupportedOperation(needs: .ratings)) {
            try await provider.setRating(StarRating(stars: 3), for: MediaID(server: provider.serverID, rawValue: "x"))
        }
    }
}
