import Foundation
import Testing
@testable import PleviDomain

@Suite("The settings backup, end to end on real defaults")
struct BackupDocumentTests {
    private let keys = BackupDocument.Keys(
        carried: ["app.theme", "search.resultOrder"],
        perLibrary: ["home.sectionOrder", "home.customSections", "home.playLog", "home.playLog.seeded"],
        playLog: "home.playLog"
    )

    private func defaults() -> UserDefaults {
        let name = "backup-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    /// Arranges a library's Home the way the app would have, under its own
    /// scope, with a play log naming `server`.
    private func arrange(
        _ defaults: UserDefaults, scope: String, order: [String], shelves: String, server: ServerID
    ) throws {
        defaults.set(order, forKey: "home.sectionOrder.\(scope)")
        defaults.set(Data(shelves.utf8), forKey: "home.customSections.\(scope)")
        let entry = PlayedEntry(
            source: PlayedSource(kind: .playlist, mediaID: MediaID(server: server, rawValue: "pl1"), title: "Sunday"),
            playedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        defaults.set(try JSONEncoder().encode([entry]), forKey: "home.playLog.\(scope)")
        defaults.set(true, forKey: "home.playLog.seeded.\(scope)")
    }

    private func snapshot(
        _ defaults: UserDefaults, scope: String?, fingerprint: String?, stored: Data? = nil
    ) throws -> Data {
        try #require(BackupDocument.snapshot(
            of: defaults, keys: keys, libraryScope: scope, libraryFingerprint: fingerprint,
            stored: stored, deviceName: "Test phone"
        ))
    }

    private func playLog(_ defaults: UserDefaults, scope: String) throws -> [PlayedEntry] {
        let data = try #require(defaults.data(forKey: "home.playLog.\(scope)"))
        return try JSONDecoder().decode([PlayedEntry].self, from: data)
    }

    // MARK: persistence-03 and server-switching-17

    @Test func switchingLibraryDoesNotDropTheFirstLibrarysShelves() throws {
        let old = defaults()
        old.set("dark", forKey: "app.theme")
        let musicScope = UUID().uuidString, xmasScope = UUID().uuidString
        try arrange(old, scope: musicScope, order: ["a", "b", "c"], shelves: "music-3-shelves", server: ServerID())
        try arrange(old, scope: xmasScope, order: ["x"], shelves: "xmas-1-shelf", server: ServerID())

        // Music is open; its backup goes up. Then Christmas opens and the
        // backup is written again over the stored one.
        let first = try snapshot(old, scope: musicScope, fingerprint: "fp-music")
        let second = try snapshot(old, scope: xmasScope, fingerprint: "fp-xmas", stored: first)

        let libraries = try #require(BackupDocument.storedLibraries(second))
        #expect(Set(libraries.keys) == ["fp-music", "fp-xmas"])
        #expect((libraries["fp-music"]?["home.sectionOrder"] as? [String]) == ["a", "b", "c"])
        #expect((libraries["fp-xmas"]?["home.sectionOrder"] as? [String]) == ["x"])
    }

    @Test func aFreshInstallHoldsEachLibrarysShelvesUntilThatLibraryConnects() throws {
        let old = defaults()
        old.set("dark", forKey: "app.theme")
        let musicScope = UUID().uuidString, xmasScope = UUID().uuidString
        try arrange(old, scope: musicScope, order: ["a", "b", "c"], shelves: "music-3-shelves", server: ServerID())
        try arrange(old, scope: xmasScope, order: ["x"], shelves: "xmas-1-shelf", server: ServerID())
        let first = try snapshot(old, scope: musicScope, fingerprint: "fp-music")
        let document = try snapshot(old, scope: xmasScope, fingerprint: "fp-xmas", stored: first)

        // A new install: nothing of its own, no library connected yet.
        let fresh = defaults()
        let landed = BackupDocument.apply(document, to: fresh, keys: keys)
        #expect(landed >= 1)
        #expect(fresh.string(forKey: "app.theme") == "dark")
        // Nothing unscoped for "the first library to connect" to take.
        #expect(fresh.object(forKey: "home.sectionOrder") == nil)
        #expect(fresh.object(forKey: "home.customSections") == nil)

        // A Navidrome library with neither fingerprint connects first: it
        // gets nothing.
        let stranger = UUID().uuidString
        BackupDocument.adoptPending(into: fresh, keys: keys, scope: stranger, fingerprint: "fp-navidrome")
        #expect(fresh.object(forKey: "home.sectionOrder.\(stranger)") == nil)

        // Christmas connects, then Music, each under a new id of this install.
        let xmasNew = UUID(), musicNew = UUID()
        BackupDocument.adoptPending(into: fresh, keys: keys, scope: xmasNew.uuidString, fingerprint: "fp-xmas")
        BackupDocument.adoptPending(into: fresh, keys: keys, scope: musicNew.uuidString, fingerprint: "fp-music")
        #expect(fresh.array(forKey: "home.sectionOrder.\(xmasNew.uuidString)") as? [String] == ["x"])
        #expect(fresh.array(forKey: "home.sectionOrder.\(musicNew.uuidString)") as? [String] == ["a", "b", "c"])
        #expect(fresh.data(forKey: "home.customSections.\(musicNew.uuidString)") == Data("music-3-shelves".utf8))
        // Adopted once.
        #expect(BackupDocument.pendingLibraries(in: fresh).isEmpty)
    }

