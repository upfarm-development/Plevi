import Foundation
import PleviDomain

/// One behavioural requirement every `MusicServerProvider` must satisfy.
public struct ContractCheck: Sendable {
    public let name: String
    public let requires: ServerCapabilities
    public let run: @Sendable (any MusicServerProvider) async throws -> Void

    public init(
        _ name: String,
        requires: ServerCapabilities = [],
        run: @escaping @Sendable (any MusicServerProvider) async throws -> Void
    ) {
        self.name = name
        self.requires = requires
        self.run = run
    }
}

public enum ContractOutcome: Sendable, Equatable {
    case passed
    case skipped(missing: ServerCapabilities)
    case failed(message: String)
}

public struct ContractResult: Sendable {
    public let name: String
    public let outcome: ContractOutcome
}

/// Thrown by checks when an expectation is not met.
public struct ContractExpectationFailure: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String
) throws {
    if !condition() {
        throw ContractExpectationFailure(message())
    }
}

/// The provider contract test suite.
public enum ProviderContract {
    public static func run(against provider: any MusicServerProvider) async -> [ContractResult] {
        var results = [ContractResult]()
        for check in checks {
            if !provider.capabilities.isSuperset(of: check.requires) {
                let missing = check.requires.subtracting(provider.capabilities)
                results.append(ContractResult(name: check.name, outcome: .skipped(missing: missing)))
                continue
            }
            do {
                try await check.run(provider)
                results.append(ContractResult(name: check.name, outcome: .passed))
            } catch {
                results.append(ContractResult(
                    name: check.name,
                    outcome: .failed(message: String(describing: error))
                ))
            }
        }
        return results
    }

    /// First artist (alphabetically) that has at least one album.
    private static func referenceArtist(_ provider: any MusicServerProvider) async throws -> ArtistDetail {
        let artists = try await provider.artists()
        try expect(!artists.isEmpty, "artists() returned an empty library")
        for artist in artists {
            let detail = try await provider.artist(id: artist.id)
            if !detail.albums.isEmpty { return detail }
        }
        throw ContractExpectationFailure("no artist has any albums")
    }

    /// First album found holding three or more tracks.
    private static func referenceAlbum(_ provider: any MusicServerProvider) async throws -> AlbumDetail {
        let albums = try await provider.albums(filter: .alphabeticalByName, offset: 0, limit: 50)
        for album in albums {
            let detail = try await provider.album(id: album.id)
            if detail.tracks.count >= 3 { return detail }
        }
        throw ContractExpectationFailure("no album with >= 3 tracks in the first 50")
    }

