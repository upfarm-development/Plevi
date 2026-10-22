import Foundation
import UIKit
import CryptoKit
import PleviDomain
import PleviTransport

/// Sleeves, at the two sizes a watch actually draws them.
actor WatchArtwork {
    private let provider: any MusicServerProvider
    private let transport: any HTTPTransport
    private let directory: URL
    /// `nonisolated` so a row can ask for what is already in memory without
    /// awaiting and without blinking a placeholder for one frame. `NSCache`
    /// is safe from any thread, which is all the unchecked part claims.
    private nonisolated(unsafe) let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// A row's thumbnail, and a sleeve filling the width of the screen.
    static let buckets = [96, 400]

    static func bucket(forPointSize points: CGFloat, scale: CGFloat = 2) -> Int {
        let pixels = Int((points * scale).rounded(.up))
        return buckets.first { $0 >= pixels } ?? buckets[buckets.count - 1]
    }

    private static let diskLimit: Int64 = 30 * 1_000_000
    private var fetchesSinceSweep = 0
    private static let sweepInterval = 100

    init(provider: any MusicServerProvider, transport: any HTTPTransport, storage: ServerID) {
        self.provider = provider
        self.transport = transport
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = caches
            .appending(path: "Artwork", directoryHint: .isDirectory)
            .appending(path: storage.rawValue.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 120
    }

    nonisolated func cached(_ id: ArtworkID, bucket: Int) -> UIImage? {
        memory.object(forKey: "\(id.rawValue)|\(bucket)" as NSString)
    }

    func image(for id: ArtworkID, bucket: Int) async -> UIImage? {
        let key = "\(id.rawValue)|\(bucket)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value }

        let file = directory.appending(path: Self.fileName(for: id, bucket: bucket))
        let task = Task<UIImage?, Never> { [provider, transport] in
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                return image
            }
            guard let request = try? await provider.artworkRequest(for: id, size: bucket),
                  let (data, response) = try? await transport.perform(request),
                  response.statusCode == 200,
                  let image = UIImage(data: data)
            else { return nil }
            try? data.write(to: file, options: .atomic)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        noteFetch()
        return image
    }

    private func noteFetch() {
        fetchesSinceSweep += 1
        guard fetchesSinceSweep >= Self.sweepInterval else { return }
        fetchesSinceSweep = 0
        let directory = self.directory
        Task.detached(priority: .utility) { Self.evict(in: directory) }
    }

    /// Oldest first, until the folder is under the ceiling. Modification
    /// date is a good enough stand-in for "least recently wanted" here: a
    /// sleeve is rewritten only when it is fetched again.
    private static func evict(in directory: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        let sized = entries.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = Int64(sized.reduce(0) { $0 + $1.1 })
        guard total > diskLimit else { return }
        for entry in sized.sorted(by: { $0.2 < $1.2 }) {
            guard total > diskLimit else { break }
            try? FileManager.default.removeItem(at: entry.0)
            total -= Int64(entry.1)
        }
    }

    /// SHA-256 rather than `Hasher`, which is seeded per process and would
    /// hand back a different name on every launch — the same reasoning the
    /// download store follows.
    private static func fileName(for id: ArtworkID, bucket: Int) -> String {
        let digest = SHA256.hash(data: Data(id.rawValue.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest)-\(bucket).img"
    }
}