    // MARK: persistence-17

    @Test func aRestoredPlayLogNamesThisInstallsLibraryNotTheOldOne() throws {
        let old = defaults()
        old.set("dark", forKey: "app.theme")
        let scope = UUID().uuidString
        let oldServer = ServerID()
        try arrange(old, scope: scope, order: ["a"], shelves: "s", server: oldServer)
        let document = try snapshot(old, scope: scope, fingerprint: "fp")

        let fresh = defaults()
        BackupDocument.apply(document, to: fresh, keys: keys)
        let newLibrary = ServerID()
        BackupDocument.adoptPending(into: fresh, keys: keys, scope: newLibrary.rawValue.uuidString, fingerprint: "fp")

        let entries = try playLog(fresh, scope: newLibrary.rawValue.uuidString)
        #expect(entries.map(\.source.mediaID.server) == [newLibrary])
        #expect(entries.first?.source.mediaID.rawValue == "pl1")
        #expect(fresh.bool(forKey: "home.playLog.seeded.\(newLibrary.rawValue.uuidString)"))
    }

    @Test func rebasingRewritesArtworkToo() {
        let old = ServerID(), new = ServerID()
        let entry = PlayedEntry(
            source: PlayedSource(
                kind: .album, mediaID: MediaID(server: old, rawValue: "al"), title: "T",
                artwork: ArtworkID(server: old, rawValue: "art")
            ),
            playedAt: .now
        )
        let rebased = PlayHistory.rebased([entry], to: new)
        #expect(rebased[0].source.mediaID.server == new)
        #expect(rebased[0].source.artwork?.server == new)
        #expect(rebased[0].source.artwork?.rawValue == "art")
        #expect(PlayHistory.rebased(Data("nope".utf8), to: new) == nil)
    }

    // MARK: persistence-02

