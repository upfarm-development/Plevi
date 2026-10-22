import Foundation
import Testing
import PleviDomain
import PleviMockProvider
import PleviProviderContract

/// The contract suite validated against its reference implementation.
/// Every future provider (Subsonic in M1, Plex later) gets a test exactly
/// like this one, pointed at recorded fixtures.
@Suite struct MockProviderContractTests {
    @Test func mockProviderPassesEveryContractCheck() async {
        let results = await ProviderContract.run(against: MockProvider())

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
        // The mock advertises every capability the suite gates on, so nothing
        // may be skipped — a skip here means a check/capability mismatch.
        #expect(skips.isEmpty, "unexpected skips: \(skips.map(\.name).joined(separator: "; "))")
        #expect(results.count == ProviderContract.checks.count)
    }
}

@Suite struct MockProviderConflictTests {
    @Test func reorderWithStaleEntriesConflicts() async throws {
        let provider = MockProvider()
        let albums = try await provider.albums(filter: .alphabeticalByName, offset: 0, limit: 10)
        let album = try await provider.album(id: albums[0].id)
        let created = try await provider.createPlaylist(
            name: "stale-reorder",
            trackIDs: album.tracks.prefix(2).map(\.id)
        )
        let bogus = PlaylistEntryID(server: provider.serverID, rawValue: "e999999")
        await #expect(throws: ProviderError.self) {
            try await provider.reorderPlaylist(id: created.id, orderedEntries: [bogus])
        }
    }

    @Test func removingUnknownEntryConflicts() async throws {
        let provider = MockProvider()
        let albums = try await provider.albums(filter: .alphabeticalByName, offset: 0, limit: 10)
        let album = try await provider.album(id: albums[0].id)
        let created = try await provider.createPlaylist(
            name: "stale-remove",
            trackIDs: album.tracks.prefix(2).map(\.id)
        )
        let bogus = PlaylistEntryID(server: provider.serverID, rawValue: "e999999")
        await #expect(throws: ProviderError.conflict(details: "playlist entry no longer exists")) {
            try await provider.removeFromPlaylist(id: created.id, entries: [bogus])
        }
    }
}
