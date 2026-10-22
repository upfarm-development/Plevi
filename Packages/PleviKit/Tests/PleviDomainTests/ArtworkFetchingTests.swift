import Foundation
import Testing
@testable import PleviDomain

/// Artwork requests: what a failure means, and that scrolling away stops the
/// request instead of leaving it queued.
@Suite("Artwork request hygiene")
struct ArtworkFetchingTests {
    // MARK: Classification

    @Test("A decoded 200 is delivered, an undecodable one is rejected")
    func okStatus() {
        #expect(ArtworkAnswer.classify(statusCode: 200, bodyDecodes: true) == .delivered)
        #expect(ArtworkAnswer.classify(statusCode: 200, bodyDecodes: false) == .rejected)
    }

    @Test("A 4xx is rejected and allows the original")
    func clientErrors() {
        for status in [400, 401, 403, 404, 415] {
            let answer = ArtworkAnswer.classify(statusCode: status, bodyDecodes: false)
            #expect(answer == .rejected)
            #expect(answer.allowsOriginalFallback)
        }
    }

    @Test("Gateway and rate-limit answers are about the route, not the picture")
    func gatewayErrors() {
        for status in [408, 429, 502, 503, 504] {
            let answer = ArtworkAnswer.classify(statusCode: status, bodyDecodes: false)
            #expect(answer == .unreachable)
            #expect(!answer.allowsOriginalFallback)
        }
    }

    @Test("A 500 is a server fault: original may be tried, never stored as rejected")
    func plainFiveHundred() {
        let answer = ArtworkAnswer.classify(statusCode: 500, bodyDecodes: false)
        #expect(answer == .serverFault)
        #expect(answer != .rejected)
        #expect(answer.allowsOriginalFallback)
    }

    @Test("Timeouts and cancels never lead to the full-size original")
    func noFallbackAfterTransport() {
        #expect(!ArtworkAnswer.unreachable.allowsOriginalFallback)
        #expect(!ArtworkAnswer.cancelled.allowsOriginalFallback)
        #expect(!ArtworkAnswer.delivered.allowsOriginalFallback)
    }

    @Test("Only real failures are worth a negative entry")
    func rememberedEndings() {
        #expect(ArtworkAnswer.unreachable.isWorthRemembering)
        #expect(ArtworkAnswer.rejected.isWorthRemembering)
        #expect(ArtworkAnswer.serverFault.isWorthRemembering)
        #expect(!ArtworkAnswer.cancelled.isWorthRemembering)
        #expect(!ArtworkAnswer.delivered.isWorthRemembering)
    }

    // MARK: Coalescing and cancellation

    private actor Counter {
        private(set) var started = 0
        private(set) var cancelled = 0
        private(set) var finished = 0
        func start() { started += 1 }
        func cancel() { cancelled += 1 }
        func finish() { finished += 1 }
    }

    /// Work that never answers, but notices being cancelled.
    private static func neverAnswers(_ counter: Counter) -> @Sendable () async -> Int? {
        {
            await counter.start()
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await counter.cancel()
            return nil
        }
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test("Three callers for one key make one request")
    func sharesWork() async {
        let coalescer = RequestCoalescer<Int>()
        let counter = Counter()
        let work: @Sendable () async -> Int? = {
            await counter.start()
            try? await Task.sleep(for: .milliseconds(50))
            return 7
        }
        async let a = coalescer.value(for: "k", work: work)
        async let b = coalescer.value(for: "k", work: work)
        async let c = coalescer.value(for: "k", work: work)
        let results = await [a, b, c]
        #expect(results == [7, 7, 7])
        #expect(await counter.started == 1)
        #expect(await coalescer.inFlightCount == 0)
    }

    @Test("The request is cancelled when the last waiter stops waiting")
    func cancelsWhenLastWaiterLeaves() async {
        let coalescer = RequestCoalescer<Int>()
        let counter = Counter()
        let work = Self.neverAnswers(counter)
        let first = Task { await coalescer.value(for: "k", work: work) }
        let second = Task { await coalescer.value(for: "k", work: work) }
        #expect(await Self.waitUntil { await counter.started == 1 })

        first.cancel()
        _ = await first.value
        // One waiter is still there, so the request carries on.
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await counter.cancelled == 0)

        second.cancel()
        _ = await second.value
        #expect(await Self.waitUntil { await counter.cancelled == 1 })
        #expect(await Self.waitUntil { await coalescer.inFlightCount == 0 })
        #expect(await counter.started == 1)
    }

