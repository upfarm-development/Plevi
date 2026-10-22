import Foundation
import Testing
import PleviDomain
import GRDB
@testable import PleviLibraryIndex

/// The launch reconciliation of downloads against the disk (D-04, D-15,
/// downloads-16 / persistence-15 / persistence-21).
@Suite("Stress: launch reconciliation of downloads")
struct StressDownloadsReconcileTests {
    private let server = ServerID()

    private func record(
        _ id: String, _ state: DownloadRecord.State, file: String? = nil,
        previous: String? = nil, failure: String? = nil
    ) -> DownloadRecord {
        DownloadRecord(
            trackId: id, state: state, fileName: file, variant: "orig",
            failure: failure, previousFileName: previous, previousVariant: previous == nil ? nil : "opus-128"
        )
    }

    private func plan(_ records: [DownloadRecord], disk: [String: Int64]) -> DownloadReconciler.Plan {
        DownloadReconciler.plan(records: records, fileSize: { disk[$0] })
    }

    private func action(_ plan: DownloadReconciler.Plan, _ id: String) -> DownloadReconciler.Action? {
        plan.entries.first { $0.record.trackId == id }?.action
    }

    // MARK: D-15

    @Test("D-15: a name is kept for every row that is not a failure, whether or not its file has landed yet")
    func keepsNamesOfRowsWhoseFileIsStillArriving() {
        let plan = plan([
            record("here", .done, file: "here.flac"),
            record("coming", .running, file: "coming.flac"),
            record("waiting", .queued, file: "waiting.flac"),
            record("gone", .done, file: "gone.flac"),
        ], disk: ["here.flac": 10])
        // Nothing in this list may be swept: a transfer that finishes between
        // the loop and the sweep must not be deleted for having been late.
        #expect(plan.keep == ["here.flac", "coming.flac", "waiting.flac", "gone.flac"])
        #expect(action(plan, "here") == .present)
        #expect(action(plan, "coming") == .redownload)
        #expect(action(plan, "gone") == .redownload, "done with the file missing needs downloading again")
    }

    @Test("D-15: the leftovers of a failed row are swept, unless the file is really there")
    func failedLeftoversAreSwept() {
        let plan = plan([
            record("bad", .failed, file: "bad.flac", failure: "HTTP 404"),
            record("odd", .failed, file: "odd.flac", failure: "HTTP 500"),
        ], disk: ["odd.flac": 50])
        #expect(!plan.keep.contains("bad.flac"))
        #expect(plan.keep.contains("odd.flac"), "a complete file is never deleted because a row disagrees")
        #expect(action(plan, "bad") == .failed("HTTP 404"))
    }

    // MARK: downloads-16: a poisoned file heals

    @Test("A zero-byte file is not a download: the song is asked for again and the file is not kept")
    func emptyFileIsRedownloaded() {
        let plan = plan([record("empty", .done, file: "empty.flac")], disk: ["empty.flac": 0])
        #expect(action(plan, "empty") == .redownload)
        #expect(!plan.keep.contains("empty.flac"))
    }

    @Test("Rows an older build failed at the preparation stage are owed, not failed")
    func legacyPreparationFailureIsOwed() {
        let plan = plan([
            record("a", .failed, failure: DownloadReconciler.legacyPreparationFailure),
            record("b", .failed, failure: "HTTP 403"),
        ], disk: [:])
        #expect(action(plan, "a") == .redownload)
        #expect(action(plan, "b") == .failed("HTTP 403"))
    }

    // MARK: D-04

    @Test("D-04: the copy being replaced is kept while the replacement has not arrived")
    func previousCopySurvivesTheSweep() {
        let plan = plan([
            record("t", .queued, file: "new-opus.opus", previous: "old-orig.flac"),
        ], disk: ["old-orig.flac": 900])
        #expect(plan.keep == ["new-opus.opus", "old-orig.flac"])
        #expect(action(plan, "t") == .redownload)
    }

    @Test("D-04: once the replacement is there, the old copy is a leftover")
    func previousCopyIsSweptAfterReplacement() {
        let plan = plan([
            record("t", .done, file: "new-opus.opus", previous: "old-orig.flac"),
        ], disk: ["old-orig.flac": 900, "new-opus.opus": 300])
        #expect(plan.keep == ["new-opus.opus"])
        #expect(action(plan, "t") == .present)
    }

    @Test("D-04: a replacement that failed for good puts the earlier copy back")
    func failedReplacementRestoresThePreviousCopy() {
        let plan = plan([
            record("t", .failed, file: "new-opus.opus", previous: "old-orig.flac", failure: "HTTP 500"),
        ], disk: ["old-orig.flac": 900])
        #expect(action(plan, "t") == .restorePrevious)
        #expect(plan.keep == ["old-orig.flac"])
    }

    @Test("D-04: a failed replacement with the old copy gone is just a failure")
    func failedReplacementWithNothingToRestore() {
        let plan = plan([
            record("t", .failed, file: "new-opus.opus", previous: "old-orig.flac", failure: "HTTP 500"),
        ], disk: [:])
        #expect(action(plan, "t") == .failed("HTTP 500"))
        #expect(plan.keep.isEmpty)
    }

    // MARK: Records

    @Test("D-04: the previous copy round-trips through the index")
    func previousFieldsRoundTrip() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.saveDownload(record("t", .queued, file: "new.opus", previous: "old.flac"))
        let read = try #require(try index.download(forTrack: MediaID(server: server, rawValue: "t")))
        #expect(read.previousFileName == "old.flac")
        #expect(read.previousVariant == "opus-128")

        var cleared = read
        cleared.previousFileName = nil
        cleared.previousVariant = nil
        try index.saveDownload(cleared)
        #expect(try index.download(forTrack: MediaID(server: server, rawValue: "t"))?.previousFileName == nil)
    }

    @Test("downloads-16: a row in a state this build does not know does not fail the read of the whole table")
    func unknownStateDoesNotPoisonTheTable() throws {
        let index = try LibraryIndex(inMemoryFor: server)
        try index.saveDownload(record("a", .done, file: "a.flac"))
        try index.saveDownload(record("b", .done, file: "b.flac"))
        try index.database.write { db in
            try db.execute(sql: "UPDATE download SET state = 'paused-by-a-newer-build' WHERE trackId = 'b'")
        }
        let all = try index.downloads()
        #expect(all.count == 2)
        #expect(all.first { $0.trackId == "b" }?.state == .failed)
        #expect(all.first { $0.trackId == "a" }?.state == .done)
    }
}
