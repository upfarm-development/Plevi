import Foundation
import Testing
@testable import PleviDomain

@Suite("What the watch holds per library, and when it is resent (watch-02, watch-05)")
struct WatchStorageTests {
    private let a = ServerID()
    private let b = ServerID()

    /// A directory laid out the way the watch lays one out: snapshot indexes
    /// beside a `Downloads` folder with one directory per library.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "watch-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func populate(_ id: ServerID, in root: URL, indexBytes: Int = 100, songs: [Int] = [10, 20]) throws {
        let name = id.rawValue.uuidString
        try Data(count: indexBytes).write(to: root.appending(path: "index-\(name).sqlite"))
        try Data(count: 7).write(to: root.appending(path: "index-\(name).sqlite-wal"))
        let folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (number, size) in songs.enumerated() {
            try Data(count: size).write(to: folder.appending(path: "song-\(number).mp3"))
        }
    }

    private func exists(_ id: ServerID, in root: URL) -> Bool {
        WatchLibraryFiles.locations(of: id, in: root).contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    // MARK: Removal

    @Test("Removing a library deletes its index, log files and downloads")
    func removalDeletesEverythingOfThatLibrary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try populate(a, in: root)
        try populate(b, in: root)

        let freed = WatchLibraryFiles.remove(a, in: root)

        #expect(freed == 100 + 7 + 10 + 20)
        #expect(!exists(a, in: root))
        // The other library is untouched: a switch from A to B never deletes A,
        // and a removal of A never touches B.
        #expect(exists(b, in: root))
        let remaining = WatchLibraryFiles.held(in: root)
        #expect(remaining[b] == Int64(137))
    }

    @Test("Removing a library that holds nothing frees nothing and throws nothing")
    func removingNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WatchLibraryFiles.remove(a, in: root) == 0)
    }

    // MARK: Enumeration

    @Test("Every library with anything on disk is listed, with its size")
    func heldListsEachLibrary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try populate(a, in: root, indexBytes: 1_000, songs: [])
        try populate(b, in: root, indexBytes: 10, songs: [500])
        // A directory of songs whose index is gone is still something to free.
        let orphan = ServerID()
        let folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
            .appending(path: orphan.rawValue.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 300).write(to: folder.appending(path: "x.mp3"))
        // Files that are not any library's are not listed.
        try Data(count: 50).write(to: root.appending(path: "notes.txt"))
        try Data(count: 50).write(to: root.appending(path: "index-not-a-uuid.sqlite"))

        let held = WatchLibraryFiles.held(in: root)

        #expect(held.count == 3)
        #expect(held[a] == 1_007)
        #expect(held[b] == 517)
        #expect(held[orphan] == 300)
    }

    @Test("A staged snapshot counts towards its library and is swept at launch")
    func stagedSnapshotsAreSwept() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try populate(a, in: root, indexBytes: 10, songs: [])
        let staged = root.appending(path: "incoming-\(a.rawValue.uuidString).sqlite")
        try Data(count: 4_000).write(to: staged)
        #expect(WatchLibraryFiles.held(in: root)[a] == 4_017)

        let freed = WatchLibraryFiles.sweepStagedSnapshots(in: root)

        #expect(freed == 4_000)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        // The library's own index is not a staged file.
        #expect(WatchLibraryFiles.held(in: root)[a] == 17)
    }

    // MARK: Resending

    private let hour: TimeInterval = 3_600
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test("A library never sent goes straight away, inside the hour")
    func newLibraryBypassesTheThrottle() {
        // A was sent ten minutes ago; the phone is switched to B.
        #expect(WatchLibrarySend.mayAutoSend(
            storage: b, lastSentStorage: a,
            lastSentAt: now.addingTimeInterval(-600), now: now, minimumInterval: hour
        ))
        #expect(WatchLibrarySend.isOwed(
            storage: b, lastSentStorage: a, lastSentAt: now.addingTimeInterval(-600)
        ))
    }

    @Test("The same library is still held to the hour")
    func sameLibraryIsThrottled() {
        #expect(!WatchLibrarySend.mayAutoSend(
            storage: a, lastSentStorage: a,
            lastSentAt: now.addingTimeInterval(-600), now: now, minimumInterval: hour
        ))
        #expect(WatchLibrarySend.mayAutoSend(
            storage: a, lastSentStorage: a,
            lastSentAt: now.addingTimeInterval(-3_601), now: now, minimumInterval: hour
        ))
        #expect(!WatchLibrarySend.isOwed(
            storage: a, lastSentStorage: a, lastSentAt: now.addingTimeInterval(-600)
        ))
    }

    @Test("A watch that was never sent anything is owed one")
    func neverSent() {
        #expect(WatchLibrarySend.mayAutoSend(
            storage: a, lastSentStorage: nil, lastSentAt: nil, now: now, minimumInterval: hour
        ))
        #expect(WatchLibrarySend.isOwed(storage: a, lastSentStorage: nil, lastSentAt: nil))
    }

    @Test("A send recorded before libraries were tracked is not resent on update")
    func legacyStamp() {
        // lastSentStorage is nil but a date exists: a build from before this
        // change. Resending tens of megabytes because of an app update would
        // be the worse mistake.
        #expect(!WatchLibrarySend.isOwed(
            storage: a, lastSentStorage: nil, lastSentAt: now.addingTimeInterval(-600)
        ))
        #expect(!WatchLibrarySend.mayAutoSend(
            storage: a, lastSentStorage: nil,
            lastSentAt: now.addingTimeInterval(-600), now: now, minimumInterval: hour
        ))
    }
}