    @Test("Three hundred cancelled asks leave no request behind")
    func fling() async {
        let coalescer = RequestCoalescer<Int>()
        let counter = Counter()
        let work = Self.neverAnswers(counter)
        let tasks = (0..<300).map { index in
            Task { await coalescer.value(for: "cell\(index)", work: work) }
        }
        #expect(await Self.waitUntil { await counter.started == 300 })
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        #expect(await Self.waitUntil { await counter.cancelled == 300 })
        #expect(await Self.waitUntil { await coalescer.inFlightCount == 0 })
    }

    @Test("A new ask after a cancel starts fresh work")
    func restartAfterCancel() async {
        let coalescer = RequestCoalescer<Int>()
        let counter = Counter()
        let stuck = Task { await coalescer.value(for: "k", work: Self.neverAnswers(counter)) }
        #expect(await Self.waitUntil { await counter.started == 1 })
        stuck.cancel()
        _ = await stuck.value

        let fresh = await coalescer.value(for: "k") { 42 }
        #expect(fresh == 42)
    }

    // MARK: The gate

    @Test("No more than the limit run at once")
    func gateLimit() async {
        let gate = RecencyGate(limit: 3)
        let peak = Counter()
        let current = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = await gate.withPlace {
                        await current.start()
                        let now = await current.started - (await current.finished)
                        if now > 3 { await peak.start() }
                        try? await Task.sleep(for: .milliseconds(5))
                        await current.finish()
                    }
                }
            }
        }
        #expect(await peak.started == 0)
        #expect(await current.finished == 20)
        #expect(await gate.runningCount == 0)
    }

    @Test("The newest waiter is served first")
    func newestFirst() async {
        let gate = RecencyGate(limit: 1)
        let order = OrderLog()
        let release = Latch()

        let holder = Task {
            await gate.withPlace { await release.wait() }
        }
        #expect(await Self.waitUntil { await gate.runningCount == 1 })

        var waiters: [Task<Void, Never>] = []
        for index in 0..<3 {
            waiters.append(Task {
                _ = await gate.withPlace { await order.add(index) }
            })
            let expected = index + 1
            #expect(await Self.waitUntil { await gate.waitingCount == expected })
        }
        await release.open()
        _ = await holder.value
        for waiter in waiters { await waiter.value }
        #expect(await order.items == [2, 1, 0])
    }

    @Test("A cancelled waiter leaves the queue without running")
    func cancelledWaiterSkipped() async {
        let gate = RecencyGate(limit: 1)
        let ran = Counter()
        let release = Latch()
        let holder = Task { await gate.withPlace { await release.wait() } }
        #expect(await Self.waitUntil { await gate.runningCount == 1 })

        let waiter = Task { await gate.withPlace { await ran.start() } }
        #expect(await Self.waitUntil { await gate.waitingCount == 1 })
        waiter.cancel()
        let result = await waiter.value
        #expect(result == nil)
        #expect(await Self.waitUntil { await gate.waitingCount == 0 })

        await release.open()
        _ = await holder.value
        #expect(await ran.started == 0)
        #expect(await gate.runningCount == 0)
    }

    private actor OrderLog {
        private(set) var items: [Int] = []
        func add(_ value: Int) { items.append(value) }
    }

    private actor Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
}
