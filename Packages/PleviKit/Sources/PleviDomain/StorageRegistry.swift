import Foundation

/// Which storage identities each configured server has ever used.
public struct StorageRegistry: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        var server: ServerID
        var storage: [ServerID]
    }

    private var entries: [Entry] = []

    public init() {}

    /// Notes that `server` files something under `storage`. `true` when that
    /// is news, which is when the registry needs writing.
    @discardableResult
    public mutating func record(storage: ServerID, forServer server: ServerID) -> Bool {
        if let index = entries.firstIndex(where: { $0.server == server }) {
            guard !entries[index].storage.contains(storage) else { return false }
            entries[index].storage.append(storage)
        } else {
            entries.append(Entry(server: server, storage: [storage]))
        }
        return true
    }

    /// Every identity `server` has used.
    public func storageIDs(ofServer server: ServerID) -> Set<ServerID> {
        Set(entries.first { $0.server == server }?.storage ?? [])
    }

    /// The server a storage identity belongs to, if it was ever written down.
    public func server(owningStorage storage: ServerID) -> ServerID? {
        entries.first { $0.storage.contains(storage) }?.server
    }

    /// Drops a server and answers the identities it had.
    @discardableResult
    public mutating func forget(server: ServerID) -> Set<ServerID> {
        let ids = storageIDs(ofServer: server)
        entries.removeAll { $0.server == server }
        return ids
    }

    // MARK: File

    /// Thrown by `load(from:)` for a file that is there and cannot be used.
    public struct Unreadable: Error {}

    /// The registry at `url`.
    public static func load(from url: URL) throws -> StorageRegistry {
        guard FileManager.default.fileExists(atPath: url.path) else { return StorageRegistry() }
        guard let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(StorageRegistry.self, from: data)
        else { throw Unreadable() }
        return registry
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
