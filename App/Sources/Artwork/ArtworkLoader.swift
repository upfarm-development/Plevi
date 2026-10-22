import UIKit
import ImageIO
import CryptoKit
import os
import PleviDomain
import PleviTransport

/// Sized, cached artwork loading.
actor ArtworkLoader {
    /// Set once the server has been reached, and nil until then.
    private var provider: (any MusicServerProvider)?
    /// Where a song's downloaded file is, for the artwork that lives inside
    /// it — see `ArtworkID.embedded(in:)`. Read from the file on the phone,
    /// so it needs neither the server nor a connection.
    private var embeddedSource: (@Sendable (MediaID) async -> URL?)?
    private let transport: any HTTPTransport
    private let directory: URL
    /// `nonisolated` so a view can ask what is already in memory without awaiting — see
    /// `cachedImage(for:bucket:)`.
    private nonisolated(unsafe) let memory = NSCache<NSString, UIImage>()
    /// One sleeve held outside the cache.
    private nonisolated let pinned = OSAllocatedUnfairLock<(key: String, image: UIImage)?>(initialState: nil)

    /// One request per sleeve however many cells ask, called off when the
    /// last of them scrolls away. See `RequestCoalescer`.
    private let coalescer = RequestCoalescer<Fetched>()
    /// Network fetches allowed at once, newest asker first, so the sleeves a
    /// fling finally stops on are not queued behind every one it passed.
    private let gate = RecencyGate(limit: ArtworkLoader.concurrentFetches)
    private static let concurrentFetches = 5
    /// Sleeves whose last fetch failed, for a short while, so scrolling back
    /// over a dead link does not put the same requests out again and again.
    /// Cleared when the server changes (`use(_:)`) and with the cache.
    private var failures = FailureMemo(lifetime: 45)

    /// What one trip for a sleeve came to.
    private struct Fetched: Sendable {
        let image: UIImage?
        let answer: ArtworkAnswer
    }

    /// The in-memory cache is bounded by bytes as well as count: a few
    /// hundred full-size sleeves is several hundred megabytes of pixels.
    private static let memoryBudget = 120_000_000

    /// Pixel buckets sized for: list thumbnails, grid cells, detail headers,
    /// full-screen/lock-screen art.
    static let buckets = [120, 300, 640, 1200]

    static func bucket(forPointSize points: CGFloat, scale: CGFloat) -> Int {
        let pixels = Int((points * scale).rounded(.up))
        return buckets.first { $0 >= pixels } ?? buckets.last!
    }

    private var diskLimit: Int64
    /// Sleeves fetched since the last sweep. Eviction walks the whole
    /// directory, so it runs every so often rather than after every image.
    private var fetchesSinceSweep = 0
    private static let sweepInterval = 200

    init(
        transport: any HTTPTransport,
        serverID: ServerID,
        diskLimit: Int64 = ArtworkLoader.defaultDiskLimit
    ) {
        self.diskLimit = diskLimit
        self.transport = transport
        self.directory = Self.rootDirectory
            .appending(path: serverID.rawValue.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 300
        memory.totalCostLimit = Self.memoryBudget
        // Bounded on disk as well as in memory.
        let directory = self.directory
        let limit = diskLimit
        Task.detached(priority: .utility) { Self.evict(in: directory, limit: limit) }
    }

    /// Hands the loader the server, once there is one to hand it.
    func use(_ provider: any MusicServerProvider) {
        self.provider = provider
        // A new server, or the same one answering again: what failed a
        // moment ago is worth asking for afresh.
        failures.removeAll()
    }

    /// What a sleeve looks like, to tell whether two are the same picture.
    func signature(of id: ArtworkID) async -> ArtworkSignature? {
        guard let image = await image(for: id, bucket: 300), let cgImage = image.cgImage else { return nil }
        return ArtworkSignature(cgImage: cgImage)
    }

    func useEmbeddedSource(_ source: @escaping @Sendable (MediaID) async -> URL?) {
        embeddedSource = source
    }

    /// Roughly a large library's sleeves at grid size, and a few hundred of
    /// the big ones. Small next to the audio cache, and artwork is cheap to
    /// fetch again.
    static let defaultDiskLimit = ArtworkLoader.limit(megabytes: 500)

    /// Where every library's artwork folder lives; see `CacheTree`.
    static var rootDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Artwork", directoryHint: .isDirectory)
    }

    /// Decimal megabytes: `ByteCountFormatter`'s file style reports decimal
    /// units, and a "500 MB" ceiling that fills up to "524 MB" reads as a bug.
    static func limit(megabytes: Int) -> Int64 { Int64(megabytes) * 1_000_000 }

    /// Changes the ceiling, and tidies up straight away if the new one is
    /// lower than what is already held.
    func setDiskLimit(_ bytes: Int64) {
        guard bytes != diskLimit else { return }
        diskLimit = bytes
        let directory = self.directory
        Task.detached(priority: .utility) { Self.evict(in: directory, limit: bytes) }
    }

    /// Bytes held on disk, for the settings screen to report.
    func usage() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    func clear() {
        memory.removeAllObjects()
        failures.removeAll()
        fetchesSinceSweep = 0
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Least recently used first, by the date each file was last read or
    /// written — the same rule the audio cache follows.
    private static func evict(in directory: URL, limit: Int64) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return }

        var total: Int64 = 0
        var files: [(url: URL, used: Date, size: Int64)] = []
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
            files.append((url, values.contentModificationDate ?? .distantPast, Int64(size)))
        }
        // The limit is the app's: the other libraries' folders count against
        // it, and their oldest files go first. See `CacheTree.share`.
        let share = CacheTree.share(of: limit, root: rootDirectory, for: directory.lastPathComponent)
        guard total > share else { return }

        for file in files.sorted(by: { $0.used < $1.used }) {
            guard total > share else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// What is already in memory for this sleeve, answered without waiting.
    nonisolated func cachedImage(for id: ArtworkID, bucket: Int) -> UIImage? {
        let key = "\(id.rawValue)|\(bucket)"
        if let held = pinned.withLock({ $0 }), held.key == key { return held.image }
        return memory.object(forKey: key as NSString)
    }

    /// Takes over the sleeve another loader was holding, for a loader that
    /// replaces it while the same song plays on.
    nonisolated func adoptPin(from other: ArtworkLoader?) {
        guard let other, other !== self else { return }
        let held = other.pinned.withLock { $0 }
        pinned.withLock { $0 = held }
    }

    /// Whether any size of this sleeve is on the phone — in memory or on disk —
    /// without asking the server for anything.
    nonisolated func isOnPhone(_ id: ArtworkID) -> Bool {
        for bucket in Self.buckets {
            if memory.object(forKey: "\(id.rawValue)|\(bucket)" as NSString) != nil { return true }
            let file = directory.appending(path: Self.fileName(for: id, bucket: bucket))
            if FileManager.default.fileExists(atPath: file.path) { return true }
            if FileManager.default.fileExists(atPath: KeptArtwork.file(for: id, bucket: bucket).path) { return true }
        }
        return false
    }

    /// Whether this sleeve is already on the phone at exactly this size, in
    /// memory or on disk. A file's existence is all it looks at: nothing is
    /// read or decoded, so it is cheap to ask about a whole discography.
    nonisolated func hasImage(for id: ArtworkID, bucket: Int) -> Bool {
        if memory.object(forKey: "\(id.rawValue)|\(bucket)" as NSString) != nil { return true }
        let file = directory.appending(path: Self.fileName(for: id, bucket: bucket))
        return FileManager.default.fileExists(atPath: file.path)
            || FileManager.default.fileExists(atPath: KeptArtwork.file(for: id, bucket: bucket).path)
    }

    /// Copies a downloaded song's or playlist's sleeve, at the sizes a page uses, and the colours
    /// worked out from it, into storage the cache's limit and "Clear artwork cache" do not reach.
    func keep(_ id: ArtworkID) async {
        guard id.embeddedTrack == nil, !KeptArtwork.isKept(id) else { return }
        var big: UIImage?
        // 1200 is the page header's size; without it a page opened offline
        // has its colours and no picture.
        for bucket in KeptArtwork.buckets {
            guard let image = await self.image(for: id, bucket: bucket) else { continue }
            if bucket == 640 { big = image }
            let cached = directory.appending(path: Self.fileName(for: id, bucket: bucket))
            KeptArtwork.store(image, copying: cached, for: id, bucket: bucket)
        }
        // The palette marks a sleeve as kept, so it goes last.
        guard let big, KeptArtwork.hasFile(for: id, bucket: 1200) else { return }
        let analysis = await Task.detached(priority: .utility) {
            ArtworkPaletteExtractor.analysis(of: big)
        }.value
        KeptArtwork.save(analysis, for: id)
    }

    /// Keeps this one sleeve in memory whatever the cache does, replacing the
    /// one held before it.
    nonisolated func pin(_ image: UIImage, for id: ArtworkID, bucket: Int) {
        pinned.withLock { $0 = ("\(id.rawValue)|\(bucket)", image) }
    }

    func image(for id: ArtworkID, bucket: Int) async -> UIImage? {
        let key = "\(id.rawValue)|\(bucket)"

        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        // Stamped on every hit, so eviction can tell a sleeve you look at
        // often from one drawn once while scrolling past.
        let onDisk = directory.appending(path: Self.fileName(for: id, bucket: bucket))
        // A sleeve of another library's, kept by that library — a song of its downloads, listed
        // here by the merged Downloads screen, has its artwork in that library's folder and not in
        // this one's.
        if !FileManager.default.fileExists(atPath: onDisk.path),
           id.server.rawValue.uuidString != directory.lastPathComponent {
            let theirs = Self.rootDirectory
                .appending(path: id.server.rawValue.uuidString, directoryHint: .isDirectory)
                .appending(path: Self.fileName(for: id, bucket: bucket))
            if let data = try? Data(contentsOf: theirs), let image = UIImage(data: data) {
                memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                return image
            }
        }
        // Kept with a download: never evicted or cleared, so it is the copy
        // that is still there offline after the cache has been emptied.
        if !FileManager.default.fileExists(atPath: onDisk.path),
           let data = try? Data(contentsOf: KeptArtwork.file(for: id, bucket: bucket)),
           let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            return image
        }
        if !touch(onDisk) {
            // Not on the phone, and asked for and failed a moment ago: say so without another trip.
            if failures.isRemembered(key) { return nil }
            noteFetch()
        }

        let fileURL = onDisk
        let provider = self.provider
        let transport = self.transport
        let gate = self.gate
        let embedded = id.embeddedTrack.map { track in (track, self.embeddedSource) }
        let fetched = await coalescer.value(for: key) {
            if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
                return Fetched(image: image, answer: .delivered)
            }
            // A picture inside a downloaded file: nothing to ask a server.
            if let (track, source) = embedded {
                guard let url = await source?(track) else { return Fetched(image: nil, answer: .cancelled) }
                return Self.readEmbedded(from: url, bucket: bucket, to: fileURL)
            }
            // Nothing on disk and nowhere to ask yet. Not an error and not
            // worth remembering: the view asks again when the server
            // arrives.
            guard let provider else { return Fetched(image: nil, answer: .cancelled) }
            let trip = await gate.withPlace {
                await Self.fetchForBucket(
                    id, bucket: bucket, provider: provider, transport: transport, to: fileURL
                )
            }
            // Called off while waiting for a place: nothing was asked.
            return trip ?? Fetched(image: nil, answer: .cancelled)
        }
        // Nil is a caller that was cancelled before the answer came.
        guard let fetched else { return nil }
        if let image = fetched.image {
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        } else if fetched.answer.isWorthRemembering {
            failures.note(key)
        }
        return fetched.image
    }

    /// Stamps the file as used, and reports whether it was there at all — a
    /// miss means a fetch, and a fetch means something new on disk.
    @discardableResult
    private func touch(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return true
    }

    private func noteFetch() {
        fetchesSinceSweep += 1
        guard fetchesSinceSweep >= Self.sweepInterval else { return }
        fetchesSinceSweep = 0
        let directory = self.directory
        let limit = diskLimit
        Task.detached(priority: .utility) { Self.evict(in: directory, limit: limit) }
    }

    /// The sized sleeve, and — only if the server replied and the reply was about the request, not
    /// about the route to it — the original, shrunk to the size asked for before it is kept.
    private static func fetchForBucket(
        _ id: ArtworkID,
        bucket: Int,
        provider: any MusicServerProvider,
        transport: any HTTPTransport,
        to fileURL: URL
    ) async -> Fetched {
        let sized = await fetch(
            id, size: bucket, provider: provider, transport: transport, to: fileURL
        )
        guard sized.answer.allowsOriginalFallback, !Task.isCancelled else { return sized }
        return await fetch(
            id, size: nil, shrunkTo: bucket, provider: provider, transport: transport, to: fileURL
        )
    }

    private static func fetch(
        _ id: ArtworkID,
        size: Int?,
        shrunkTo limit: Int? = nil,
        provider: any MusicServerProvider,
        transport: any HTTPTransport,
        to fileURL: URL
    ) async -> Fetched {
        let request: URLRequest
        do {
            request = try await provider.artworkRequest(for: id, size: size)
        } catch {
            return Fetched(image: nil, answer: ended(by: error))
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.perform(request)
        } catch {
            return Fetched(image: nil, answer: ended(by: error))
        }
        let decoded = response.statusCode == 200 ? UIImage(data: data) : nil
        let answer = ArtworkAnswer.classify(statusCode: response.statusCode, bodyDecodes: decoded != nil)
        guard answer == .delivered, var image = decoded else {
            return Fetched(image: nil, answer: answer)
        }
        var bytes = data
        if let limit, let small = shrink(data, to: limit) {
            image = small.image
            bytes = small.data
        }
        try? bytes.write(to: fileURL, options: .atomic)
        return Fetched(image: image, answer: .delivered)
    }

    /// The picture in an audio file's tags, shrunk to the size asked for and
    /// kept like any other sleeve.
    private static func readEmbedded(from url: URL, bucket: Int, to fileURL: URL) -> Fetched {
        guard let data = EmbeddedPicture.read(from: url), var image = UIImage(data: data) else {
            return Fetched(image: nil, answer: .rejected)
        }
        var bytes = data
        if let small = shrink(data, to: bucket) {
            image = small.image
            bytes = small.data
        }
        try? bytes.write(to: fileURL, options: .atomic)
        return Fetched(image: image, answer: .delivered)
    }

    /// A request that threw: called off, or did not get through.
    private static func ended(by error: any Error) -> ArtworkAnswer {
        Task.isCancelled || error.isCancelledFetch ? .cancelled : .unreachable
    }

    /// The picture scaled so its longer side is `limit` pixels, re-encoded,
    /// or nil when it is already that small (or cannot be read).
    private static func shrink(_ data: Data, to limit: Int) -> (image: UIImage, data: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > limit
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: scaled)
        guard let encoded = image.jpegData(compressionQuality: 0.9) else { return nil }
        return (image, encoded)
    }

    /// Bytes of pixels, for the memory cache's budget.
    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    /// Artwork IDs are server-defined strings; hash them for a safe filename.
    static func fileName(for id: ArtworkID, bucket: Int) -> String {
        let digest = SHA256.hash(data: Data(id.rawValue.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest)-\(bucket).img"
    }
}


