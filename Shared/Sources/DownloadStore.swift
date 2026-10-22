import Foundation
import CryptoKit
import PleviDomain

/// Where kept files live.
struct DownloadStore: Sendable {
    let directory: URL

    init(serverID: ServerID) {
        directory = Self.rootDirectory
            .appending(path: serverID.rawValue.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup()
    }

    /// A store to look in, not to keep things in: the same folder, but nothing
    /// is made or marked. Asking whether another library has a file must not
    /// write to the disk each time it is asked.
    init(lookingIn serverID: ServerID) {
        directory = Self.rootDirectory
            .appending(path: serverID.rawValue.uuidString, directoryHint: .isDirectory)
    }

    /// The folder holding every library's downloads, one folder each.
    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Plevi", directoryHint: .isDirectory)
            .appending(path: "Downloads", directoryHint: .isDirectory)
    }

    /// What every library's downloads take, for the Storage screen's
    /// "Space used". The open library's `usage()` is the figure for the
    /// Downloads page; the phone holds the others too.
    static func usageOfEveryLibrary() -> Int64 {
        CacheTree.usage(of: rootDirectory)
    }

    private func excludeFromBackup() {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The name a track's file takes. The same shape as the play cache's, and
    /// for the same reason: SHA-256 rather than `Hasher`, which is seeded per
    /// process and would hand back a different name on every launch.
    static func fileName(for id: MediaID, variant: MediaVariant, fileExtension: String) -> String {
        let digest = SHA256.hash(data: Data(id.rawValue.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = fileExtension.isEmpty ? "audio" : fileExtension
        return "\(digest)-\(variant.tag).\(ext)"
    }

    func url(named name: String) -> URL {
        directory.appending(path: name)
    }

    /// The file, if it is really there. A row in the table saying "done" and
    /// no file on disk is the state to be ready for: iOS does not delete these
    /// but a restore, a bug or a hand on a debugger can.
    func existingFile(named name: String?) -> URL? {
        guard let name else { return nil }
        let url = url(named: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func size(of name: String) -> Int64 {
        let values = try? url(named: name).resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    func remove(named name: String) {
        // An empty name resolves to the directory itself, and removing that
        // takes every download on the device with it. Never a real file, so
        // never a real removal.
        guard !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(named: name))
    }

    func usage() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup()
    }

    /// Files with no row in the table behind them — the leftovers of a
    /// download that was cancelled at the wrong moment, or of a table that was
    /// rebuilt. Swept at startup rather than left to accumulate silently.
    func removeFiles(notNamed kept: Set<String>) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        var removed = 0
        for url in entries where !kept.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }
}

/// Pictures kept beside converted downloads.
struct EmbeddedArtStore: Sendable {
    let directory: URL

    init(serverID: ServerID) {
        directory = DownloadStore.rootDirectory
            .deletingLastPathComponent()
            .appending(path: "EmbeddedArt", directoryHint: .isDirectory)
            .appending(path: serverID.rawValue.uuidString, directoryHint: .isDirectory)
    }

    static func fileName(for id: MediaID) -> String {
        let digest = SHA256.hash(data: Data(id.rawValue.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).img"
    }

    func existing(for id: MediaID) -> URL? {
        let url = directory.appending(path: Self.fileName(for: id))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func write(_ data: Data, for id: MediaID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appending(path: Self.fileName(for: id))
        try? data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func remove(for id: MediaID) {
        try? FileManager.default.removeItem(at: directory.appending(path: Self.fileName(for: id)))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Everything but the pictures of the songs given: what is left of
    /// downloads that were removed.
    func removeAll(except songs: [MediaID]) {
        let kept = Set(songs.map(Self.fileName(for:)))
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in entries where !kept.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
