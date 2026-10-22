import Foundation
import Testing
@testable import PleviDomain

/// A failed or called-off request is not an answer.
@Suite("Failed fetches are never recorded as empty answers")
struct FetchAnswersTests {
    private static let server = ServerID()
    private static func id(_ raw: String, on server: ServerID = server) -> MediaID {
        MediaID(server: server, rawValue: raw)
    }

    // MARK: Telling the endings apart

    @Test("A timeout is a failure, not a cancellation")
    func timeoutFails() async {
        let outcome = await FetchOutcome<[Int]>.attempt { throw URLError(.timedOut) }
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }

    @Test("All three shapes of a cancelled request read as cancelled")
    func cancellationShapes() async {
        let shapes: [any Error] = [
            CancellationError(),
            URLError(.cancelled),
            ProviderError.network(underlying: URLError(.cancelled)),
        ]
        for error in shapes {
            let outcome = await FetchOutcome<Int>.attempt { throw error }
            guard case .cancelled = outcome else {
                Issue.record("\(error) should be cancelled, got \(outcome)")
                continue
            }
        }
    }

    @Test("A wrapped network error that is not a cancel stays a failure")
    func wrappedTimeout() async {
        let outcome = await FetchOutcome<Int>.attempt {
            throw ProviderError.network(underlying: URLError(.timedOut))
        }
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }

    @Test("A throw inside a cancelled task is a cancel whatever it was thrown as")
    func throwWhileCancelled() async {
        let task = Task { () -> FetchOutcome<Int> in
            while !Task.isCancelled { await Task.yield() }
            return await FetchOutcome<Int>.attempt { throw URLError(.timedOut) }
        }
        task.cancel()
        let outcome = await task.value
        guard case .cancelled = outcome else {
            Issue.record("expected cancelled, got \(outcome)")
            return
        }
    }

    @Test("An empty answer is an answer")
    func emptyAnswers() async {
        let outcome = await FetchOutcome<[Int]>.attempt { [] }
        #expect(outcome.answer == [])
    }

    // MARK: Lists

    @Test("A failed first load is failed, not empty")
    func failedIsNotEmpty() async {
        var list = FetchedList<Int>()
        #expect(list.isLoading)
        list.apply(await FetchOutcome.attempt { throw URLError(.timedOut) })
        #expect(list.isFailed)
        #expect(!list.isEmptyAnswer)
        #expect(list.items == nil)
    }

    @Test("A real empty answer is the only thing that reads as empty")
    func realEmpty() async {
        var list = FetchedList<Int>()
        list.apply(.answered([]))
        #expect(list.isEmptyAnswer)
        #expect(!list.isFailed)
        #expect(!list.isLoading)
    }

    @Test("A good list survives a failed refresh and a cancelled one")
    func goodListSurvives() {
        var list = FetchedList<Int>()
        list.apply(.answered([1, 2, 3]))
        list.apply(.failed(message: "timed out"))
        #expect(list.items == [1, 2, 3])
        #expect(list.isStale)
        list.apply(.cancelled)
        #expect(list.items == [1, 2, 3])
        #expect(list.isStale)
        list.apply(.answered([4]))
        #expect(list.items == [4])
        #expect(!list.isStale)
    }

    @Test("A cancel changes nothing, including the failure already on show")
    func cancelKeepsFailure() {
        var list = FetchedList<Int>()
        list.apply(.failed(message: "offline"))
        list.apply(.cancelled)
        #expect(list.isFailed)
        list.beginRetry()
        #expect(list.isLoading)
    }

    // MARK: Reviews

    @Test("A failed review request leaves no entry, so the album is asked again")
    func failedReviewNotCached() async {
        var ledger = ReviewLedger()
        let album = Self.id("100")
        let step = await ReviewLedger.ask { throw URLError(.timedOut) }
        #expect(step == .failed)
        ledger.record(step, for: album)
        #expect(ledger.review(for: album) == nil)

        let retry = await ReviewLedger.ask { "A fine record." }
        ledger.record(retry, for: album)
        #expect(ledger.review(for: album) == "A fine record.")
    }

    @Test("A cancelled review request leaves no entry")
    func cancelledReviewNotCached() async {
        var ledger = ReviewLedger()
        let album = Self.id("101")
        let step = await ReviewLedger.ask { throw CancellationError() }
        #expect(step == .cancelled)
        ledger.record(step, for: album)
        #expect(ledger.review(for: album) == nil)
    }

    @Test("A server that answers with no notes is remembered as unreviewed")
    func noNotesIsRemembered() async {
        let album = Self.id("102")
        for notes in [nil, "", "  \n "] as [String?] {
            var ledger = ReviewLedger()
            let step = await ReviewLedger.ask { notes }
            #expect(step == .unreviewed)
            ledger.record(step, for: album)
            #expect(ledger.review(for: album) == "")
        }
    }

    @Test("Two servers with the same rating key do not share reviews")
    func serversDoNotCollide() {
        var ledger = ReviewLedger()
        let other = ServerID()
        ledger.record(.review("Mine"), for: Self.id("7"))
        #expect(ledger.review(for: Self.id("7", on: other)) == nil)
        ledger.record(.unreviewed, for: Self.id("7", on: other))
        #expect(ledger.review(for: Self.id("7")) == "Mine")
    }

