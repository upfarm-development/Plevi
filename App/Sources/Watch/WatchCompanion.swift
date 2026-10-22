import Foundation
import Observation
import os
import WatchConnectivity
import PleviDomain
import PleviLibraryIndex
import PleviTransport

/// The phone's half of the link to the watch.
@MainActor
@Observable
final class WatchCompanion: NSObject {
    /// What the phone has managed to tell the watch, for Settings to show.
    private(set) var isReachable = false
    private(set) var isWatchAppInstalled = false
    private(set) var librarySentAt: Date?
    /// Which library that send was of. The hourly limit is per library: a
    /// phone switched to another one inside the hour has not sent *that* one.
    private(set) var librarySentStorage: ServerID?
    private(set) var isSendingLibrary = false
    /// The last thing that went wrong, shown in Settings rather than logged
    /// into a void.
    private(set) var lastFailure: String?

    /// Set by `AppModel` so this can ask for what it needs at the moment it
    /// needs it, rather than holding a second copy of everything.
    var provisioning: (@MainActor () -> WatchLink.Provisioning?)?
    var secrets: (@MainActor (ServerID) -> WatchLink.Secrets?)?
    var libraryIndex: (@MainActor () -> (index: LibraryIndex, storage: ServerID)?)?
    /// Something the watch played, for the phone's own shelf.
    var onPlayedOnWatch: (@MainActor (PlayedSource, Date) -> Void)?

    private var session: WCSession?
    /// The snapshot in flight, so a second request while one is running does
    /// not start a second vacuum over the same file.
    private var sendingLibrary: Task<Void, Never>?
    /// A send was asked for before there was a library open to send.
    private var wantsLibrary = false
    /// Which snapshot files are in flight, and what a transfer ending means.
    private var snapshots = WatchSnapshotLedger()

    /// Whether a send is owed — either one that was asked for too early, a
    /// watch that has never been given a library at all, or a watch that was
    /// last given a different library than the one the phone is on now.
    var owesLibrary: Bool {
        wantsLibrary || WatchLibrarySend.isOwed(
            storage: libraryIndex?()?.storage,
            lastSentStorage: librarySentStorage,
            lastSentAt: librarySentAt
        )
    }

    /// A snapshot is tens of megabytes.
    static let minimumInterval: TimeInterval = 60 * 60

    private static let sentAtKey = "watch.librarySentAt"
    private static let sentStampKey = "watch.librarySentStamp"
    private static let sentStorageKey = "watch.librarySentStorage"

    private let defaults: UserDefaults

