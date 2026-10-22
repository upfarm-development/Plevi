import Foundation
import Testing
@testable import PleviDomain

@Suite("Library snapshots in flight to the watch (watch-07)")
struct WatchSnapshotLedgerTests {
    private let a = ServerID()
    private let b = ServerID()

    private func transfer(_ file: String, _ storage: ServerID) -> WatchSnapshotLedger.Transfer {
        .init(file: file, storage: storage)
    }

    @Test("Two sends an hour apart leave one transfer wanted and the first cancelled on purpose")
    func secondSendSupersedesTheFirst() {
        var ledger = WatchSnapshotLedger()
        let first = transfer("library-a-1.sqlite", a)
        #expect(ledger.begin(first, outstanding: []).isEmpty)

        let second = transfer("library-a-2.sqlite", a)
        let cancelled = ledger.begin(second, outstanding: [first])

        #expect(cancelled == [first])
        // The first transfer's completion arrives as a cancellation error when
        // the watch returns. It is ours; it is not a failure to show.
        #expect(ledger.finish(file: first.file, failed: true) == .superseded)
        #expect(ledger.finish(file: second.file, failed: false) == .delivered)
    }

    @Test("Another library's transfer is left alone")
    func otherLibraryIsNotCancelled() {
        var ledger = WatchSnapshotLedger()
        let other = transfer("library-b-1.sqlite", b)
        _ = ledger.begin(other, outstanding: [])
        let cancelled = ledger.begin(transfer("library-a-1.sqlite", a), outstanding: [other])
        #expect(cancelled.isEmpty)
    }

    @Test("Transfers queued by an earlier launch are cancelled too")
    func earlierLaunchIsCancelled() {
        var ledger = WatchSnapshotLedger()
        // This launch's ledger knows nothing of the queued file; the session does.
        let leftover = transfer("library-a-old.sqlite", a)
        let cancelled = ledger.begin(transfer("library-a-new.sqlite", a), outstanding: [leftover])
        #expect(cancelled == [leftover])
        #expect(ledger.finish(file: leftover.file, failed: true) == .superseded)
    }

    @Test("A failure of the latest snapshot takes the stamp back; an older failure only reports")
    func failureOfTheLatest() {
        var ledger = WatchSnapshotLedger()
        let only = transfer("library-a-1.sqlite", a)
        _ = ledger.begin(only, outstanding: [])
        #expect(ledger.finish(file: only.file, failed: true) == .latestFailed)

        var other = WatchSnapshotLedger()
        _ = other.begin(transfer("library-a-1.sqlite", a), outstanding: [])
        // A second library's snapshot, unrelated; then the first one fails
        // having been replaced by nothing — still the latest of its library.
        _ = other.begin(transfer("library-b-1.sqlite", b), outstanding: [])
        #expect(other.finish(file: "library-a-1.sqlite", failed: true) == .latestFailed)
        // An unknown file that fails is an older one.
        #expect(other.finish(file: "library-zzz.sqlite", failed: true) == .olderFailed)
    }

    @Test("Each snapshot has a file of its own")
    func namesAreUnique() {
        #expect(WatchSnapshotLedger.fileName(for: a) != WatchSnapshotLedger.fileName(for: a))
        #expect(WatchSnapshotLedger.fileName(for: a).hasPrefix("library-\(a.rawValue.uuidString)-"))
    }

    @Test("Only our own unqueued snapshot files are swept at launch")
    func staleSweep() {
        let queued: Set<String> = ["library-a-queued.sqlite"]
        #expect(!WatchSnapshotLedger.isStale(fileName: "library-a-queued.sqlite", queued: queued))
        #expect(WatchSnapshotLedger.isStale(fileName: "library-a-orphan.sqlite", queued: queued))
        #expect(!WatchSnapshotLedger.isStale(fileName: "something-else.sqlite", queued: queued))
        #expect(!WatchSnapshotLedger.isStale(fileName: "library-a.txt", queued: queued))
    }
}
