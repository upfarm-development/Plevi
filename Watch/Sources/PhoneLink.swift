import Foundation
import Observation
import WatchConnectivity
import PleviDomain
import PleviKeychain
import PleviLibraryIndex
import PleviTransport

/// The watch's half of the link to the phone.
@MainActor
@Observable
final class PhoneLink: NSObject {
    /// What the phone has told us. Nil until the first context arrives.
    private(set) var provisioning: WatchLink.Provisioning?
    /// Bumped whenever a new library file has been put in place, so views
    /// watching it can reopen the index.
    private(set) var libraryGeneration = 0
    private(set) var isReachable = false

    /// Called when a snapshot has landed and been swapped in.
    var onLibraryArrived: (@MainActor (ServerID) -> Void)?
    /// Called before an arriving library replaces the one in use, so whoever
    /// has the current one open can let go of it first.
    var onLibraryWillInstall: (@MainActor (ServerID) -> Void)?
    /// Called when provisioning changes, so the model can rebuild a provider.
    var onProvisioningChanged: (@MainActor () -> Void)?
    /// Called when the phone says a server has been removed. The only thing
    /// that may delete a library's files; a changed storage id never does.
    var onServerRemoved: (@MainActor (WatchLink.ServerRemoved) -> Void)?

    private let secrets: any SecretStore
    private var session: WCSession?
    private let defaults: UserDefaults

    private static let provisioningKey = "watch.provisioning"

    init(secrets: any SecretStore = KeychainSecretStore(), defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
        super.init()
        // What the phone last said, from disk, before the session has so much as activated.
        if let data = defaults.data(forKey: Self.provisioningKey) {
            provisioning = try? JSONDecoder().decode(WatchLink.Provisioning.self, from: data)
        }
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    /// Asks the phone for a library this watch does not have.
    func requestLibraryIfMissing(storage: ServerID) {
        guard let session, session.activationState == .activated else { return }
        guard requestedLibraries.insert(storage.rawValue).inserted else { return }
        let request = WatchLink.NeedsLibrary(storageID: storage)
        guard let packed = WatchLink.packed(request, under: WatchLink.Key.needsLibrary) else { return }
        session.transferUserInfo(packed)
    }

    private var requestedLibraries: Set<UUID> = []

    /// Asks the phone to say everything again, when this watch has been told nothing.
    func requestProvisioningIfMissing() {
        guard provisioning == nil, !requestedProvisioning,
              let session, session.activationState == .activated
        else { return }
        requestedProvisioning = true
        guard let packed = WatchLink.packed(
            WatchLink.NeedsProvisioning(), under: WatchLink.Key.needsProvisioning
        ) else { return }
        session.transferUserInfo(packed)
    }

    private var requestedProvisioning = false

    /// Something put on here, for the phone's own Recently Played.
    func report(played source: PlayedSource, at date: Date) {
        guard let session, session.activationState == .activated else { return }
        let played = WatchLink.Played(source: source, playedAt: date)
        guard let packed = WatchLink.packed(played, under: WatchLink.Key.played) else { return }
        session.transferUserInfo(packed)
    }

    // MARK: Receiving

    /// Takes the decoded payload rather than the raw dictionary.
    private func apply(_ incoming: WatchLink.Provisioning) {
        // A phone on a newer build than this watch. Better to keep working
        // from what we already have than to half-read something we do not
        // understand.
        guard incoming.version <= WatchLink.version else { return }
        provisioning = incoming
        if let data = try? JSONEncoder().encode(incoming) {
            defaults.set(data, forKey: Self.provisioningKey)
        }
        onProvisioningChanged?()
    }

    private func store(_ received: WatchLink.Secrets) {
        let id = received.serverID
        // A server that has been signed out of on the phone arrives as an
        // empty payload rather than as silence, so the watch clears rather
        // than going on using a credential that has been revoked.
        guard !received.isEmpty else {
            try? secrets.removeSecrets(accountPrefix: ServerSecretKeys.prefix(id))
            onProvisioningChanged?()
            return
        }
        if let credentials = received.subsonicCredentials {
            try? secrets.setSecret(credentials, for: ServerSecretKeys.credentials(id))
        }
        if let token = received.plexToken {
            try? secrets.setSecretString(token, for: ServerSecretKeys.plexToken(id))
        }
        for (name, value) in received.headerValues {
            try? secrets.setSecretString(value, for: ServerSecretKeys.header(id, name: name))
        }
        if let session = received.proxySession {
            try? secrets.setSecret(session, for: ServerSecretKeys.proxySession(id))
        }
        onProvisioningChanged?()
    }

    /// Puts an arrived snapshot where the library is read from.
    private func install(_ file: URL, storage: ServerID) -> Bool {
        let destination = LibraryStorage.indexURL(for: storage)
        let manager = FileManager.default
        do {
            // Whatever this device knows that the snapshot does not: which
            // songs are on its own disk. Carried across before the swap, or
            // every arriving library would forget the downloads.
            var carried = carriedRows(from: destination, storage: storage)
            // A previous index that was there and could not be read is not a library with no
            // downloads.
            if case .unreadable = carried { carried = carriedRows(from: destination, storage: storage) }
            if case .unreadable = carried { WatchDownloads.holdNextSweep(for: storage) }

            let staging = destination.deletingLastPathComponent()
                .appending(path: "incoming-\(storage.rawValue.uuidString).sqlite")
            for suffix in ["", "-wal", "-shm"] {
                try? manager.removeItem(at: URL(fileURLWithPath: staging.path + suffix))
            }
            try manager.moveItem(at: file, to: staging)
            if case .rows(let rows) = carried { try restore(rows, into: staging, storage: storage) }

            // Nothing is destroyed until the arriving file has been opened and found to hold a
            // library.
            guard opens(staging, storage: storage) else {
                for suffix in ["", "-wal", "-shm"] {
                    try? manager.removeItem(at: URL(fileURLWithPath: staging.path + suffix))
                }
                return false
            }

            // Whoever is reading the file being replaced is told to let go first.
            onLibraryWillInstall?(storage)

            for suffix in ["", "-wal", "-shm"] {
                try? manager.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
            }
            // The write-ahead log travels with the database it belongs to: the carried rows may
            // live in it rather than in the file, and a database moved away from its log is a
            // database missing whatever the log had not folded in yet.
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: staging.path + suffix)
                if manager.fileExists(atPath: side.path) {
                    try? manager.moveItem(
                        at: side, to: URL(fileURLWithPath: destination.path + suffix)
                    )
                }
            }
            try manager.moveItem(at: staging, to: destination)
            return true
        } catch {
            try? manager.removeItem(at: file)
            return false
        }
    }

    /// What this device knows that an arriving library does not.
    struct CarriedRows {
        var downloads: [DownloadRecord] = []
        var playlists: [DownloadedPlaylistRecord] = []

        var isEmpty: Bool { downloads.isEmpty && playlists.isEmpty }
    }

    private func carriedRows(from existing: URL, storage: ServerID) -> CarriedRowsOutcome<CarriedRows> {
        guard FileManager.default.fileExists(atPath: existing.path) else { return .nothing }
        guard let index = try? LibraryIndex(databaseURL: existing, serverID: storage) else { return .unreadable }
        // Read with do/catch: `(try? ...) ?? []` made a failed read look like
        // a library with nothing downloaded, and the install swapped in a
        // database without the rows.
        do {
            let rows = CarriedRows(
                downloads: try index.downloads(),
                playlists: try index.downloadedPlaylists()
            )
            return rows.isEmpty ? .nothing : .rows(rows)
        } catch {
            return .unreadable
        }
    }

    /// Whether the arriving file is a library this build can read.
    private func opens(_ file: URL, storage: ServerID) -> Bool {
        guard let index = try? LibraryIndex(databaseURL: file, serverID: storage) else {
            return false
        }
        return ((try? index.stats().trackCount) ?? 0) > 0
    }

    private func restore(_ rows: CarriedRows, into file: URL, storage: ServerID) throws {
        let index = try LibraryIndex(databaseURL: file, serverID: storage)
        try index.saveDownloads(rows.downloads)
        for record in rows.playlists { try index.saveDownloadedPlaylist(record) }
    }
}

