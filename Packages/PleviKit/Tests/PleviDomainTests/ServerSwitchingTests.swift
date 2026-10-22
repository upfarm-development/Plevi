import Foundation
import Testing
@testable import PleviDomain

@Suite("Rebuilding the stack on a server or library switch")
struct ServerSwitchingTests {
    private let a = ServerID()
    private let b = ServerID()

    // MARK: Overlapping runs (server-switching-01)

    @Test("Only the newest run is current")
    func newestRunIsCurrent() {
        var runs = ConnectionRuns()
        let first = runs.begin()
        #expect(runs.isCurrent(first))
        let second = runs.begin()
        #expect(!runs.isCurrent(first))
        #expect(runs.isCurrent(second))
    }

    @Test("An overtaken run cannot publish, whatever order the runs finish in")
    func overtakenRunDoesNotPublish() {
        var runs = ConnectionRuns()
        let slowA = runs.begin()      // tap server A: probe takes 16 s
        let fastB = runs.begin()      // tap server B: finishes first
        let fastPublished = runs.publish(b, run: fastB)
        let slowPublished = runs.publish(a, run: slowA)
        #expect(fastPublished)
        #expect(!slowPublished, "the late run 1 must not overwrite run 2's stack")
        #expect(runs.published == b)
    }

    @Test("A run that was overtaken before finishing cannot claim the stack")
    func overtakenBeforeFinishing() {
        var runs = ConnectionRuns()
        let first = runs.begin()
        _ = runs.begin()
        let published = runs.publish(a, run: first)
        #expect(!published)
        #expect(runs.published == nil)
    }

    // MARK: Storage identity (server-switching-03, 09, 15)

    @Test("A reconnect to the published identity is not a change")
    func sameIdentityIsNotAChange() {
        var runs = ConnectionRuns()
        let run = runs.begin()
        runs.publish(a, run: run)
        // Retry, scene resume, a proxy sign-in, an address repair.
        #expect(!runs.storageChanged(incoming: a))
        #expect(runs.storageChanged(incoming: b))
    }

    @Test("Changed is measured against the published stack, not against a run that never published")
    func changeIgnoresOvertakenRuns() {
        var runs = ConnectionRuns()
        let first = runs.begin()
        runs.publish(a, run: first)
        _ = runs.begin()               // a run for B starts and is overtaken...
        _ = runs.begin()               // ...by another run for B
        // The stack is still A's, so B is still a change: the sync, the DJ
        // and the queue of A must not survive it.
        #expect(runs.storageChanged(incoming: b))
    }

    @Test("Launch and no-server both count against a published stack")
    func firstRunAndNoServer() {
        var runs = ConnectionRuns()
        #expect(runs.storageChanged(incoming: a), "nothing published yet")
        #expect(!runs.storageChanged(incoming: nil), "no server and no stack is not a change")
        let run = runs.begin()
        runs.publish(a, run: run)
        #expect(runs.storageChanged(incoming: nil), "the last server was removed")
        runs.tearDown()
        #expect(!runs.storageChanged(incoming: nil))
    }

    // MARK: Playback (P-07)

    @Test("A queue of another library must stop; the same library must not")
    func playbackFollowsTheQueue() {
        #expect(ServerSwitching.playbackMustStop(queueServer: a, incoming: b))
        #expect(!ServerSwitching.playbackMustStop(queueServer: a, incoming: a))
    }

    @Test("Nothing queued never stops anything")
    func emptyQueueDoesNotStop() {
        #expect(!ServerSwitching.playbackMustStop(queueServer: nil, incoming: a))
        #expect(!ServerSwitching.playbackMustStop(queueServer: nil, incoming: nil))
    }

    @Test("Removing the last server stops a queue that is playing")
    func noServerStopsQueue() {
        #expect(ServerSwitching.playbackMustStop(queueServer: a, incoming: nil))
    }

    // MARK: Editing does not switch (server-switching-14)

    @Test("A new server becomes active")
    func newServerBecomesActive() {
        #expect(ServerSwitching.activeServerAfterStoring(b, wasAlreadyListed: false, currentlyActive: a) == b)
        #expect(ServerSwitching.activeServerAfterStoring(a, wasAlreadyListed: false, currentlyActive: nil) == a)
    }

    @Test("Re-saving an existing server leaves the active one alone")
    func editKeepsActive() {
        // Add A, add B (active B), edit A and press Test & Save: still B.
        #expect(ServerSwitching.activeServerAfterStoring(a, wasAlreadyListed: true, currentlyActive: b) == b)
        // Editing the active one keeps it.
        #expect(ServerSwitching.activeServerAfterStoring(b, wasAlreadyListed: true, currentlyActive: b) == b)
    }

    @Test("An edit with no active server activates it")
    func editWithNothingActive() {
        #expect(ServerSwitching.activeServerAfterStoring(a, wasAlreadyListed: true, currentlyActive: nil) == a)
    }

    // MARK: Download sweep backstop

    @Test("A manager may only sweep an index that is its own")
    func sweepNeedsMatchingIndex() {
        #expect(ServerSwitching.mayRemoveUnaccountedFiles(managerServer: a, indexServer: a))
        #expect(!ServerSwitching.mayRemoveUnaccountedFiles(managerServer: a, indexServer: b))
    }
}

@Suite("Registry of storage identities")
struct StorageRegistryTests {
    private let plex = ServerID()
    private let navidrome = ServerID()
    private let main = ServerID()
    private let christmas = ServerID()

    @Test("Records every library a server used and reports news once")
    func recordsLibraries() {
        var registry = StorageRegistry()
        let first = registry.record(storage: main, forServer: plex)
        let second = registry.record(storage: christmas, forServer: plex)
        let again = registry.record(storage: main, forServer: plex)
        #expect(first && second)
        #expect(!again)
        #expect(registry.storageIDs(ofServer: plex) == [main, christmas])
        #expect(registry.storageIDs(ofServer: navidrome).isEmpty)
    }

    @Test("A storage identity finds its server, including a switched-away library")
    func findsOwner() {
        var registry = StorageRegistry()
        registry.record(storage: main, forServer: plex)
        registry.record(storage: christmas, forServer: plex)
        registry.record(storage: navidrome, forServer: navidrome)
        #expect(registry.server(owningStorage: christmas) == plex)
        #expect(registry.server(owningStorage: navidrome) == navidrome)
        #expect(registry.server(owningStorage: ServerID()) == nil)
    }

    @Test("Forgetting a server returns its libraries and leaves the others alone")
    func forgetIsScoped() {
        var registry = StorageRegistry()
        registry.record(storage: main, forServer: plex)
        registry.record(storage: christmas, forServer: plex)
        registry.record(storage: navidrome, forServer: navidrome)
        let forgotten = registry.forget(server: plex)
        #expect(forgotten == [main, christmas])
        #expect(registry.storageIDs(ofServer: plex).isEmpty)
        #expect(registry.storageIDs(ofServer: navidrome) == [navidrome])
        let again = registry.forget(server: plex)
        #expect(again.isEmpty)
    }

    @Test("Survives a round trip through the file")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var registry = StorageRegistry()
        registry.record(storage: main, forServer: plex)
        registry.record(storage: christmas, forServer: plex)
        try registry.save(to: url)
        #expect(try StorageRegistry.load(from: url) == registry)
    }

    @Test("No file is an empty registry; a damaged file is an error, not an empty registry")
    func missingAndDamagedFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try StorageRegistry.load(from: url) == StorageRegistry())
        try Data("not json".utf8).write(to: url)
        #expect(throws: StorageRegistry.Unreadable.self) {
            try StorageRegistry.load(from: url)
        }
    }
}
