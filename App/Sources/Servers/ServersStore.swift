import Foundation
import Observation
import OSLog
import UIKit
import PleviDomain
import PleviTransport
import PleviKeychain
import PleviSubsonicProvider
import PleviPlexProvider

/// Persists server configurations (no secrets) and brokers all Keychain
/// access. Config lives as JSON in Application Support; credentials and
/// custom-header values live only in the Keychain, keyed by server UUID.
@MainActor
@Observable
final class ServersStore {
    private(set) var servers: [ServerConfig] = []
    private(set) var activeServerID: ServerID?

    /// Whether `servers` is what the file says, rather than what an unreadable file left behind.
    private(set) var isLoaded = false

    /// Something worth telling the user about the file: entries that could not be read, or a save
    /// that did not land.
    @ObservationIgnored var notice: String? {
        didSet { if let notice { onNotice?(notice) } }
    }
    @ObservationIgnored var onNotice: (@MainActor (String) -> Void)?

    private static let log = Logger(subsystem: AppIdentity.phone, category: "servers")

    /// Called once a list that could not be read at launch has been.
    /// Whatever ran in between ran without it — see
    /// `AppModel.serversArrivedLate`.
    @ObservationIgnored var onLateLoad: (@MainActor () -> Void)?

    /// A server's sign-in changed — a fresh add counts too, `previous` is just `nil` — comparing
    /// the raw bytes each side of the Keychain, not the higher-level credential type: a Subsonic
    /// password and a Plex token both come through here…
    @ObservationIgnored var onSignInChanged: (@MainActor (_ id: ServerID, _ previous: Data?, _ new: Data) -> Void)?
    /// A server is about to be removed — its Keychain entries, including any
    /// Remote Control pins, are still there when this fires.
    @ObservationIgnored var willRemove: (@MainActor (_ id: ServerID) -> Void)?

    private let secrets: any SecretStore
    private let fileURL: URL
    @ObservationIgnored private var unlockObservers: [any NSObjectProtocol] = []

