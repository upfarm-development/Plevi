import Foundation
import CryptoKit

/// Decoded copies of the files iOS cannot read, kept only as long as they are wanted.
public actor DecodedAudioCache {
    public static let shared = DecodedAudioCache()

    /// What the engine should be handed for a file.
    public struct Playable: Sendable {
        /// The file itself, or its decoded copy.
        public let url: URL
        /// Set when `url` is a decoded copy: what the original was.
        public let source: VorbisSourceInfo?
    }

    /// The song playing, the one behind it in a gapless join, and a little room
    /// for the one just left and for a skip.
    private let capacity: Int
    private let directory: URL
    private var inFlight: [String: Task<Playable, Never>] = [:]
    private var known: [String: VorbisSourceInfo] = [:]
    private var swept = false

    public init(
        capacity: Int = 4,
        directory: URL = FileManager.default.temporaryDirectory.appending(path: "PleviDecoded", directoryHint: .isDirectory)
    ) {
        self.capacity = capacity
        self.directory = directory
    }

    /// The file as it stands, or — for Ogg Vorbis — a decoded copy.
    public func playable(_ file: URL) async -> Playable {
        guard VorbisFile.isVorbis(at: file) else { return Playable(url: file, source: nil) }
        sweepOnce()
        let key = Self.key(for: file)
        let copy = directory.appending(path: key + ".caf")
        if FileManager.default.fileExists(atPath: copy.path), let info = known[key] {
            touch(copy)
            return Playable(url: copy, source: info)
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { [directory] () -> Playable in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let info = try VorbisDecoder.decode(file, to: copy)
                return Playable(url: copy, source: info)
            } catch {
                return Playable(url: file, source: nil)
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let info = result.source {
            known[key] = info
            trim(keeping: copy)
        }
        return result
    }

    /// What `playableEarly` hands back.
    public struct EarlyPlayable: Sendable {
        public let playable: Playable
        /// False when `playable.url` is a copy that is still being written: the
        /// caller plays it as a growing file and is told by `onComplete` when it
        /// is whole.
        public let isComplete: Bool
    }

    /// Like `playable`, but returns as soon as the first seconds of a Vorbis song are decoded, with
    /// the rest still being written, so a song can start in a fraction of a second instead of after
    /// the whole of it.
    public func playableEarly(
        _ file: URL,
        onComplete: @escaping @Sendable (Bool) -> Void
    ) async -> EarlyPlayable {
        guard VorbisFile.isVorbis(at: file) else {
            return EarlyPlayable(playable: Playable(url: file, source: nil), isComplete: true)
        }
        sweepOnce()
        let key = Self.key(for: file)
        let copy = directory.appending(path: key + ".caf")
        if FileManager.default.fileExists(atPath: copy.path), let info = known[key] {
            touch(copy)
            return EarlyPlayable(playable: Playable(url: copy, source: info), isComplete: true)
        }
        // A whole copy is already being made for the read-ahead: wait for it.
        if let running = inFlight[key] {
            return EarlyPlayable(playable: await running.value, isComplete: true)
        }
        let directory = self.directory
        let start = EarlyStart()
        let job = Task.detached(priority: .userInitiated) { () -> Playable in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let info = try VorbisDecoder.decodeProgressively(file, to: copy) { partial in
                    start.resume(Playable(url: copy, source: partial), isComplete: false)
                }
                let done = Playable(url: copy, source: info)
                // A song shorter than the lead-in: it was already whole.
                start.resume(done, isComplete: true)
                if start.resumedAsPartial { onComplete(true) }
                return done
            } catch {
                start.resume(nil, isComplete: true)
                if start.resumedAsPartial { onComplete(false) }
                return Playable(url: file, source: nil)
            }
        }
        inFlight[key] = job
        let first = await start.wait()
        Task { [weak self] in
            let result = await job.value
            await self?.finishEarly(key: key, copy: copy, result: result)
        }
        guard let first else {
            return EarlyPlayable(playable: Playable(url: file, source: nil), isComplete: true)
        }
        return EarlyPlayable(playable: first.playable, isComplete: first.isComplete)
    }

    private func finishEarly(key: String, copy: URL, result: Playable) {
        inFlight[key] = nil
        if let info = result.source {
            known[key] = info
            trim(keeping: copy)
        }
    }

    private static func key(for file: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(file.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(stamp.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Whatever an earlier run left behind is gone before this one starts
    /// adding to it.
    private func sweepOnce() {
        guard !swept else { return }
        swept = true
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The oldest copies go once there are more than the capacity.
    private func trim(keeping fresh: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let copies = entries.filter { $0.pathExtension == "caf" }
        guard copies.count > capacity else { return }
        let ordered = copies.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return first < second
        }
        for old in ordered.prefix(copies.count - capacity) where old != fresh {
            try? FileManager.default.removeItem(at: old)
            known[old.deletingPathExtension().lastPathComponent] = nil
        }
    }
}

/// Hands the first answer of a decode to whoever is waiting for it, once.
private final class EarlyStart: @unchecked Sendable {
    struct Answer { let playable: DecodedAudioCache.Playable; let isComplete: Bool }
    private let lock = NSLock()
    private var answer: Answer??
    private var waiter: CheckedContinuation<Answer?, Never>?
    private(set) var resumedAsPartial = false

    func resume(_ playable: DecodedAudioCache.Playable?, isComplete: Bool) {
        lock.lock()
        guard answer == nil else { lock.unlock(); return }
        let value = playable.map { Answer(playable: $0, isComplete: isComplete) }
        answer = .some(value)
        if value != nil, !isComplete { resumedAsPartial = true }
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func wait() async -> Answer? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let ready = answer {
                lock.unlock()
                continuation.resume(returning: ready)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