    public static let checks: [ContractCheck] = [
        ContractCheck("testConnection returns server info") { provider in
            _ = try await provider.testConnection()
        },

        ContractCheck("artists are unique and named") { provider in
            let artists = try await provider.artists()
            try expect(!artists.isEmpty, "artists() returned an empty library")
            try expect(
                Set(artists.map(\.id)).count == artists.count,
                "artists() returned duplicate IDs"
            )
            try expect(
                artists.allSatisfy { !$0.name.isEmpty },
                "artists() returned an unnamed artist"
            )
        },

        ContractCheck("artist detail albums belong to the artist") { provider in
            let detail = try await referenceArtist(provider)
            try expect(
                detail.albums.allSatisfy { $0.artistID == nil || $0.artistID == detail.artist.id },
                "artist(id:) returned an album owned by a different artist"
            )
        },

        ContractCheck("album detail tracks are ordered and belong to the album") { provider in
            let detail = try await referenceAlbum(provider)
            try expect(
                detail.tracks.allSatisfy { $0.albumID == nil || $0.albumID == detail.album.id },
                "album(id:) returned a track from a different album"
            )
            let positions = detail.tracks.map { ($0.discNumber ?? 1, $0.trackNumber ?? 0) }
            let sorted = positions.sorted { $0 < $1 }
            try expect(
                positions.elementsEqual(sorted, by: ==),
                "album(id:) tracks are not in disc/track order"
            )
        },

        ContractCheck("album pagination pages do not overlap") { provider in
            let first = try await provider.albums(filter: .alphabeticalByName, offset: 0, limit: 1)
            let second = try await provider.albums(filter: .alphabeticalByName, offset: 1, limit: 1)
            try expect(first.count <= 1 && second.count <= 1, "limit was not respected")
            if let a = first.first, let b = second.first {
                try expect(a.id != b.id, "offset was ignored: both pages returned the same album")
            }
        },

        ContractCheck("search finds a known track by its title") { provider in
            let album = try await referenceAlbum(provider)
            let target = album.tracks[0]
            let results = try await provider.search(target.title, limit: 10)
            try expect(
                results.tracks.contains { $0.id == target.id },
                "search(\"\(target.title)\") did not return the track"
            )
        },

        ContractCheck("empty search pages the whole library for sync") { provider in
            let first = try await provider.search("", limit: 2, offset: 0)
            try expect(
                !first.tracks.isEmpty,
                "an empty query must return library content — clients rely on it for sync"
            )
            try expect(first.tracks.count <= 2, "limit was not respected for empty query")
            let second = try await provider.search("", limit: 2, offset: 2)
            if !second.tracks.isEmpty {
                let firstIDs = Set(first.tracks.map(\.id))
                try expect(
                    second.tracks.allSatisfy { !firstIDs.contains($0.id) },
                    "offset returned overlapping pages"
                )
            }
        },

        ContractCheck("track fetch round-trips an album entry") { provider in
            let album = try await referenceAlbum(provider)
            let expected = album.tracks[0]
            let fetched = try await provider.track(id: expected.id)
            try expect(fetched.id == expected.id, "track(id:) returned a different track")
            try expect(fetched.title == expected.title, "track(id:) title mismatch")
        },

        ContractCheck("random tracks respect the limit", requires: .randomBrowse) { provider in
            let tracks = try await provider.randomTracks(limit: 3)
            try expect(tracks.count <= 3, "randomTracks(limit: 3) returned \(tracks.count)")
        },

        ContractCheck("genres are listed", requires: .genreBrowsing) { provider in
            let genres = try await provider.genres()
            try expect(!genres.isEmpty, "genres() returned nothing for a seeded library")
            try expect(genres.allSatisfy { !$0.name.isEmpty }, "genres() returned an unnamed genre")
        },

        ContractCheck("similar tracks exclude the seed track", requires: .similarItems) { provider in
            let album = try await referenceAlbum(provider)
            let seed = album.tracks[0]
            let similar = try await provider.similarTracks(to: seed.id, limit: 5)
            try expect(
                !similar.contains { $0.id == seed.id },
                "similarTracks returned the seed track itself"
            )
        },

        ContractCheck("top tracks belong to the artist", requires: .topTracks) { provider in
            let artist = try await referenceArtist(provider)
            let top = try await provider.topTracks(forArtist: artist.artist.id, limit: 5)
            try expect(
                top.allSatisfy { $0.artistID == nil || $0.artistID == artist.artist.id },
                "topTracks returned a track by a different artist"
            )
        },

        ContractCheck("artist info is available", requires: .artistInfo) { provider in
            let artist = try await referenceArtist(provider)
            _ = try await provider.artistInfo(id: artist.artist.id)
        },

        ContractCheck("album info is available", requires: .albumInfo) { provider in
            let album = try await referenceAlbum(provider)
            _ = try await provider.albumInfo(id: album.album.id)
        },

        ContractCheck("release types are normalised") { provider in
            let albums = try await provider.albums(filter: .alphabeticalByName, offset: 0, limit: 20)
            try expect(!albums.isEmpty, "no albums to inspect")
            // Every album must resolve to a category, even when the server
            // reports nothing — the artist page files them by this.
            for album in albums {
                try expect(
                    ReleaseType.allCases.contains(album.primaryReleaseType),
                    "album \"\(album.name)\" has no usable release type"
                )
            }
        },

        ContractCheck("playlist lifecycle: create, read, rename, add, remove", requires: .playlists) { provider in
            let album = try await referenceAlbum(provider)
            let trackIDs = album.tracks.prefix(2).map(\.id)
            let created = try await provider.createPlaylist(
                name: "contract-lifecycle",
                trackIDs: Array(trackIDs)
            )
            do {
                var detail = try await provider.playlist(id: created.id)
                try expect(
                    detail.entries.map(\.track.id) == Array(trackIDs),
                    "created playlist does not contain the requested tracks in order"
                )

                try await provider.renamePlaylist(id: created.id, name: "contract-renamed")
                detail = try await provider.playlist(id: created.id)
                try expect(detail.playlist.name == "contract-renamed", "rename was not applied")

                try await provider.addToPlaylist(id: created.id, trackIDs: [album.tracks[2].id])
                detail = try await provider.playlist(id: created.id)
                try expect(detail.entries.count == 3, "add did not extend the playlist")

                let middle = detail.entries[1]
                try await provider.removeFromPlaylist(id: created.id, entries: [middle.entryID])
                detail = try await provider.playlist(id: created.id)
                try expect(detail.entries.count == 2, "remove did not shrink the playlist")
                try expect(
                    !detail.entries.contains { $0.entryID == middle.entryID },
                    "removed entry is still present"
                )
            } catch {
                throw error
            }

            // The playlist it made is left behind on purpose.
            let remaining = try await provider.playlists()
            try expect(
                remaining.contains { $0.id == created.id },
                "playlist created by the contract is not listed"
            )
        },

        ContractCheck("playlist reorder applies a full permutation", requires: [.playlists, .playlistReorder]) { provider in
            let album = try await referenceAlbum(provider)
            let trackIDs = album.tracks.prefix(3).map(\.id)
            let created = try await provider.createPlaylist(
                name: "contract-reorder",
                trackIDs: Array(trackIDs)
            )
            do {
                let detail = try await provider.playlist(id: created.id)
                let reversed = detail.entries.map(\.entryID).reversed()
                try await provider.reorderPlaylist(id: created.id, orderedEntries: Array(reversed))
                let after = try await provider.playlist(id: created.id)
                try expect(
                    after.entries.map(\.track.id) == trackIDs.reversed(),
                    "reorder did not produce the requested order"
                )
            } catch {
                throw error
            }
        },

        ContractCheck("favorite toggle round-trips", requires: .favorites) { provider in
            let album = try await referenceAlbum(provider)
            let track = album.tracks[0]
            try await provider.setFavorite(true, for: track.id, kind: .track)
            let afterSet = try await provider.track(id: track.id)
            try expect(afterSet.isFavorite, "setFavorite(true) not reflected")
            try await provider.setFavorite(false, for: track.id, kind: .track)
            let afterClear = try await provider.track(id: track.id)
            try expect(!afterClear.isFavorite, "setFavorite(false) not reflected")
        },

        ContractCheck("rating set and clear round-trips", requires: .ratings) { provider in
            let album = try await referenceAlbum(provider)
            let track = album.tracks[0]
            try await provider.setRating(StarRating(stars: 4), for: track.id)
            let afterSet = try await provider.track(id: track.id)
            try expect(afterSet.rating == StarRating(stars: 4), "setRating(4) not reflected")
            try await provider.setRating(nil, for: track.id)
            let afterClear = try await provider.track(id: track.id)
            try expect(afterClear.rating == nil, "setRating(nil) did not clear the rating")
        },

        ContractCheck("scrobble accepts now-playing and submission", requires: .scrobbling) { provider in
            let album = try await referenceAlbum(provider)
            let track = album.tracks[0]
            try await provider.scrobble(id: track.id, at: Date(), submission: false)
            try await provider.scrobble(id: track.id, at: Date(), submission: true)
        },

        ContractCheck("media requests are well-formed") { provider in
            let album = try await referenceAlbum(provider)
            let track = album.tracks[0]

            let stream = try await provider.streamRequest(for: track.id, options: .original)
            try expect(stream.url != nil, "streamRequest has no URL")
            try expect(
                stream.url?.scheme == "https" || stream.url?.scheme == "http",
                "streamRequest URL is not HTTP(S)"
            )

            let download = try await provider.downloadRequest(for: track.id, options: .original)
            try expect(download.url != nil, "downloadRequest has no URL")

            if let artwork = track.artwork {
                let art = try await provider.artworkRequest(for: artwork, size: 300)
                try expect(art.url != nil, "artworkRequest has no URL")
            }
        },

        ContractCheck("synced lyrics are monotonically timed", requires: .syncedLyrics) { provider in
            let album = try await referenceAlbum(provider)
            for track in album.tracks {
                guard let lyrics = try await provider.lyrics(for: track.id) else { continue }
                if lyrics.synced {
                    let starts = lyrics.lines.compactMap(\.start)
                    try expect(
                        starts == starts.sorted(),
                        "synced lyric line times are not non-decreasing"
                    )
                }
            }
        },
    ]
}