/// Artwork and colours that belong to downloads rather than to the cache.
enum KeptArtwork {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "KeptArtwork", directoryHint: .isDirectory)
    }

    private static func directory(for id: ArtworkID) -> URL {
        root.appending(path: id.server.rawValue.uuidString, directoryHint: .isDirectory)
    }

    static func file(for id: ArtworkID, bucket: Int) -> URL {
        directory(for: id).appending(path: ArtworkLoader.fileName(for: id, bucket: bucket))
    }

    /// The sizes kept: the rows, the grid, the page, and the page's header.
    static let buckets = [120, 300, 640, 1200]

    private static func paletteName(for id: ArtworkID) -> String {
        ArtworkLoader.fileName(for: id, bucket: 0).replacingOccurrences(of: ".img", with: ".palette")
    }

    private static func paletteFile(for id: ArtworkID) -> URL {
        directory(for: id).appending(path: paletteName(for: id))
    }

    /// Removes a library's kept files that belong to none of `rawIDs`.
    static func prune(server: ServerID, keeping rawIDs: Set<String>, root: URL = KeptArtwork.root) {
        let folder = root.appending(path: server.rawValue.uuidString, directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        var wanted = Set<String>()
        for raw in rawIDs {
            let id = ArtworkID(server: server, rawValue: raw)
            wanted.insert(paletteName(for: id))
            for bucket in buckets { wanted.insert(ArtworkLoader.fileName(for: id, bucket: bucket)) }
        }
        for name in names where !wanted.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// Complete only with the header size as well as the colours, so
    /// sleeves kept before the header size was kept are filled in.
    static func isKept(_ id: ArtworkID) -> Bool {
        FileManager.default.fileExists(atPath: paletteFile(for: id).path) && hasFile(for: id, bucket: 1200)
    }

    static func hasFile(for id: ArtworkID, bucket: Int) -> Bool {
        FileManager.default.fileExists(atPath: file(for: id, bucket: bucket).path)
    }

    static func palette(for id: ArtworkID) -> StoredPalette? {
        guard let data = try? Data(contentsOf: paletteFile(for: id)) else { return nil }
        return try? JSONDecoder().decode(StoredPalette.self, from: data)
    }

    static func save(_ palette: StoredPalette, for id: ArtworkID) {
        guard let data = try? JSONEncoder().encode(palette) else { return }
        prepare(directory(for: id))
        try? data.write(to: paletteFile(for: id), options: .atomic)
    }

    static func copy(_ source: URL, for id: ArtworkID, bucket: Int) {
        prepare(directory(for: id))
        let target = file(for: id, bucket: bucket)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
    }

    /// The cache's own file when there is one, otherwise the picture as JPEG.
    static func store(_ image: UIImage, copying cached: URL, for id: ArtworkID, bucket: Int) {
        if FileManager.default.fileExists(atPath: cached.path) {
            copy(cached, for: id, bucket: bucket)
        } else if let data = image.jpegData(compressionQuality: 0.9) {
            prepare(directory(for: id))
            try? data.write(to: file(for: id, bucket: bucket), options: .atomic)
        }
    }

    private static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
