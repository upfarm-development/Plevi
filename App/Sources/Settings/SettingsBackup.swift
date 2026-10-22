import Foundation
import PleviDomain
import UIKit

/// A copy of the settings worth carrying to a new install, kept in iCloud.
enum SettingsBackup {
    // MARK: What travels

    /// The settings a listener would be sorry to lose, named one at a time.
    static let carried: [String] = [
        // How it looks
        "app.theme", "pages.style", "pages.albumDisplay", "pages.playlistStyle",
        "pages.albumsPerRow", "pages.gridDensity", "tracks.rowStyle", "player.layout", "player.progressStyle",
        "player.progressLikeStars", "library.collectionGrids", "library.seeAllLayout",
        "library.quickSwitch", "tabs.playlists", "tabs.downloads",
        // What it shows
        "album.showsReview", "album.reviewPosition", "album.similarAlbums",
        "album.showsFormatBadge", "album.badgeLossyBitRate", "album.badgeLosslessDetail",
        "artist.sectionLayouts", "artist.sectionOrder", "artist.sectionsEnabled",
        "artist.combineSinglesEPs", "player.lyrics", "player.showsCodecInfo",
        "player.showsRemainingTime", "player.rollsTitle", "player.rollsArtist",
        "player.rollsAlbum", "search.resultOrder", "search.allQuickLibraries", "downloads.mergeLibraries",
        "player.queueRailExpandedLandscape", "player.queueRailExpandedPortrait",
        // Ratings
        "ratings.style", "ratings.visibility", "ratings.onlyWhenRated", "ratings.inQueue",
        // How it sounds
        "audio.equalizerPreset", "audio.equalizerGains", "audio.customEqualizerPresets",
        "audio.limiterEnabled", "audio.replayGainMode", "audio.replayGainPreamp",
        "audio.smartFades", "audio.maxOverlapSeconds", "audio.fadeEnvelope",
        "audio.keepAlbumsGapless", "audio.fadeThresholdDb", "audio.overlapTrimSeconds",
        "audio.matchSampleRates",
        // How it plays
        "player.smartContinuePlaying", "player.smartContinueByOrigin",
        "player.smartShuffleByDefault", "player.smartShuffle", "player.confirmsStopAndClear",
        "playlists.sorting", "playlists.trackSort", "radio.decades", "radio.genres",
        "dj.insertionCount",
        // What it fetches. Not the cache sizes — see `deviceState`.
        "audio.streamTranscode", "audio.streamTranscodeCellular", "audio.streamAwayWiFiAsMobile",
        "audio.downloadTranscode",
        "audio.prefetchWiFi", "audio.prefetchCellular", "audio.keepConvertedFiles",
        "downloads.sort", "downloads.overCellular", "downloads.refreshPlaylistsAtLaunch",
        "downloads.refreshDownloadedDetailsAtLaunch",
    ]

    /// Home's arrangement, which is kept per library under a key ending in the library's own UUID.
    static let perLibrary: [String] = [
        "home.sectionOrder", "home.sectionLayouts", "home.sectionsOff", "home.customSections",
        "home.playLog", "home.playLog.seeded",
    ]

    /// Names this installation to something outside it.
    static let identity: Set<String> = [
        "plex.clientIdentifier", "watch.librarySentAt", "watch.librarySentStamp",
    ]

    /// True of this device rather than of this listener.
    static let deviceState: Set<String> = [
        "downloads.offlineMode", "audio.cacheGigabytes", "artwork.cacheMegabytes",
        "app.iconName", "library.mappingVersion",
    ]

    /// Worked out from the library rather than chosen, and rebuilt on its own.
    static let derived: Set<String> = [
        "downloads.lastBatch", "search.recent",
    ]

    // MARK: The document


    /// One slot per kind of device, so an iPad and an iPhone keep separate backups and each
    /// restores from its own.
    enum DeviceKind: String {
        case phone, pad, other

