import Foundation
import Testing
import PleviDomain
@testable import PleviLibraryIndex

/// The table-side rules behind the watch's reconcile (persistence-15) and its
/// batched writes (perf-scale-14).
@Suite("Watch downloads: table reads and writes")
struct WatchDownloadsTableTests {
    private let server = ServerID()

    private func record(_ id: String, _ state: DownloadRecord.State = .done, file: String? = nil) -> DownloadRecord {
        DownloadRecord(trackId: id, state: state, fileName: file ?? "\(id).mp3", title: "Song \(id)")
    }

    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    // MARK: persistence-15

    @Test("A table that could not be read is never swept")
    func failedReadIsNotEmpty() {
        #expect(!DownloadSweepPolicy.maySweep(readSucceeded: false, skipOnce: false))
        #expect(DownloadSweepPolicy.maySweep(readSucceeded: true, skipOnce: false))
    }

    @Test("A snapshot install that lost the rows holds the next sweep off")
    func installThatLostRowsSkipsOnce() {
        #expect(!DownloadSweepPolicy.maySweep(readSucceeded: true, skipOnce: true))
    }

    @Test("A row marked done whose file is gone is owed again, and its name is not swept")
    func doneWithoutFileIsRedownloaded() {
        let plan = DownloadReconciler.plan(
            records: [record("a"), record("b")],
            fileSize: { $0 == "a.mp3" ? 100 : nil }
        )
        let actions = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.record.trackId, $0.action) })
        #expect(actions["a"] == .present)
        #expect(actions["b"] == .redownload)
        #expect(plan.keep.contains("b.mp3"), "a transfer landing in the window is the song, not a leftover")
    }

    // MARK: perf-scale-14

    @Test("Several rows are read in one call, in any number")
    func bulkRead() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        let many = (0..<1_000).map { record("s\($0)") }
        try index.saveDownloads(many)

        let ids = (0..<1_000).map { id("s\($0)") } + [id("missing")]
        let found = try index.downloads(forTracks: ids)

        #expect(found.count == 1_000)
        #expect(Set(found.map(\.trackId)).count == 1_000)
        #expect(try index.downloads(forTracks: []).isEmpty)
    }

    @Test("Saving and deleting several rows does what one at a time did")
    func bulkWriteAndDelete() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.saveDownloads([record("a"), record("b"), record("c")])
        #expect(try index.downloads().count == 3)

        try index.deleteDownloads(forTracks: [id("a"), id("c")])

        #expect(try index.downloads().map(\.trackId) == ["b"])
    }
}
