import Foundation
import PleviDomain

/// The servers file, read so that one entry this build cannot decode does not cost the user the
/// others.
public enum ServerListFile {
    public struct Contents: Equatable, Sendable {
        public var servers: [ServerConfig]
        public var activeServerID: ServerID?
        /// Entries in the file that could not be decoded.
        public var skipped: Int

        public init(servers: [ServerConfig], activeServerID: ServerID?, skipped: Int) {
            self.servers = servers
            self.activeServerID = activeServerID
            self.skipped = skipped
        }
    }

    private struct Persisted: Encodable {
        var servers: [ServerConfig]
        var activeServerID: ServerID?
    }

    /// One entry, decoded or not. Never throws, so the container moves on to
    /// the next entry whatever was in this one.
    private struct Entry: Decodable {
        let config: ServerConfig?
        init(from decoder: any Decoder) throws {
            config = try? ServerConfig(from: decoder)
        }
    }

    private struct Document: Decodable {
        let servers: [Entry]
        let activeServerID: ServerID?

        enum CodingKeys: String, CodingKey { case servers, activeServerID }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            servers = try container.decode([Entry].self, forKey: .servers)
            activeServerID = try? container.decodeIfPresent(ServerID.self, forKey: .activeServerID)
        }
    }

    /// What the file holds, entry by entry. `nil` when it is not a server
    /// list at all, which is the case for a damaged file.
    public static func decode(_ data: Data) -> Contents? {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        let servers = document.servers.compactMap(\.config)
        return Contents(
            servers: servers,
            activeServerID: document.activeServerID,
            skipped: document.servers.count - servers.count
        )
    }

    public static func encode(servers: [ServerConfig], activeServerID: ServerID?) throws -> Data {
        try JSONEncoder().encode(Persisted(servers: servers, activeServerID: activeServerID))
    }

    /// Copies the file to `<name>.bad` beside it before anything is saved
    /// over it, unless a copy from an earlier problem is already there: the
    /// first copy is the one that has the servers in it.
    @discardableResult
    public static func keepCopy(of url: URL) -> URL? {
        let copy = URL(fileURLWithPath: url.path + ".bad")
        guard !FileManager.default.fileExists(atPath: copy.path) else { return copy }
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }
}