        /// Main-actor because `UIDevice` is. Every caller is already there.
        @MainActor
        static var current: DeviceKind {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone: .phone
            case .pad: .pad
            default: .other
            }
        }
    }

    static func storeKey(for kind: DeviceKind) -> String {
        "\(AppIdentity.phone).settings.snapshot.\(kind.rawValue)"
    }

    /// Set once this install has decided whether to restore, so the decision
    /// is made exactly once and never again.
    private static let settledKey = "settings.backup.settled"

    /// The lists above, in the form the document code in `PleviDomain` takes.
    /// That code is where the round trip is tested; this file decides only
    /// what travels.
    static let keys = BackupDocument.Keys(
        carried: carried, perLibrary: perLibrary, playLog: "home.playLog"
    )

    /// The settings themselves, worth keeping apart from `snapshot`'s own wrapping: a document also
    /// carries a timestamp, which makes two otherwise-identical documents compare unequal every
    /// time one is built — and telling "nothing changed" from…
    static func values(of defaults: UserDefaults, libraryScope: String?) -> [String: Any] {
        BackupDocument.values(of: defaults, keys: keys, libraryScope: libraryScope)
    }

    /// Every library's arrangement that the stored document and the open
    /// library together hold, for the same comparison.
    static func libraries(
        of defaults: UserDefaults,
        libraryScope: String?,
        libraryFingerprint: String?,
        stored: Data?
    ) -> [String: [String: Any]] {
        BackupDocument.libraries(
            of: defaults, keys: keys, libraryScope: libraryScope,
            libraryFingerprint: libraryFingerprint, stored: stored
        )
    }

    /// The `values` a stored document was carrying, for comparing against a
    /// freshly built set without caring what timestamp or device name the
    /// old document happened to carry.
    static func storedValues(_ data: Data) -> [String: Any]? {
        BackupDocument.storedValues(data)
    }

    /// Everything worth keeping, as one document.
    static func snapshot(
        of defaults: UserDefaults,
        libraryScope: String?,
        libraryFingerprint: String?,
        stored: Data?,
        deviceName: String
    ) -> Data? {
        BackupDocument.snapshot(
            of: defaults, keys: keys, libraryScope: libraryScope,
            libraryFingerprint: libraryFingerprint, stored: stored, deviceName: deviceName
        )
    }

    /// What a snapshot says about itself, for a screen to report.
    struct Description: Equatable {
        let writtenAt: Date
        let deviceName: String
        let count: Int
    }

    static func describe(_ data: Data) -> Description? {
        guard let document = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
            let version = document["version"] as? Int, version <= BackupDocument.currentVersion,
            let writtenAt = document["writtenAt"] as? Date,
            let values = document["values"] as? [String: Any]
        else { return nil }
        return Description(
            writtenAt: writtenAt,
            deviceName: document["deviceName"] as? String ?? "another device",
            count: values.count
        )
    }

    /// Writes a snapshot into `defaults`, returning how many settings landed.
    /// See `BackupDocument.apply`.
    @discardableResult
    static func apply(
        _ data: Data,
        to defaults: UserDefaults,
        libraryScope: String? = nil,
        libraryFingerprint: String? = nil
    ) -> Int {
        BackupDocument.apply(
            data, to: defaults, keys: keys,
            libraryScope: libraryScope, libraryFingerprint: libraryFingerprint
        )
    }

    /// Hands a library the arrangement a restore set aside for it, as it is
    /// opened. See `BackupDocument.adoptPending`.
    static func adoptPending(into defaults: UserDefaults, scope: String, fingerprint: String?) {
        BackupDocument.adoptPending(into: defaults, keys: keys, scope: scope, fingerprint: fingerprint)
    }

    // MARK: Deciding

    /// Whether this install has already decided about a backup.
    static func hasSettled(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: settledKey)
    }

    static func settle(_ defaults: UserDefaults) {
        defaults.set(true, forKey: settledKey)
    }

    /// Whether this looks like an install with nothing of its own yet.
    ///
    /// Asked of the settings themselves rather than of a marker, because a
    /// marker is exactly what a fresh install does not have: if none of the
    /// carried keys is present, nobody has changed anything here.
    static func looksUntouched(_ defaults: UserDefaults) -> Bool {
        !carried.contains { defaults.object(forKey: $0) != nil }
    }
}