    init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Plevi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appending(path: "servers.json")
        load()
        if !isLoaded { readWhenUnlocked() }
    }

    var activeServer: ServerConfig? {
        servers.first { $0.id == activeServerID }
    }

    // MARK: Mutations

    /// Stores a server, replacing any with the same ID — which is how an edit
    /// is saved, so the active server, its index, and its Keychain entries all
    /// survive a change of password or address.
    func add(
        _ config: ServerConfig,
        credentials: SubsonicCredentials,
        headerValues: [String: String]
    ) throws {
        // Without this, a mutator that somehow ran before the list finished loading would still
        // write the Keychain half of a server below and then have `save()` silently drop the other
        // half — a secret with no server entry to match it.
        guard isLoaded else { return }
        // A header removed during an edit must take its Keychain entry with
        // it, rather than leaving a secret nothing refers to any more.
        if let existing = servers.first(where: { $0.id == config.id }) {
            for name in existing.customHeaderNames where headerValues[name] == nil {
                try? secrets.removeSecret(for: Self.headerKey(config.id, name: name))
            }
        }
        let previousCredentials = try? secrets.secret(for: Self.credentialsKey(config.id))
        let newCredentials = try credentials.encoded()
        try secrets.setSecret(newCredentials, for: Self.credentialsKey(config.id))
        for (name, value) in headerValues {
            try secrets.setSecretString(value, for: Self.headerKey(config.id, name: name))
        }
        activeServerID = ServerSwitching.activeServerAfterStoring(
            config.id,
            wasAlreadyListed: servers.contains { $0.id == config.id },
            currentlyActive: activeServerID
        )
        servers.removeAll { $0.id == config.id }
        servers.append(config)
        save()
        if previousCredentials != newCredentials {
            onSignInChanged?(config.id, previousCredentials, newCredentials)
        }
    }

    func setActive(_ id: ServerID) {
        guard isLoaded else { return }
        guard servers.contains(where: { $0.id == id }) else { return }
        activeServerID = id
        save()
    }

    func remove(_ id: ServerID) {
        guard isLoaded else { return }
        willRemove?(id)
        try? secrets.removeSecrets(accountPrefix: "\(id.rawValue.uuidString)/")
        servers.removeAll { $0.id == id }
        if activeServerID == id {
            activeServerID = servers.first?.id
        }
        save()
    }

    // MARK: Secret access

    func credentials(for id: ServerID) -> SubsonicCredentials? {
        guard let data = try? secrets.secret(for: Self.credentialsKey(id)) else { return nil }
        return try? SubsonicCredentials.decode(data)
    }

    func headerValues(for config: ServerConfig) -> [String: String] {
        var values: [String: String] = [:]
        for name in config.customHeaderNames {
            if let value = try? secrets.secretString(for: Self.headerKey(config.id, name: name)) {
                values[name] = value
            }
        }
        return values
    }

    // The four account builders moved to `ServerSecretKeys` in Shared when
    // the watch app needed to file the sign-in it is sent at the same
    // addresses this looks them up under.
    private static func credentialsKey(_ id: ServerID) -> SecretKey {
        ServerSecretKeys.credentials(id)
    }

    private static func headerKey(_ id: ServerID, name: String) -> SecretKey {
        ServerSecretKeys.header(id, name: name)
    }

    // MARK: Plex

    /// A Plex server's token, stored beside the Subsonic credentials rather
    /// than in the config file — it grants full access to the library, so it
    /// belongs in the Keychain like any password.
    func plexToken(for id: ServerID) -> String? {
        try? secrets.secretString(for: Self.plexTokenKey(id))
    }

    func addPlexServer(_ config: ServerConfig, token: String) throws {
        guard isLoaded else { return }
        let previousToken = try? secrets.secretString(for: Self.plexTokenKey(config.id))
        try secrets.setSecretString(token, for: Self.plexTokenKey(config.id))
        activeServerID = ServerSwitching.activeServerAfterStoring(
            config.id,
            wasAlreadyListed: servers.contains { $0.id == config.id },
            currentlyActive: activeServerID
        )
        servers.removeAll { $0.id == config.id }
        servers.append(config)
        save()
        if previousToken != token {
            onSignInChanged?(config.id, previousToken.map { Data($0.utf8) }, Data(token.utf8))
        }
    }

    /// Re-signs an existing Plex config in — **Sign In Again**, used
    /// both by the backfill for a config saved before step 5 and by the Settings row for one whose
    /// token cannot read its Plex user.
    func setPlexSignIn(accountID: String?, token: String?, for id: ServerID) {
        guard isLoaded else { return }
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].accountID = accountID
        save()
        guard let token else { return }
        let previousToken = try? secrets.secretString(for: Self.plexTokenKey(id))
        try? secrets.setSecretString(token, for: Self.plexTokenKey(id))
        if previousToken != token {
            onSignInChanged?(id, previousToken.map { Data($0.utf8) }, Data(token.utf8))
        }
    }

    /// Replaces the address a server is reached at on its own network.
    func setLocalAddress(_ url: URL, for id: ServerID) {
        guard isLoaded else { return }
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].addresses = servers[index].addresses.replacingLocal(with: url)
        save()
    }

    /// The same server, reached from outside on another address.
    func setRemoteAddress(_ url: URL, for id: ServerID) {
        guard isLoaded else { return }
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].addresses = servers[index].addresses.replacingRemote(with: url)
        save()
    }

    /// Points an existing server at another of its libraries, and renames it to match.
    @discardableResult
    func setLibrary(_ selection: LibrarySelection, for id: ServerID) -> Bool {
        guard isLoaded else { return false }
        guard let index = servers.firstIndex(where: { $0.id == id }),
              servers[index].offers(selection)
        else { return false }
        let previous = servers[index].library?.title
        servers[index].library = selection
        servers[index].name = Self.renamed(servers[index].name, from: previous, to: selection.title)
        save()
        return true
    }

    /// Swaps the library's name on the end of a server's own, leaving a name
    /// the user typed themselves alone.
    private static func renamed(_ name: String, from previous: String?, to title: String) -> String {
        guard let previous, !previous.isEmpty, name.hasSuffix(" — \(previous)") else { return name }
        return String(name.dropLast(previous.count + 3)) + " — " + title
    }

    private static func plexTokenKey(_ id: ServerID) -> SecretKey {
        ServerSecretKeys.plexToken(id)
    }

    // MARK: Proxy sign-in sessions

    /// The SSO session captured from a proxy in front of a server. A cookie
    /// that grants access to the whole server belongs in the Keychain beside
    /// the password, not in the config file.
    func proxySession(for id: ServerID) -> ProxySession? {
        guard let data = try? secrets.secret(for: Self.proxySessionKey(id)) else { return nil }
        return try? JSONDecoder().decode(ProxySession.self, from: data)
    }

    func setProxySession(_ session: ProxySession?, for id: ServerID) {
        guard let session, let data = try? JSONEncoder().encode(session) else {
            try? secrets.removeSecret(for: Self.proxySessionKey(id))
            return
        }
        try? secrets.setSecret(data, for: Self.proxySessionKey(id))
    }

    private static func proxySessionKey(_ id: ServerID) -> SecretKey {
        ServerSecretKeys.proxySession(id)
    }

    // MARK: Persistence

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Only the contents are locked away; whether the file is there
            // can be asked at any time.
            isLoaded = !FileManager.default.fileExists(atPath: fileURL.path)
            return
        }
        isLoaded = true
        // A file that is there and cannot be read as a server list, or holds entries this build
        // cannot decode, is not "no servers".
        guard let contents = ServerListFile.decode(data) else {
            ServerListFile.keepCopy(of: fileURL)
            notice = String(localized: "The list of servers could not be read. A copy was kept, and you can add your servers again.")
            Self.log.error("servers.json could not be decoded; \(data.count) bytes kept as servers.json.bad")
            return
        }
        if contents.skipped > 0 {
            ServerListFile.keepCopy(of: fileURL)
            notice = String(localized: "\(contents.skipped) saved server(s) could not be read by this version of Plevi. A copy of the list was kept.")
            Self.log.error("servers.json: \(contents.skipped) entries could not be decoded")
        }
        // A Subsonic server has no libraries.
        servers = contents.servers.map { config in
            guard config.kind == .subsonic, config.library != nil else { return config }
            var repaired = config
            repaired.library = nil
            return repaired
        }
        activeServerID = contents.activeServerID ?? contents.servers.first?.id
        // Written with complete protection until build 428, which locks the file whenever the
        // device is — exactly when the background refresh runs.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    /// Tries the file again when the device is unlocked, and again whenever
    /// the app comes forward, in case the first was missed while suspended.
    private func readWhenUnlocked() {
        let names = [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.willEnterForegroundNotification,
        ]
        unlockObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryLoad() }
            }
        }
    }

    private func retryLoad() {
        guard !isLoaded else { return }
        load()
        guard isLoaded else { return }
        unlockObservers.forEach(NotificationCenter.default.removeObserver)
        unlockObservers = []
        onLateLoad?()
    }

    /// Server addresses and names, no secrets — those are in the Keychain,
    /// readable after the first unlock. The list is kept the same way, so
    /// a background wake on a locked device can see which server to ask.
    private func save() {
        guard isLoaded else { return }
        do {
            let data = try ServerListFile.encode(servers: servers, activeServerID: activeServerID)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A full disk used to lose the change without a word: the
            // server was on screen until the next launch and then was not.
            Self.log.error("servers.json could not be written: \(error.localizedDescription)")
            notice = String(localized: "Your servers could not be saved: \(error.localizedDescription)")
        }
    }
}
