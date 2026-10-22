import Foundation
import PleviDomain
import UIKit

/// Where the settings snapshot is kept, and when it is written.
@MainActor
@Observable
final class SettingsBackupStore {
    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    @ObservationIgnored private var writing: Task<Void, Never>?
    /// Held outside the actor's isolation only so `deinit` can give them
    /// back: `deinit` is nonisolated, and these are written once in `init`
    /// and read once here.
    @ObservationIgnored private nonisolated(unsafe) var observer: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated(unsafe) var localChanges: (any NSObjectProtocol)?

    /// The library Home is arranged for, so the arrangement can be captured
    /// without the UUID it is filed under. Set by `AppModel` when one connects.
    var libraryScope: String?

    /// What names that library across installs (`LibraryFingerprint`), so its arrangement can be
    /// filed in the backup beside the other libraries' and found again on a new install.
    var libraryFingerprint: String?

    /// The last document this install put into iCloud, so a snapshot that
    /// somebody else wrote can be told from one of ours.
    @ObservationIgnored private var lastWritten: Data?

    /// What is in iCloud right now, for a screen to report.
    private(set) var stored: SettingsBackup.Description?

    /// Whether iCloud is actually going to keep this, last time it was asked.
    private(set) var isAvailable: Bool

    init(defaults: UserDefaults = .standard, store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
        self.isAvailable = false
        refresh()
        // A snapshot written by another device arrives whenever it arrives.
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Every setting in the app is written through `UserDefaults`, and there is no narrower seam
        // than that: `AppSettings` writes from dozens of property observers, and the Home
        // arrangement and the custom shelves are written by two other types…
        localChanges = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.record() }
        }
        store.synchronize()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let localChanges { NotificationCenter.default.removeObserver(localChanges) }
    }

    /// This device's own slot — a phone does not restore a tablet's Home.
    private let key = SettingsBackup.storeKey(for: .current)

    private func refresh() {
        isAvailable = store.synchronize()
        stored = store.data(forKey: key).flatMap(SettingsBackup.describe)
    }

    // MARK: Writing

    /// Records the settings as they are now.
    func record() {
        writing?.cancel()
        writing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    private func write() {
        let values = SettingsBackup.values(of: defaults, libraryScope: libraryScope)
        guard !values.isEmpty else { return }
        let existing = store.data(forKey: key)
        // An install whose restore has not run yet must not replace a snapshot it did not write
        // with the few settings it has so far: the first server added writes three Home keys, and
        // two seconds later the full backup that had just arrived from…
        let decision = BackupWriteDecision.decide(
            settled: SettingsBackup.hasSettled(defaults), stored: existing, lastWritten: lastWritten
        )
        guard decision != .skip else { return }
        // `UserDefaults.didChangeNotification` fires for every default in the app,
        // `plex.clientIdentifier` and a watch handshake stamp included — neither of which is in the
        // backup at all, so most firings of this method have nothing new to say.
        let libraries = SettingsBackup.libraries(
            of: defaults, libraryScope: libraryScope,
            libraryFingerprint: libraryFingerprint, stored: existing
        )
        if let existing,
           let already = SettingsBackup.storedValues(existing),
           (values as NSDictionary).isEqual(to: already),
           (libraries as NSDictionary).isEqual(to: SettingsBackupStore.libraries(in: existing)) {
            return
        }
        guard let data = SettingsBackup.snapshot(
            of: defaults,
            libraryScope: libraryScope,
            libraryFingerprint: libraryFingerprint,
            stored: existing,
            deviceName: UIDevice.current.name
        ) else { return }
        store.set(data, forKey: key)
        store.synchronize()
        lastWritten = data
        // Nothing was there, and this install has settings of its own now: a
        // snapshot that turns up later must not be restored over them.
        if decision == .writeAndSettle { SettingsBackup.settle(defaults) }
        refresh()
    }

    private static func libraries(in data: Data) -> [String: [String: Any]] {
        BackupDocument.storedLibraries(data) ?? [:]
    }

    // MARK: Reading

    /// Restores on an install that has nothing of its own, once.
    @discardableResult
    @MainActor
    static func restoreIfUntouched(
        into defaults: UserDefaults,
        from store: NSUbiquitousKeyValueStore = .default,
        kind: SettingsBackup.DeviceKind = .current
    ) -> Int {
        guard !SettingsBackup.hasSettled(defaults) else { return 0 }
        // Launched before the first unlock after a restart, the defaults read as empty, which looks
        // exactly like an install with nothing of its own.
        guard UIApplication.shared.isProtectedDataAvailable else { return 0 }
        guard SettingsBackup.looksUntouched(defaults) else {
            // Settings of its own, so there is nothing to decide again.
            SettingsBackup.settle(defaults)
            return 0
        }
        store.synchronize()
        guard let data = store.data(forKey: SettingsBackup.storeKey(for: kind)) else {
            // Nothing there yet. Deliberately *not* settled: a snapshot may
            // still be on its way down, and the next launch should look
            // again rather than deciding on an empty store for good.
            return 0
        }
        let landed = SettingsBackup.apply(data, to: defaults)
        SettingsBackup.settle(defaults)
        return landed
    }

    /// Restores by hand, whatever this install already holds.
    @discardableResult
    func restoreNow() -> Int {
        guard let data = store.data(forKey: key) else { return 0 }
        // Into the open library's own keys and over what is there: the launch-time path writes
        // unscoped keys for the first library to find, which only works for an install with no
        // library of its own yet.
        return SettingsBackup.apply(
            data, to: defaults,
            libraryScope: libraryScope, libraryFingerprint: libraryFingerprint
        )
    }
}