    /// Every send here is fire-and-forget and most of them are skipped for
    /// good reasons, which makes "nothing happened" the normal case and an
    /// impossible one to tell from a bug without saying so somewhere.
    private static let log = Logger(subsystem: AppIdentity.phone, category: "watch")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        librarySentAt = defaults.object(forKey: Self.sentAtKey) as? Date
        librarySentStorage = defaults.string(forKey: Self.sentStorageKey)
            .flatMap(UUID.init(uuidString:)).map(ServerID.init(rawValue:))
        super.init()
    }

    /// Starts the session, on a device that has a watch to talk to.
    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    // MARK: Sending

    /// Which server, which library, and what has been played lately.
    func sendProvisioning(reprovision: Bool = false) {
        guard let session, canSend(session), var provisioning = provisioning?() else { return }
        if reprovision { provisioning.nonce = UUID().uuidString }
        guard let packed = WatchLink.packed(provisioning, under: WatchLink.Key.provisioning) else { return }
        guard packed[WatchLink.Key.provisioning] as? Data
            != session.applicationContext[WatchLink.Key.provisioning] as? Data
        else { return }
        do {
            try session.updateApplicationContext(packed)
            lastFailure = nil
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    /// The sign-in, queued so it survives both apps being closed.
    func clearSecrets(for server: ServerID) {
        guard let session, canSend(session) else { return }
        let empty = WatchLink.Secrets(serverID: server)
        guard let packed = WatchLink.packed(empty, under: WatchLink.Key.secrets) else { return }
        session.transferUserInfo(packed)
    }

    /// Tells the watch a server is gone: its credentials, and — by name — the libraries it may
    /// delete.
    func forgetServer(_ server: ServerID, storage: Set<ServerID>) {
        clearSecrets(for: server)
        guard let session, canSend(session) else { return }
        let removed = WatchLink.ServerRemoved(
            serverID: server,
            storageIDs: storage.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        )
        guard let packed = WatchLink.packed(removed, under: WatchLink.Key.serverRemoved) else { return }
        session.transferUserInfo(packed)
        // The send memory goes with it: a library removed and added again
        // under the same storage id has not been sent to anybody.
        if let sent = librarySentStorage, storage.contains(sent) {
            librarySentStorage = nil
            defaults.removeObject(forKey: Self.sentStorageKey)
        }
    }

    func sendSecrets(for server: ServerID) {
        guard let session, canSend(session), let secrets = secrets?(server) else { return }
        guard let packed = WatchLink.packed(secrets, under: WatchLink.Key.secrets) else { return }
        session.transferUserInfo(packed)
    }

    /// Writes a snapshot of the library and sends it.
    func sendLibrary(force: Bool = false, stamp: String? = nil) {
        guard let session else {
            Self.log.info("library send skipped: no session")
            return
        }
        guard canSend(session) else {
            Self.log.info("""
                library send skipped: state \(session.activationState.rawValue), \
                paired \(session.isPaired), installed \(session.isWatchAppInstalled)
                """)
            return
        }
        guard sendingLibrary == nil else { return }
        if !force, let last = librarySentAt {
            // Per library. A global stamp kept a phone that had just been
            // switched to another library from sending it for up to an hour,
            // and the watch sat on "Getting your library" meanwhile.
            let withinTheHour = Date().timeIntervalSince(last) < Self.minimumInterval
            if let current = libraryIndex?()?.storage {
                if !WatchLibrarySend.mayAutoSend(
                    storage: current, lastSentStorage: librarySentStorage,
                    lastSentAt: last, now: Date(), minimumInterval: Self.minimumInterval
                ) { return }
            } else if withinTheHour {
                return
            }
        }
        // The session activates while `AppModel` is still being built, which is well before the
        // library file is open — so the first attempt of a launch usually arrives here with nothing
        // to send.
        guard let opened = libraryIndex?() else {
            Self.log.info("library send deferred: no index open yet")
            wantsLibrary = true
            return
        }
        wantsLibrary = false
        Self.log.info("library send starting")

        isSendingLibrary = true
        sendingLibrary = Task { [weak self] in
            defer {
                self?.isSendingLibrary = false
                self?.sendingLibrary = nil
            }
            // A file of its own for every snapshot. One path per library meant
            // a second send rewrote the file the first was still waiting to
            // deliver, and the first one's completion then deleted it.
            let destination = FileManager.default.temporaryDirectory
                .appending(path: WatchSnapshotLedger.fileName(for: opened.storage))
            let index = opened.index
            do {
                // Off the main thread: this vacuums the whole database twice
                // and takes about a second on a large library.
                let count = try await Task.detached(priority: .utility) {
                    try index.snapshot(to: destination)
                    return try index.stats().trackCount
                }.value
                guard let self, let session = self.session else { return }
                // An empty library is not worth a transfer, and stamping one as sent is worse than
                // not sending it: the watch shows the same waiting screen either way, while the
                // hour between sends starts running against a library that does not exist yet.
                guard count > 0 else {
                    Self.log.info("library send skipped: nothing in it yet")
                    self.wantsLibrary = true
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                // Tens of megabytes each: a watch out of reach for a day must not
                // come back to a pile of them. The ones this replaces are
                // cancelled, and their endings are ours to ignore.
                let replaced = self.snapshots.begin(
                    .init(file: destination.lastPathComponent, storage: opened.storage),
                    outstanding: session.outstandingFileTransfers.compactMap(Self.transfer(of:))
                )
                for old in replaced {
                    session.outstandingFileTransfers
                        .first { $0.file.fileURL.lastPathComponent == old.file }?
                        .cancel()
                }
                session.transferFile(destination, metadata: [
                    WatchLink.Key.storageID: opened.storage.rawValue.uuidString,
                    WatchLink.Key.generatedAt: Date().timeIntervalSince1970,
                    WatchLink.Key.trackCount: count,
                ])
                Self.log.info("library sent: \(count) tracks")
                self.note(sentAt: Date(), storage: opened.storage)
                if let stamp { self.noteLibrary(stamp: stamp) }
                self.lastFailure = nil
                // So the watch's Settings can say when the library it holds was made, without
                // waiting for the file itself to land.
                self.sendProvisioning(reprovision: force)
            } catch {
                Self.log.error("library send failed: \(error.localizedDescription)")
                self?.lastFailure = error.localizedDescription
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    /// How long a watch may go without a library before the background task sends one regardless of
    /// whether the phone thinks anything changed.
    static let staleAfter: TimeInterval = 20 * 60 * 60

    /// Sends the library if the watch has gone `staleAfter` without one (or is owed one), and
    /// answers once the snapshot has been handed to the system.
    @discardableResult
    func sendLibraryIfStale() async -> Bool {
        // The session was asked to activate when this object was made and
        // answers on its own queue. A phone woken in the background gets here
        // first, and a send before activation is refused.
        for _ in 0..<20 where session?.activationState != .activated {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return false }
        }
        guard let session, canSend(session) else {
            Self.log.info("background library send skipped: watch not reachable for sending")
            return false
        }
        let stale = librarySentAt.map { Date().timeIntervalSince($0) >= Self.staleAfter } ?? true
        guard stale || owesLibrary else { return false }
        sendLibrary()
        guard let sending = sendingLibrary else { return false }
        await sending.value
        return true
    }

    /// Whether a library send would actually do anything, so Settings can say
    /// so rather than offering a button that silently does nothing.
    var canSendLibrary: Bool {
        guard let session else { return false }
        return canSend(session)
    }

    /// What a queued transfer is, for the ledger: the file and the library it
    /// carries, read from the metadata it was queued with.
    private static func transfer(of transfer: WCSessionFileTransfer) -> WatchSnapshotLedger.Transfer? {
        guard let raw = transfer.file.metadata?[WatchLink.Key.storageID] as? String,
              let uuid = UUID(uuidString: raw)
        else { return nil }
        return .init(file: transfer.file.fileURL.lastPathComponent, storage: ServerID(rawValue: uuid))
    }

    /// Removes the snapshot files an earlier launch left in the temporary
    /// directory: the ones a transfer no longer refers to. Called once the
    /// session can say what is still queued.
    private func sweepStaleSnapshots(keeping queued: Set<String>) {
        let directory = FileManager.default.temporaryDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where WatchSnapshotLedger.isStale(fileName: url.lastPathComponent, queued: queued) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func canSend(_ session: WCSession) -> Bool {
        session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    private func forgetSentLibrary() {
        librarySentAt = nil
        librarySentStorage = nil
        defaults.removeObject(forKey: Self.sentAtKey)
        defaults.removeObject(forKey: Self.sentStorageKey)
        defaults.removeObject(forKey: Self.sentStampKey)
    }

    private func note(sentAt date: Date, storage: ServerID) {
        librarySentAt = date
        librarySentStorage = storage
        defaults.set(date, forKey: Self.sentAtKey)
        defaults.set(storage.rawValue.uuidString, forKey: Self.sentStorageKey)
    }

    /// Whether the library has changed since the last snapshot went out.
    func libraryChanged(stamp: String) -> Bool {
        defaults.string(forKey: Self.sentStampKey) != stamp
    }

    func noteLibrary(stamp: String) {
        defaults.set(stamp, forKey: Self.sentStampKey)
    }
}

// MARK: - WCSessionDelegate

// The delegate methods arrive on a background queue, which is why this is
// `@unchecked Sendable` and why every one of them hops to the main actor
// before touching anything. The same bargain `BackgroundDownloader` makes.
extension WatchCompanion: WCSessionDelegate, @unchecked Sendable {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: (any Error)?
    ) {
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        // Read here, on the delegate's queue: a session is not something to
        // carry across to the main actor.
        let queued = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        Task { @MainActor [weak self] in
            guard let self else { return }
            isWatchAppInstalled = installed
            isReachable = reachable
            guard state == .activated else { return }
            sweepStaleSnapshots(keeping: queued)
            // Everything the watch needs, at the first moment there is anywhere to send it.
            sendProvisioning(reprovision: true)
            if let server = provisioning?()?.config?.id { sendSecrets(for: server) }
            // A watch that has never been sent a library gets one now, without waiting for a sync
            // to change something.
            if librarySentAt == nil { sendLibrary(force: true) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The watch was switched. Reactivating is required before anything can
    /// be sent again, and the new watch knows nothing, so it is provisioned
    /// from scratch by the activation handler above.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let installed = session.isWatchAppInstalled
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wasInstalled = isWatchAppInstalled
            isWatchAppInstalled = installed
            // The app was just installed on the watch: provision it now
            // rather than at the next sync, which could be an hour away.
            if installed, !wasInstalled {
                sendProvisioning(reprovision: true)
                if let server = provisioning?()?.config?.id { sendSecrets(for: server) }
                sendLibrary(force: true)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in self?.isReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let played = WatchLink.unpacked(
            WatchLink.Played.self, from: userInfo, under: WatchLink.Key.played
        ) {
            Task { @MainActor [weak self] in
                self?.onPlayedOnWatch?(played.source, played.playedAt)
            }
        }
        // The watch has no copy of a library it has been told about.
        if WatchLink.unpacked(
            WatchLink.NeedsLibrary.self, from: userInfo, under: WatchLink.Key.needsLibrary
        ) != nil {
            Task { @MainActor [weak self] in self?.sendLibrary(force: true) }
        }
        // A watch that has been told nothing: say it all again, credentials
        // included.
        if WatchLink.unpacked(
            WatchLink.NeedsProvisioning.self, from: userInfo, under: WatchLink.Key.needsProvisioning
        ) != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                sendProvisioning(reprovision: true)
                if let server = provisioning?()?.config?.id { sendSecrets(for: server) }
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        // The snapshot was written to a temporary file for the transfer's
        // sake; it is the system's until now and ours to clean up after.
        let url = fileTransfer.file.fileURL
        let message = error?.localizedDescription
        let failed = error != nil
        Task { @MainActor [weak self] in
            // Its own file, by the URL the transfer reports. Never a path
            // shared with the next snapshot.
            try? FileManager.default.removeItem(at: url)
            guard let self else { return }
            switch snapshots.finish(file: url.lastPathComponent, failed: failed) {
            case .delivered, .superseded:
                break
            case .latestFailed:
                // The send did not happen after all.
                if let message { lastFailure = message }
                forgetSentLibrary()
            case .olderFailed:
                if let message { lastFailure = message }
            }
        }
    }
}
