import Foundation
import CryptoKit
import PleviDomain
import PleviTransport

/// Which library a cache belongs to, and where that library's index lives.
enum LibraryStorage {
    /// The identity a server's *caches* are filed under: the server itself when it has one library,
    /// and a value derived from both when it has several.
    static func id(for config: ServerConfig) -> ServerID {
        guard let key = config.library?.key, !key.isEmpty else { return config.id }
        var hasher = SHA256()
        hasher.update(data: Data(config.id.rawValue.uuidString.utf8))
        hasher.update(data: Data("/".utf8))
        hasher.update(data: Data(key.utf8))
        let digest = Array(hasher.finalize())
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { raw in
            for index in 0..<16 { raw[index] = digest[index] }
        }
        return ServerID(rawValue: UUID(uuid: bytes))
    }

    /// Application Support is per-container, so this is the same *name* on both devices and never
    /// the same *file*.
    static func indexURL(for id: ServerID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Plevi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appending(path: "index-\(id.rawValue.uuidString).sqlite")
    }
}