    @Test func aRestoreByHandLandsInTheOpenLibrarysKeysAndLeavesNoOrphan() throws {
        let old = defaults()
        old.set("dark", forKey: "app.theme")
        let oldScope = UUID().uuidString
        try arrange(old, scope: oldScope, order: ["from", "backup"], shelves: "backup-shelves", server: ServerID())
        let document = try snapshot(old, scope: oldScope, fingerprint: "fp-music")

        // A used install whose open library already owns its keys, and which
        // has a stale unscoped copy lying around.
        let used = defaults()
        let scope = UUID().uuidString
        try arrange(used, scope: scope, order: ["local"], shelves: "local-shelves", server: ServerID())
        used.set(["stale"], forKey: "home.sectionOrder")

        let landed = BackupDocument.apply(
            document, to: used, keys: keys, libraryScope: scope, libraryFingerprint: "fp-music"
        )
        #expect(used.array(forKey: "home.sectionOrder.\(scope)") as? [String] == ["from", "backup"])
        #expect(used.data(forKey: "home.customSections.\(scope)") == Data("backup-shelves".utf8))
        #expect(used.string(forKey: "app.theme") == "dark")
        // No unscoped copy for the next library to adopt.
        for base in keys.perLibrary { #expect(used.object(forKey: base) == nil) }
        // Counted: theme, plus the four arrangement keys that landed.
        #expect(landed == 1 + 4)
    }

    @Test func aRestoreByHandKeepsOtherLibrariesForWhenTheyConnect() throws {
        let old = defaults()
        old.set("dark", forKey: "app.theme")
        let a = UUID().uuidString, b = UUID().uuidString
        try arrange(old, scope: a, order: ["a"], shelves: "a", server: ServerID())
        try arrange(old, scope: b, order: ["b"], shelves: "b", server: ServerID())
        let first = try snapshot(old, scope: a, fingerprint: "fp-a")
        let document = try snapshot(old, scope: b, fingerprint: "fp-b", stored: first)

        let used = defaults()
        let scope = UUID().uuidString
        BackupDocument.apply(document, to: used, keys: keys, libraryScope: scope, libraryFingerprint: "fp-a")
        #expect(used.array(forKey: "home.sectionOrder.\(scope)") as? [String] == ["a"])
        #expect(Set(BackupDocument.pendingLibraries(in: used).keys) == ["fp-b"])
    }

    // MARK: Older documents

    @Test func aDocumentFromBeforeLibrariesWereToldApartStillRestores() throws {
        // What the previous build wrote: `values` only, the open library's
        // arrangement under its unscoped names.
        let document: [String: Any] = [
            "version": 1, "writtenAt": Date(), "deviceName": "Old",
            "values": ["app.theme": "dark", "home.sectionOrder": ["q"]] as [String: Any],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)

        let fresh = defaults()
        BackupDocument.apply(data, to: fresh, keys: keys)
        #expect(fresh.array(forKey: "home.sectionOrder") as? [String] == ["q"])

        let used = defaults()
        let scope = UUID().uuidString
        BackupDocument.apply(data, to: used, keys: keys, libraryScope: scope)
        #expect(used.array(forKey: "home.sectionOrder.\(scope)") as? [String] == ["q"])
        #expect(used.object(forKey: "home.sectionOrder") == nil)
    }

    @Test func keysOutsideTheAllowlistNeverLandAndWrongVersionsAreIgnored() throws {
        let document: [String: Any] = [
            "version": 1, "writtenAt": Date(), "deviceName": "x",
            "values": ["app.theme": "dark", "plex.clientIdentifier": "SAME-ON-TWO-DEVICES"] as [String: Any],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        let fresh = defaults()
        #expect(BackupDocument.apply(data, to: fresh, keys: keys) == 1)
        #expect(fresh.object(forKey: "plex.clientIdentifier") == nil)

        var newer = document
        newer["version"] = 99
        let future = try PropertyListSerialization.data(fromPropertyList: newer, format: .binary, options: 0)
        #expect(BackupDocument.apply(future, to: defaults(), keys: keys) == 0)
    }

    // MARK: persistence-04

    @Test func anOrderSavedUnderAPerLibraryKeyIsFoundAgain() {
        let d = defaults()
        let scope = UUID().uuidString
        d.set(["songs", "artists"], forKey: "search.resultOrder.\(scope)")
        d.set("x", forKey: "search.resultOrder.notAUUID")
        d.set("x", forKey: "search.resultOrderExtra")
        #expect(LibraryBackup.firstScopedValue(of: "search.resultOrder", in: d) as? [String] == ["songs", "artists"])
        #expect(LibraryBackup.firstScopedValue(of: "search.other", in: d) == nil)
    }

    // MARK: persistence-13

    @Test func anInstallThatHasNotRestoredDoesNotOverwriteASnapshotItDidNotWrite() {
        let theirs = Data("theirs".utf8), ours = Data("ours".utf8)
        // Not settled, and iCloud holds something this install never wrote.
        #expect(BackupWriteDecision.decide(settled: false, stored: theirs, lastWritten: nil) == .skip)
        #expect(BackupWriteDecision.decide(settled: false, stored: theirs, lastWritten: ours) == .skip)
        // Not settled, nothing there: write, and stop waiting for a restore.
        #expect(BackupWriteDecision.decide(settled: false, stored: nil, lastWritten: nil) == .writeAndSettle)
        // Its own earlier write is its own to replace.
        #expect(BackupWriteDecision.decide(settled: false, stored: ours, lastWritten: ours) == .write)
        // A settled install is the backup's author, whatever it finds.
        #expect(BackupWriteDecision.decide(settled: true, stored: theirs, lastWritten: nil) == .write)
    }

    @Test func aDocumentKeepsWithinTheBudgetByDroppingOtherLibrariesFirst() throws {
        let d = defaults()
        d.set("dark", forKey: "app.theme")
        let scope = UUID().uuidString
        try arrange(d, scope: scope, order: ["mine"], shelves: "mine", server: ServerID())
        // A stored document whose other library is enormous.
        let huge: [String: Any] = [
            "version": 1, "writtenAt": Date(), "deviceName": "x", "values": ["app.theme": "dark"],
            "libraries": ["fp-other": ["home.customSections": Data(count: 700_000)]],
        ]
        let stored = try PropertyListSerialization.data(fromPropertyList: huge, format: .binary, options: 0)
        let document = try snapshot(d, scope: scope, fingerprint: "fp-mine", stored: stored)
        #expect(document.count < LibraryBackup.documentBudget)
        #expect(Set(try #require(BackupDocument.storedLibraries(document)).keys) == ["fp-mine"])
    }
}