// MARK: - WCSessionDelegate

extension PhoneLink: WCSessionDelegate, @unchecked Sendable {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: (any Error)?
    ) {
        // The context that was already waiting when the app launched.
        // Without this the watch shows its waiting screen until the phone
        // happens to send something new.
        let waiting = WatchLink.unpacked(
            WatchLink.Provisioning.self,
            from: session.receivedApplicationContext,
            under: WatchLink.Key.provisioning
        )
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self, state == .activated else { return }
            isReachable = reachable
            if let waiting { apply(waiting) }
            requestProvisioningIfMissing()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let incoming = WatchLink.unpacked(
            WatchLink.Provisioning.self, from: context, under: WatchLink.Key.provisioning
        ) else { return }
        Task { @MainActor [weak self] in self?.apply(incoming) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let removed = WatchLink.unpacked(
            WatchLink.ServerRemoved.self, from: userInfo, under: WatchLink.Key.serverRemoved
        ) {
            Task { @MainActor [weak self] in self?.onServerRemoved?(removed) }
            return
        }
        guard let received = WatchLink.unpacked(
            WatchLink.Secrets.self, from: userInfo, under: WatchLink.Key.secrets
        ) else { return }
        Task { @MainActor [weak self] in self?.store(received) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is ours only until this method returns, so it is moved
        // out of the inbox on the spot rather than on a later hop.
        let url = file.fileURL
        let raw = file.metadata?[WatchLink.Key.storageID] as? String
        guard let raw, let uuid = UUID(uuidString: raw) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let storage = ServerID(rawValue: uuid)
        // Moved synchronously here; the main actor is only told afterwards.
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "arrived-\(uuid.uuidString).sqlite")
        try? FileManager.default.removeItem(at: staged)
        do { try FileManager.default.moveItem(at: url, to: staged) } catch { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if install(staged, storage: storage) {
                libraryGeneration += 1
                onLibraryArrived?(storage)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in self?.isReachable = reachable }
    }
}