    @Test("A missing stored column is not a negative answer")
    func storedColumn() {
        var ledger = ReviewLedger()
        ledger.noteStored(nil, for: Self.id("1"))
        ledger.noteStored("   ", for: Self.id("2"))
        ledger.noteStored("Line one\r\n\r\nLine two", for: Self.id("3"))
        #expect(ledger.review(for: Self.id("1")) == nil)
        #expect(ledger.review(for: Self.id("2")) == nil)
        #expect(ledger.review(for: Self.id("3")) == "Line one Line two")
    }

    // MARK: Failure memo

    @Test("A failure is held for its lifetime and then forgotten")
    func memoExpires() {
        var memo = FailureMemo(lifetime: 300)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!memo.isRemembered("a", at: start))
        memo.note("a", at: start)
        #expect(memo.isRemembered("a", at: start.addingTimeInterval(299)))
        #expect(!memo.isRemembered("a", at: start.addingTimeInterval(300)))
        #expect(!memo.isRemembered("b", at: start))
        memo.forget("a")
        #expect(!memo.isRemembered("a", at: start))
    }

    @Test("The memo stays bounded")
    func memoBounded() {
        var memo = FailureMemo(lifetime: 60, capacity: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<100 { memo.note("k\(index)", at: start.addingTimeInterval(Double(index) * 0.001)) }
        #expect(memo.count <= 10)
        #expect(memo.isRemembered("k99", at: start.addingTimeInterval(1)))
    }

    // MARK: Shelf cache pruning

    private typealias Entry = ShelfCachePruning.Entry

    @Test("Switching library keeps the other library's entry")
    func switchKeepsOthers() {
        let entries = [
            Entry(key: "jazz-w10", library: "jazz", period: "10"),
            Entry(key: "pop-w10", library: "pop", period: "10"),
        ]
        let plan = ShelfCachePruning.plan(
            entries: entries, currentLibrary: "pop", currentPeriod: "10", recentLibraries: ["jazz"]
        )
        #expect(plan.remove.isEmpty)
        #expect(plan.recentLibraries == ["pop", "jazz"])
    }

    @Test("A new period drops the same library's earlier period only")
    func newPeriod() {
        let entries = [
            Entry(key: "jazz-w10", library: "jazz", period: "10"),
            Entry(key: "pop-w10", library: "pop", period: "10"),
            Entry(key: "pop-w11", library: "pop", period: "11"),
        ]
        let plan = ShelfCachePruning.plan(
            entries: entries, currentLibrary: "pop", currentPeriod: "11", recentLibraries: ["jazz"]
        )
        #expect(plan.remove == ["pop-w10"])
    }

    @Test("Libraries beyond the cap are dropped, least recent first")
    func cappedLibraries() {
        let names = (0..<5).map { "lib\($0)" }
        let entries = names.map { Entry(key: "k-\($0)", library: $0, period: "1") }
        let plan = ShelfCachePruning.plan(
            entries: entries, currentLibrary: "lib4", currentPeriod: "1",
            recentLibraries: ["lib3", "lib2", "lib1", "lib0"], maximumLibraries: 3
        )
        #expect(plan.recentLibraries == ["lib4", "lib3", "lib2"])
        #expect(Set(plan.remove) == ["k-lib1", "k-lib0"])
    }

    @Test("An entry for a library that is not remembered is dropped even in its period")
    func unknownLibraryDropped() {
        let entries = [Entry(key: "stray", library: "gone", period: "1")]
        let plan = ShelfCachePruning.plan(
            entries: entries, currentLibrary: "here", currentPeriod: "1", recentLibraries: [], maximumLibraries: 2
        )
        #expect(plan.remove == ["stray"])
    }

    @Test("Pruning preferences keeps a switched-away library's shelf and drops old periods")
    func pruneDefaults() throws {
        let name = "FetchAnswersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefix = "home.test."
        for key in ["10|jazz", "10|pop", "9|pop", "garbage"] {
            defaults.set(Data([1]), forKey: prefix + key)
        }
        defaults.set(Data([1]), forKey: "home.other.10|pop")
        defaults.set(["jazz"], forKey: "home.recent")

        ShelfCachePruning.prune(
            defaults, prefix: prefix, recentKey: "home.recent",
            currentLibrary: "pop", currentPeriod: "10"
        ) { suffix in
            let parts = suffix.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (library: parts[1], period: parts[0]) : nil
        }

        #expect(defaults.data(forKey: prefix + "10|jazz") != nil)
        #expect(defaults.data(forKey: prefix + "10|pop") != nil)
        #expect(defaults.data(forKey: prefix + "9|pop") == nil)
        #expect(defaults.data(forKey: prefix + "garbage") == nil)
        #expect(defaults.data(forKey: "home.other.10|pop") != nil)
        #expect(defaults.stringArray(forKey: "home.recent") == ["pop", "jazz"])
    }
}
