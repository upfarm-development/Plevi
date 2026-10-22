import Foundation
import Testing
@testable import PleviDomain

@Suite("One cache limit across every library folder")
struct CacheTreeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Library folders with files of known size and age (seconds before
    /// `now`), under a fresh root.
    private func tree(_ libraries: [String: [(name: String, bytes: Int, age: TimeInterval)]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cachetree-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (library, files) in libraries {
            let folder = root.appending(path: library, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                let url = folder.appending(path: file.name)
                try Data(count: file.bytes).write(to: url)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-file.age)],
                    ofItemAtPath: url.path
                )
            }
        }
        return root
    }

    private func names(_ root: URL, _ library: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: library).path)) ?? []).sorted()
    }

    private let hour: TimeInterval = 3600

    @Test func usageSumsEveryLibrary() throws {
        let root = try tree([
            "a": [("1", 100, hour), ("2", 50, hour)],
            "b": [("1", 200, hour)],
            "c": [("1", 7, hour)],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CacheTree.usage(of: root) == 357)
    }

    @Test func aMissingRootHoldsNothing() {
        let root = FileManager.default.temporaryDirectory.appending(path: "nope-\(UUID().uuidString)")
        #expect(CacheTree.usage(of: root) == 0)
        #expect(CacheTree.trim(root: root, to: 0, sparing: nil) == 0)
    }

    @Test func trimRemovesTheOldestAcrossLibrariesAndSparesTheOpenOne() throws {
        let root = try tree([
            "open": [("o1", 100, 10 * hour)],
            "x": [("x-old", 100, 9 * hour), ("x-new", 100, 2 * hour)],
            "y": [("y-mid", 100, 5 * hour)],
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        // 400 held, 250 allowed: the open library's file is older than
        // everything but is not this function's to remove.
        let removed = CacheTree.trim(root: root, to: 250, sparing: "open", now: now)
        #expect(removed == 200)
        #expect(names(root, "open") == ["o1"])
        #expect(names(root, "x") == ["x-new"])
        #expect(names(root, "y").isEmpty)
    }

    @Test func trimStopsOnceUnderTheLimit() throws {
        let root = try tree(["x": [("a", 100, 9 * hour), ("b", 100, 8 * hour), ("c", 100, 7 * hour)]])
        defer { try? FileManager.default.removeItem(at: root) }
        CacheTree.trim(root: root, to: 200, sparing: nil, now: now)
        #expect(names(root, "x") == ["b", "c"])
    }

    @Test func trimLeavesPartialAndRecentFilesAlone() throws {
        let root = try tree([
            "x": [("song.partial", 500, 9 * hour), ("just-played", 500, 60), ("old", 500, 9 * hour)],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        CacheTree.trim(root: root, to: 0, sparing: nil, now: now)
        #expect(names(root, "x") == ["just-played", "song.partial"])
    }

    @Test func nothingIsRemovedUnderTheLimit() throws {
        let root = try tree(["x": [("a", 100, 9 * hour)]])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CacheTree.trim(root: root, to: 100, sparing: nil, now: now) == 0)
        #expect(names(root, "x") == ["a"])
    }

    @Test func clearRemovesEveryOtherLibraryFolder() throws {
        let root = try tree([
            "open": [("o", 10, hour)], "x": [("a", 10, hour)], "y": [("b", 10, hour)],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        CacheTree.clear(root: root, except: "open")
        #expect(names(root, "open") == ["o"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "x").path))
        #expect(CacheTree.usage(of: root) == 10)
    }

    @Test func shareTrimsTheOthersAndLeavesWhatRemainsToTheOwnFolder() throws {
        let root = try tree([
            "own": [("o", 300, hour)],
            "x": [("x-old", 200, 9 * hour), ("x-new", 200, 2 * hour)],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        // 700 held, 500 allowed: x's oldest goes, leaving 200 for the others.
        let share = CacheTree.share(of: 500, root: root, for: "own", now: now)
        #expect(names(root, "x") == ["x-new"])
        #expect(share == 300)
        #expect(names(root, "own") == ["o"])
    }

    @Test func shareNeverFallsBelowAQuarterOfTheLimit() throws {
        // Files this young are not trimmed, so the others can exceed the limit.
        let root = try tree(["own": [("o", 10, hour)], "x": [("fresh", 900, 60)]])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CacheTree.share(of: 400, root: root, for: "own", now: now) == 100)
    }
}
