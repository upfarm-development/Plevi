import Foundation

/// What the watch keeps on disk for each library, and the rules for when the phone resends a
/// library and when the watch may delete one.
public enum WatchLibraryFiles {
    /// Every file and directory belonging to one library, under the directory the snapshot indexes
    /// live in (`Application Support/Plevi`).
    public static func locations(of storage: ServerID, in root: URL) -> [URL] {
        let name = storage.rawValue.uuidString
        var urls: [URL] = []
        for stem in ["index-\(name).sqlite", "incoming-\(name).sqlite"] {
            for suffix in ["", "-wal", "-shm"] {
                urls.append(root.appending(path: stem + suffix))
            }
        }
        urls.append(
            root.appending(path: "Downloads", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
        )
        return urls
    }

    /// Every library this directory holds something for, with the bytes each
    /// takes. Found by looking at the file names, which are the only record.
    public static func held(in root: URL) -> [ServerID: Int64] {
        let manager = FileManager.default
        var found: [ServerID: Int64] = [:]
        func add(_ id: ServerID, _ url: URL) {
            found[id, default: 0] += size(of: url)
        }
        for entry in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if let id = id(fromFileName: entry.lastPathComponent) { add(id, entry) }
        }
        let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
        for entry in (try? manager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? [] {
            if let uuid = UUID(uuidString: entry.lastPathComponent) {
                add(ServerID(rawValue: uuid), entry)
            }
        }
        return found
    }

    /// Deletes everything a library left and answers how many bytes that was.
    @discardableResult
    public static func remove(_ storage: ServerID, in root: URL) -> Int64 {
        var freed: Int64 = 0
        for url in locations(of: storage, in: root) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            freed += size(of: url)
            try? FileManager.default.removeItem(at: url)
        }
        return freed
    }

    /// The library an `index-<uuid>.sqlite[-wal|-shm]` or `incoming-<uuid>...`
    /// file belongs to.
    static func id(fromFileName name: String) -> ServerID? {
        for prefix in ["index-", "incoming-"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard rest.count >= 36 else { return nil }
            let uuid = String(rest.prefix(36))
            let tail = rest.dropFirst(36)
            guard ["", ".sqlite", ".sqlite-wal", ".sqlite-shm"].contains(String(tail)),
                  let parsed = UUID(uuidString: uuid)
            else { return nil }
            return ServerID(rawValue: parsed)
        }
        return nil
    }

    /// Removes the half-arrived snapshots a killed install left behind.
    @discardableResult
    public static func sweepStagedSnapshots(in root: URL) -> Int64 {
        var freed: Int64 = 0
        for entry in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent.hasPrefix("incoming-") {
            freed += size(of: entry)
            try? FileManager.default.removeItem(at: entry)
        }
        return freed
    }

    static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let entries = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let file = entries?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

/// When the phone sends the watch a library snapshot on its own.
public enum WatchLibrarySend {
    /// A snapshot is tens of megabytes, so automatic sends are rate limited to one an hour.
    public static func mayAutoSend(
        storage: ServerID,
        lastSentStorage: ServerID?,
        lastSentAt: Date?,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let lastSentAt else { return true }
        // A send from before the library was recorded (nil) is taken to be of
        // this one: resending tens of megabytes on the strength of an update
        // would be the worse mistake.
        if let lastSentStorage, lastSentStorage != storage { return true }
        return now.timeIntervalSince(lastSentAt) >= minimumInterval
    }

    /// Whether the watch is owed a snapshot for `storage` that it was never
    /// sent, whatever the clock says.
    public static func isOwed(
        storage: ServerID?,
        lastSentStorage: ServerID?,
        lastSentAt: Date?
    ) -> Bool {
        guard lastSentAt != nil else { return true }
        guard let storage, let lastSentStorage else { return false }
        return storage != lastSentStorage
    }
}
