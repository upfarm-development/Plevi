import Foundation

/// A folder of per-library cache folders, treated as one cache.
public enum CacheTree {
    /// Every file under every library folder of `root`, with what the
    /// housekeeping needs to know about it.
    public struct Entry {
        public let url: URL
        public let library: String
        public let size: Int64
        public let used: Date
    }

    /// Files younger than this are left alone by `trim`: the tail of a
    /// download still being written, or a song played a moment ago.
    public static let recentWindow: TimeInterval = 10 * 60

    public static func entries(in root: URL) -> [Entry] {
        let manager = FileManager.default
        guard let libraries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var found: [Entry] = []
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        for folder in libraries {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys)
            ) else { continue }
            for url in files {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isDirectory != true else { continue }
                found.append(Entry(
                    url: url,
                    library: folder.lastPathComponent,
                    size: Int64(values.fileSize ?? 0),
                    used: values.contentModificationDate ?? .distantPast
                ))
            }
        }
        return found
    }

    /// Bytes held by every library folder under `root`.
    public static func usage(of root: URL) -> Int64 {
        entries(in: root).reduce(0) { $0 + $1.size }
    }

    /// Brings the whole tree under `limit` by removing the least recently used files of the
    /// libraries other than `sparing`, oldest first.
    @discardableResult
    public static func trim(
        root: URL,
        to limit: Int64,
        sparing: String?,
        now: Date = Date()
    ) -> Int64 {
        let all = entries(in: root)
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return 0 }
        let candidates = all
            .filter { $0.library != sparing }
            .filter { !$0.url.lastPathComponent.hasSuffix(".partial") }
            .filter { now.timeIntervalSince($0.used) > recentWindow }
            .sorted { $0.used < $1.used }
        var removed: Int64 = 0
        for entry in candidates {
            guard total > limit else { break }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.size
            removed += entry.size
        }
        return removed
    }

    /// What one library's own folder may hold under `limit`, after the other libraries' oldest
    /// files have been trimmed to make room for it.
    public static func share(of limit: Int64, root: URL, for library: String, now: Date = Date()) -> Int64 {
        trim(root: root, to: limit, sparing: library, now: now)
        let others = entries(in: root)
            .filter { $0.library != library }
            .reduce(Int64(0)) { $0 + $1.size }
        return max(limit - others, limit / 4)
    }

    /// Removes every library folder under `root` except `sparing`, which the
    /// caller clears through its own store so a file being written into it is
    /// not pulled out from under it twice over.
    public static func clear(root: URL, except sparing: String?) {
        guard let libraries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for folder in libraries where folder.lastPathComponent != sparing {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
