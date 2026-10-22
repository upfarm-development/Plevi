import Foundation
import Observation

/// The watch's own preferences, in the watch's own `UserDefaults`.
@MainActor
@Observable
final class WatchSettings {
    /// Which page the pager opens on.
    var startPage: StartPage {
        didSet { defaults.set(startPage.rawValue, forKey: Keys.startPage) }
    }

    /// What to ask the server for when playing now, and what to ask for when keeping a copy.
    var streaming: WatchAudioChoice {
        didSet { streaming.write(to: defaults, under: Keys.streaming) }
    }

    var downloads: WatchAudioChoice {
        didSet { downloads.write(to: defaults, under: Keys.downloads) }
    }

    /// Whether the download queue is being held rather than worked through.
    var isDownloadQueuePaused: Bool {
        didSet { defaults.set(isDownloadQueuePaused, forKey: Keys.queuePaused) }
    }

    /// Nonisolated because `WatchAudioChoice` reads it while decoding, and
    /// that is a plain value type with no actor of its own.
    nonisolated static let bitRates = [64, 96, 128, 160, 192, 256]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.startPage = StartPage(rawValue: defaults.string(forKey: Keys.startPage) ?? "")
            ?? .library
        // Whatever the one setting said becomes what both say, so a watch
        // that already had a preference keeps it rather than being handed
        // the defaults back on the day this split in two.
        let carriedOver = WatchAudioChoice.carriedOver(from: defaults)
        self.streaming = WatchAudioChoice(from: defaults, under: Keys.streaming) ?? carriedOver
        self.downloads = WatchAudioChoice(from: defaults, under: Keys.downloads) ?? carriedOver
        self.isDownloadQueuePaused = defaults.bool(forKey: Keys.queuePaused)
    }

    private enum Keys {
        static let startPage = "watch.startPage"
        static let streaming = "watch.audio.streaming"
        static let downloads = "watch.audio.downloads"
        static let queuePaused = "watch.downloads.paused"
    }
}

/// One answer to "what should the server send" — asked twice, once for
/// playing and once for keeping. See `WatchSettings.streaming`.
struct WatchAudioChoice: Hashable, Sendable {
    /// Whether the server is asked to convert at all. Off means the file as
    /// the server keeps it, except where the watch cannot decode it, which
    /// no setting can override.
    var converts: Bool
    var format: WatchAudioFormat
    /// What the server is asked to produce, in kbit/s.
    var kbps: Int

    /// Where both start, which is where the single setting they replaced started.
    static let standard = WatchAudioChoice(converts: true, format: .mp3, kbps: 128)

    fileprivate init(converts: Bool, format: WatchAudioFormat, kbps: Int) {
        self.converts = converts
        self.format = format
        self.kbps = kbps
    }

    /// Reads one back, or nil where nothing has been written yet.
    fileprivate init?(from defaults: UserDefaults, under key: String) {
        guard let stored = defaults.dictionary(forKey: key) else { return nil }
        converts = stored["converts"] as? Bool ?? true
        // A stored "aac" no longer names anything this can ask for, and
        // reads as MP3 — see `WatchAudioFormat`.
        format = WatchAudioFormat(rawValue: stored["format"] as? String ?? "") ?? .mp3
        let rate = stored["kbps"] as? Int ?? 0
        kbps = WatchSettings.bitRates.contains(rate) ? rate : 128
    }

    fileprivate func write(to defaults: UserDefaults, under key: String) {
        defaults.set(
            ["converts": converts, "format": format.rawValue, "kbps": kbps] as [String: Any],
            forKey: key
        )
    }

    /// What the single setting this replaced was saying, for a watch that
    /// already had one.
    fileprivate static func carriedOver(from defaults: UserDefaults) -> WatchAudioChoice {
        // `object(forKey:)` rather than `bool(forKey:)`: the latter cannot
        // tell "off" from "never set", and the default here is on.
        let converts = defaults.object(forKey: "watch.transcode") as? Bool ?? true
        let rate = defaults.integer(forKey: "watch.aacKbps")
        return WatchAudioChoice(
            converts: converts,
            format: WatchAudioFormat(rawValue: defaults.string(forKey: "watch.audioFormat") ?? "")
                ?? .mp3,
            kbps: WatchSettings.bitRates.contains(rate) ? rate : 128
        )
    }
}

/// What the server is asked to convert to.
enum WatchAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp3: "MP3"
        }
    }
}

/// The page the watch opens on.
enum StartPage: String, CaseIterable, Identifiable, Sendable {
    case library
    case downloads

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: "Library"
        case .downloads: "Downloads"
        }
    }
}
