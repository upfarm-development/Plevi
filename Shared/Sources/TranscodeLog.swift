import Foundation
import PleviDomain
import Synchronization
import os

/// The identifiers the app files its background work, keychain items and log lines under, taken
/// from the running bundle rather than written out.
enum AppIdentity {
    static let phone: String = {
        let bundle = Bundle.main
        return (bundle.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String)
            ?? bundle.bundleIdentifier
            ?? "plevi"
    }()

    /// This bundle's own identifier, which on the watch carries a suffix.
    static let own: String = Bundle.main.bundleIdentifier ?? phone
}

/// Everything that happens to a Plex transcode, in one place.
enum TranscodeLog {
    static let logger = Logger(subsystem: AppIdentity.phone, category: "transcode")

    private static let capacity = 20
    private static let lines = Mutex<[String]>([])

    /// Every line passes through `LogRedaction.scrub` first: the log is copied to the clipboard by
    /// Recent Problems and pasted into bug reports, and an interpolated error or URL can carry
    /// Subsonic's `u`, `t`, `s` or `apiKey`.
    static func record(_ rawMessage: String) {
        let message = LogRedaction.scrub(rawMessage)
        logger.debug("\(message, privacy: .public)")
        lines.withLock { buffer in
            buffer.append(message)
            if buffer.count > capacity { buffer.removeFirst() }
        }
        appendToFile(message)
    }

    /// An error as a line of the log: what it was, never what it carried.
    /// Interpolating the raw error prints `URLError`'s `userInfo`, failing
    /// URL and all.
    static func describe(_ error: any Error) -> String {
        LogRedaction.describe(error)
    }

    /// The last lines recorded, oldest first — for attaching to a failure.
    static func recentLines() -> [String] {
        lines.withLock { $0 }
    }

    // MARK: Persisted to disk, surviving a force quit
    //
    // The ring buffer above lives in memory: a hang that only shows up after
    // the app is force quit takes the story with it, exactly when there is
    // most to learn from it. Everything `record` is given also goes to a
    // plain file, which a force quit does not touch.

    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appending(path: "PlaybackLog", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let currentFile = directory.appending(path: "current.log")
    private static let previousFile = directory.appending(path: "previous.log")

    /// Rotates the last run's log out of the way and opens a fresh handle for this one, the first
    /// time anything is recorded.
    private static let handle: Mutex<FileHandle?> = {
        if FileManager.default.fileExists(atPath: currentFile.path) {
            try? FileManager.default.removeItem(at: previousFile)
            try? FileManager.default.moveItem(at: currentFile, to: previousFile)
        }
        FileManager.default.createFile(atPath: currentFile.path, contents: nil)
        return Mutex(try? FileHandle(forWritingTo: currentFile))
    }()

    private static func appendToFile(_ message: String) {
        let stamped = "\(timestamp()) \(message)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        handle.withLock { handle in
            guard let handle else { return }
            // Best-effort: a log write must never be why playback fails.
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static let stampFormat: Date.FormatStyle =
        .dateTime.hour().minute().second().secondFraction(.fractional(3))
    private static func timestamp() -> String { Date().formatted(stampFormat) }

    /// The full log this run has written so far.
    static func currentSessionLog() -> String {
        (try? String(contentsOf: currentFile, encoding: .utf8)) ?? ""
    }

    /// The run before this one. Read this after a force quit: by the time
    /// anyone opens Recent Problems in the new run, `currentSessionLog` is
    /// already this run's own and starts empty.
    static func previousSessionLog() -> String {
        (try? String(contentsOf: previousFile, encoding: .utf8)) ?? ""
    }
}

/// A switch for testing a hypothesis about the Plex transcoder without a
/// rebuild. It defaults to today's
/// behaviour, so leaving it alone changes nothing.
enum TranscodeDebugSettings {
    private enum Keys {
        static let reportsPosition = "debug.transcode.reportsPositionToPlex"
    }

    /// Whether the true playback position is reported to Plex every few seconds — build 345's
    /// behaviour, and the leading suspect for why the transcoder falls asleep mid-song (H2a).
    static var reportsPositionToPlex: Bool {
        get { UserDefaults.standard.object(forKey: Keys.reportsPosition) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.reportsPosition) }
    }
}
