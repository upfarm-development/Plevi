import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// A calibration point, the album twin of `SongListTests.handlesTheWholeLibrary`:
/// not a performance target, but the line between "reads the album table in
/// one go" and "went quadratic".
@Suite("A whole library's worth of albums")
struct AlbumListScaleTests {
    @Test("Five thousand albums, every column filled in, arrives quickly enough to show")
    func handlesARealLibrary() throws {
        let server = ServerID()
        let index = try LibraryIndex(inMemoryFor: server)
        let names = ["Aurora", "Nightfall", "Daybreak", "Echoes", "Halcyon", "Interlude", "Wayfarer", "Zenith"]
        let albums = (0..<5_000).map { i in
            Album(
                id: MediaID(server: server, rawValue: "al\(i)"),
                name: "\(names[i % names.count]) \(i)",
                artistName: "Artist \(i % 700)",
                artistID: MediaID(server: server, rawValue: "ar\(i % 700)"),
                year: 1960 + (i % 65),
                genre: ["Folk", "Jazz", "Ambient", "Rock", "Pop"][i % 5],
                trackCount: 8 + (i % 10),
                duration: 2_400,
                artwork: ArtworkID(server: server, rawValue: "art\(i)"),
                addedAt: Date(timeIntervalSince1970: Double(1_500_000_000 + i * 3_600)),
                playedAt: i % 3 == 0 ? Date(timeIntervalSince1970: Double(1_600_000_000 + i)) : nil,
                playCount: i % 3 == 0 ? i % 40 : nil,
                isFavorite: i % 11 == 0,
                rating: i % 6 == 0 ? StarRating(4) : nil,
                releaseTypes: [.album],
                recordLabel: "Label \(i % 50)",
                releaseDate: Date(timeIntervalSince1970: Double(1_500_000_000 + i * 3_600)),
                criticRating: i % 9 == 0 ? 8.0 : nil,
                review: i % 9 == 0 ? "A record worth the time it asks for." : nil
            )
        }
        try index.upsertAlbums(albums, generation: 1)
        try index.finishSync(generation: 1)

        let started = Date()
        let rows = try index.albums(filter: .alphabeticalByName, offset: 0, limit: 100_000)
        let elapsed = Date().timeIntervalSince(started)
        #expect(rows.count == 5_000)
        print("ALBUMSCALE 5,000 albums read and sorted in \(String(format: "%.3f", elapsed))s")
        #expect(elapsed < 8.0, "took \(String(format: "%.2f", elapsed))s")
    }
}
