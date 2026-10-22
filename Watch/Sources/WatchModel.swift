import Foundation
import Network
import Observation
import Synchronization
import WatchKit
import PleviDomain
import PleviKeychain
import PleviLibraryIndex
import PleviPlexProvider
import PleviSubsonicProvider
import PleviTransport

/// The watch app's composition root.
@MainActor
@Observable
final class WatchModel {
    static let shared = WatchModel()

    /// One background session per library, so a watch pointed at a different
    /// library does not inherit the other's transfers. The identifier is what
    /// the system hands back when it relaunches us to finish them.
    static let downloadSessionPrefix = AppIdentity.own + ".downloads."

    let settings = WatchSettings()
    let link: PhoneLink
    let player = WatchPlayer()
    let playLog = WatchPlayLog()
    let pendingPlays = WatchPendingPlays()

    /// The copy of the library the phone sent, once one has arrived.
    private(set) var library: WatchLibrary?
    /// Nil until a server has been reached. Browsing does not need it;
    /// playlists and artwork do.
    private(set) var provider: (any MusicServerProvider)?
    private(set) var artwork: WatchArtwork?
    /// Nil until there is both a library to file downloads against and a
    /// server to fetch them from.
    private(set) var downloads: WatchDownloads?
    private(set) var isConnecting = false
    /// Said out loud in Settings rather than swallowed.
    private(set) var connectionProblem: String?
    /// Which of the server's addresses the watch actually reached, for the one screen that can say
    /// so.
    private(set) var reachedAddress: EndpointSelector.Choice?

    private let secrets: any SecretStore
    /// The SSO session for a proxy in front of the server, read by every
    /// transport on every request — including the one that fetches audio.
    private let proxySessions = ProxySessionHolder()
    /// One selector per server, kept across connects rather than rebuilt for each one: on a watch
    /// the local-address probe is expensive enough that paying it every time would be felt.
    private struct SelectorKey: Hashable {
        var server: ServerID
        var addresses: ServerAddresses
        var pins: [PinnedCertificate]
    }
    private var selector: (key: SelectorKey, value: EndpointSelector)?
    /// What is needed to move the live provider to another address, and what
    /// it is on now. Replaced by every connect; read by `refreshEndpoint`.
    private struct EndpointHandle {
        var selector: EndpointSelector
        var current: URL
        var apply: @Sendable (URL) async -> Void
    }
    private var endpoint: EndpointHandle?
    private var endpointGate = EndpointRefreshGate()
    private var refreshingEndpoint = false
    private var refreshEndpointAgain = false
    /// Which run of `runConnect` the published provider belongs to, so a
    /// refresh that was overtaken by a newer connect drops its answer.
    private var connectGeneration = 0
    private var sweptStagedSnapshots = false
    private var pathMonitor: NWPathMonitor?
    private var pathDebounce: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    /// Asked for again while one is already under way, so it is not lost —
    /// only deferred until that one finishes. See `connect()`.
    private var reconnectRequested = false
    /// One reader per download session, started once and never cancelled.
    private var downloadReaders: [String: Task<Void, Never>] = [:]
    /// Which `WatchDownloads` a reader's identifier belongs to. Set once,
    /// when the object is built, and never moved — see `downloadReaders`.
    private var downloadsByIdentifier: [String: WatchDownloads] = [:]
    /// Events that arrived before there was anything to apply them to — the
    /// app relaunched in the background to finish a transfer, where the
    /// system replays what it finished before the library has been opened.
    private var pendingEvents: [String: [BackgroundDownloadEvent]] = [:]

    init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        self.link = PhoneLink(secrets: secrets)
    }

    /// What the app shows before anything else can be decided.
    enum Stage: Equatable {
        /// No server has ever been sent: the phone has not been opened, or
        /// has nothing set up.
        case waitingForPhone
        /// A server is known but its library has not arrived yet.
        case waitingForLibrary
        case ready
    }

    var stage: Stage {
        guard link.provisioning?.config != nil else { return .waitingForPhone }
        guard let library, !library.isEmpty else { return .waitingForLibrary }
        return .ready
    }

    var serverName: String? { link.provisioning?.config?.name }

    /// Changes whenever the library behind the app is replaced.
    var libraryVersion: String {
        "\(library?.storage.rawValue.uuidString ?? "none")-\(link.libraryGeneration)"
    }

    /// Set when something is deliberately put on, so the root can bring the
    /// playing screen forward. Cleared by whoever acts on it.
    var wantsNowPlaying = false

    private func startedPlaying() {
        // A tap that starts music should be felt as well as seen.
        WKInterfaceDevice.current().play(.start)
        wantsNowPlaying = true
    }

    /// Changes when the connection to the server becomes usable.
    var connectionKey: String { "\(provider != nil)-\(artwork != nil)" }

    /// Changes as songs arrive or leave, so a page showing what is on this
    /// watch refreshes when that answer moves. Neither the library version
    /// nor a record's id does.
    var downloadsKey: String {
        guard let downloads else { return "none" }
        return "\(downloads.doneCount)-\(downloads.activeCount)"
    }

    /// What a page that lists what is on this watch keys its reload on.
    func downloadsRefreshKey(_ downloadedOnly: Bool) -> String {
        downloadedOnly ? downloadsKey : ""
    }

    /// What has been put on lately, on either device.
    var recentlyPlayed: [PlayedEntry] {
        playLog.merged(with: link.provisioning?.playLog ?? [])
    }

    /// Waits out the transfers the system finished while the app was closed.
    func finishBackgroundTransfers(identifier: String) async {
        guard identifier.hasPrefix(Self.downloadSessionPrefix) else { return }
        boot()
        // The rest of the identifier is the library the session belongs to.
        let raw = String(identifier.dropFirst(Self.downloadSessionPrefix.count))
        guard UUID(uuidString: raw) != nil, let config = link.provisioning?.config else { return }
        let downloader = BackgroundDownloader.shared(
            identifier: identifier,
            pins: config.pinnedCertificates,
            allowedOrigins: config.allowedOrigins
        )
        // Read them before waiting for them.
        followDownloads(identifier: identifier, downloader: downloader)
        // Bounded, on the one platform that punishes an unbounded wait.
        await waitBriefly(seconds: 8) { await downloader.waitForSavedEvents() }
        // And then the queue moves on, which is the half that was missing.
        await waitBriefly(seconds: 4) { [weak self] in
            // `Task.isCancelled` first, and it is the whole reason this loop is safe.
            while !Task.isCancelled, await self?.downloads == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // Bounded like the rest of it. This asks the system what it is
        // carrying and can start transfers, neither of which is instant.
        await waitBriefly(seconds: 4) { [weak self] in
            await self?.downloads?.restartQueue()
        }
    }

    /// Runs something, but not for longer than it is worth.
    private func waitBriefly(
        seconds: Int, _ work: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Keeps whatever a hold was raised on.
    func download(_ actions: HoldActions) async {
        guard downloads != nil, let reason = actions.reason else { return }
        let tracks = await actions.tracks()
        // Read again after the wait rather than held across it: an arriving library replaces this
        // object, and the one bound before the round trip would go on writing into the database
        // file that has since been unlinked.
        guard let downloads else { return }
        // What a record or a playlist holds is asked of the server at the moment of asking, so it
        // can come back with nothing — the server unreachable, which on a watch is most of the time
        // it is not on Wi-Fi.
        guard !tracks.isEmpty else {
            downloadProblem = "\(actions.title) — no songs came back. Your server may be out of reach."
            return
        }
        let problem: String?
        if let playlist = actions.playlist {
            problem = await downloads.download(playlist: playlist, tracks: tracks)
        } else {
            problem = await downloads.download(tracks, reason: reason, named: actions.title)
        }
        if let problem { downloadProblem = problem }
    }

    /// A download that could not even begin, for the wearer rather than the
    /// log. Cleared by whoever shows it.
    private(set) var downloadProblem: String?

    func clearDownloadProblem() { downloadProblem = nil }

    func downloadedPlaylists() -> [Playlist] { library?.downloadedPlaylists() ?? [] }

    func tracks(inDownloadedPlaylist id: MediaID) -> [Track] {
        library?.tracks(inDownloadedPlaylist: id) ?? []
    }

    /// Every song a kept playlist lists, for removing it.
    func memberIDs(inDownloadedPlaylist id: MediaID) -> [MediaID] {
        library?.memberIDs(inDownloadedPlaylist: id) ?? []
    }

    func boot() {
        link.onProvisioningChanged = { [weak self] in self?.reload() }
        link.onLibraryWillInstall = { [weak self] _ in self?.releaseLibrary() }
        link.onLibraryArrived = { [weak self] _ in self?.reload(reopening: true) }
        link.onServerRemoved = { [weak self] removed in self?.serverRemoved(removed) }
        // Half-arrived snapshots from an install that was killed: tens of
        // megabytes that nothing refers to. At launch, when none can be
        // running.
        if !sweptStagedSnapshots {
            sweptStagedSnapshots = true
            let root = Self.storageRoot
            Task.detached(priority: .utility) { WatchLibraryFiles.sweepStagedSnapshots(in: root) }
        }
        player.settings = settings
        player.onServerTrouble = { [weak self] in self?.noteTrouble() }
        player.pendingPlays = pendingPlays
        // Something put on here belongs at the top of the shelf on the phone
        // too: Recently Played is one list across both devices.
        player.onSourcePlayed = { [weak self] source, date in
            // Kept here so the shelf on this watch is right immediately, and
            // sent to the phone so its own shelf is right too.
            self?.playLog.record(source, at: date)
            self?.link.report(played: source, at: date)
            // And the screen follows what was just put on.
            self?.startedPlaying()
        }
        link.start()
        reload()
        startWatchingTheNetwork()
    }

    /// Opens whatever library is on disk and, separately, reaches for the server.
    private func reload(reopening: Bool = false) {
        guard let storage = link.provisioning?.storageID else {
            stopPlaybackIfOrphaned(incoming: nil)
            releaseLibrary()
            provider = nil
            artwork = nil
            endpoint = nil
            player.source = nil
            return
        }
        // A queue of one library must not go on against another library's provider: the next song
        // would be asked for by an id the new server has never heard of (or, on Plex, cheerfully
        // misreports).
        stopPlaybackIfOrphaned(incoming: storage)
        if reopening || library?.storage != storage {
            releaseLibrary()
            library = WatchLibrary.opened(storage: storage)
        }
        // Kept songs play now, not after the address probe: see
        // `WatchLibrary.downloadedFile`.
        installDownloadedLookup()
        // What was pinned or played belongs to the library it happened in.
        playLog.use(library: storage)
        pendingPlays.use(library: storage)
        // Nothing on disk for this library, so ask for it. The phone cannot
        // know what this watch is missing; only this watch can.
        if library == nil || library?.isEmpty == true {
            link.requestLibraryIfMissing(storage: storage)
        }
        connect()
    }

    /// Points the player at the files on this watch, straight from the library that was just
    /// opened.
    private func installDownloadedLookup() {
        player.downloadedFile = library.map { library in
            { [weak library] id in library?.downloadedFile(for: id) }
        }
    }

    private func stopPlaybackIfOrphaned(incoming: ServerID?) {
        guard ServerSwitching.playbackMustStop(queueServer: player.queueServer, incoming: incoming)
        else { return }
        player.stop()
    }

    // MARK: Libraries the phone no longer has

    /// Where every library's files live, for the enumeration below.
    private static var storageRoot: URL {
        LibraryStorage.indexURL(for: ServerID()).deletingLastPathComponent()
    }

    /// Bytes held for libraries other than the one in use: the ones the phone
    /// switched away from, which are kept on purpose (switching back must not
    /// cost a re-download) and so need somewhere to be seen and removed.
    private(set) var otherLibraryBytes: Int64 = 0

    func measureOtherLibraries() async {
        let active = library?.storage ?? link.provisioning?.storageID
        let root = Self.storageRoot
        otherLibraryBytes = await Task.detached(priority: .utility) {
            WatchLibraryFiles.held(in: root)
                .filter { $0.key != active }
                .reduce(Int64(0)) { $0 + $1.value }
        }.value
    }

    /// Deletes every library this watch holds except the one in use. Asked
    /// for by the wearer, from Settings.
    func removeOtherLibraries() async {
        let active = library?.storage ?? link.provisioning?.storageID
        let root = Self.storageRoot
        let others = await Task.detached(priority: .utility) {
            Set(WatchLibraryFiles.held(in: root).keys).subtracting(active.map { [$0] } ?? [])
        }.value
        purge(others)
        otherLibraryBytes = 0
    }

    /// The phone removed a server.
    private func serverRemoved(_ removed: WatchLink.ServerRemoved) {
        var doomed = Set(removed.storageIDs)
        // The server the watch is provisioned for, in case the phone did not
        // know every library it had filed (an older phone build).
        if link.provisioning?.config?.id == removed.serverID,
           let storage = link.provisioning?.storageID {
            doomed.insert(storage)
        }
        purge(doomed)
    }

    /// Stands down everything holding a library, then deletes its files.
    private func purge(_ doomed: Set<ServerID>) {
        guard !doomed.isEmpty else { return }
        if let queued = player.queueServer, doomed.contains(queued) { player.stop() }
        if let active = library?.storage, doomed.contains(active) { releaseLibrary() }
        let config = link.provisioning?.config
        for id in doomed {
            let identifier = Self.downloadSessionPrefix + id.rawValue.uuidString
            // Transfers first: one the system is still carrying recreates the
            // directory and moves its song into it when it lands.
            BackgroundDownloader.shared(
                identifier: identifier,
                pins: config.map { LibraryStorage.id(for: $0) == id ? $0.pinnedCertificates : [] } ?? [],
                allowedOrigins: config.map { LibraryStorage.id(for: $0) == id ? $0.allowedOrigins : [] } ?? []
            ).cancelAll()
            downloadsByIdentifier[identifier] = nil
            pendingEvents[identifier] = nil
            playLog.forget(library: id)
            pendingPlays.forget(library: id)
        }
        let root = Self.storageRoot
        Task.detached(priority: .utility) {
            for id in doomed { WatchLibraryFiles.remove(id, in: root) }
            // Cancelling is asked of the system, not done to it: a transfer
            // can land in the moment before the cancel does.
            try? await Task.sleep(for: .seconds(3))
            for id in doomed { WatchLibraryFiles.remove(id, in: root) }
        }
    }

    /// Reads one download session's events for as long as the app runs.
    private func followDownloads(identifier: String, downloader: BackgroundDownloader) {
        guard downloadReaders[identifier] == nil else { return }
        downloadReaders[identifier] = Task { [weak self] in
            for await event in downloader.attach() {
                guard let self else { return }
                if let downloads = downloadsByIdentifier[identifier] { downloads.apply(event) }
                // Nothing to apply it to yet — the app woken in the background to finish a transfer
                // gets here before it has a library open, or this identifier's own `WatchDownloads`
                // has not been built yet.
                else { pendingEvents[identifier, default: []].append(event) }
            }
        }
    }

    /// Lets go of the library file and everything holding it open.
    private func releaseLibrary() {
        // Told to stand down, not merely let go of: a drain suspended on the
        // server holds this object alive well past the last reference to it.
        // See `WatchDownloads.discard`.
        downloads?.discard()
        downloads = nil
        player.downloadedFile = nil
        library = nil
    }

    /// Reaches for the server: picks an address, builds a provider, tries a real request, and
    /// records what happened.
    private func connect() {
        guard connectTask == nil else {
            reconnectRequested = true
            return
        }
        guard link.provisioning?.config != nil else { return }
        isConnecting = true
        connectTask = Task { [weak self] in
            await self?.runConnect()
        }
    }

    private func runConnect() async {
        defer {
            connectTask = nil
            isConnecting = false
            // Whatever arrived while this was busy gets its own turn now, reading the provisioning
            // this run already finished with rather than whatever prompted it — which may itself be
            // stale by now, and connect() reads fresh regardless.
            if reconnectRequested {
                reconnectRequested = false
                connect()
            }
        }
        guard let config = link.provisioning?.config else { return }
        let made = await buildProvider(for: config)
        let built = made?.provider
        guard !Task.isCancelled else { return }
        // The phone can have said something else while the address was being chosen, which on a
        // watch is ten seconds.
        guard link.provisioning?.config?.id == config.id else { return }
        connectGeneration += 1
        provider = built
        endpoint = made.map {
            EndpointHandle(selector: $0.selector, current: $0.url, apply: $0.apply)
        }
        artwork = built.map {
            WatchArtwork(
                provider: $0,
                // With the proxy sign-in, like every other transport here: a server behind an
                // authenticating proxy answers a request without it with the proxy's login page, so
                // artwork simply never arrived.
                transport: ServerHTTPTransport(config: config, proxySessions: proxySessions),
                storage: LibraryStorage.id(for: config)
            )
        }
        player.source = built.map {
            WatchAudioSource(
                config: config,
                provider: $0,
                // Its own transport, with a deadline that fits a song: the default bounds a whole
                // transfer at thirty seconds, which a converted track over the phone's relay cannot
                // meet, so every such song failed with bytes still arriving.
                transport: ServerHTTPTransport(
                    config: config, resourceTimeout: 3600, proxySessions: proxySessions
                ),
                proxySessions: proxySessions
            )
        }
        // One reader of the download event stream at a time.
        self.downloads?.discard()
        self.downloads = nil
        installDownloadedLookup()
        if let built, let library {
            let identifier = Self.downloadSessionPrefix
                + library.storage.rawValue.uuidString
            let downloader = BackgroundDownloader.shared(
                identifier: identifier,
                pins: config.pinnedCertificates,
                allowedOrigins: config.allowedOrigins
            )
            let downloads = WatchDownloads(
                index: library.index,
                storage: library.storage,
                config: config,
                provider: built,
                downloader: downloader,
                settings: settings,
                proxySessions: proxySessions
            )
            self.downloads = downloads
            downloads.onTrouble = { [weak self] in self?.noteTrouble() }
            downloadsByIdentifier[identifier] = downloads
            followDownloads(identifier: identifier, downloader: downloader)
            // A song kept here costs nothing to reach and plays with the
            // server gone, so it always wins over a stream.
            player.downloadedFile = { [weak downloads] id in downloads?.fileURL(for: id) }
            // What the table says, checked against what is actually on
            // the disk. Deliberately after the reader is attached, so a
            // transfer that lands mid-check is not missed.
            await downloads.reconcile()
            // Replayed *after* settling, not before.
            for event in pendingEvents.removeValue(forKey: identifier) ?? [] {
                downloads.apply(event)
            }
        }
        guard let built else {
            connectionProblem = "No sign-in for this server yet."
            player.sourceUnavailableReason = "No sign-in for this server yet."
            return
        }
        player.sourceUnavailableReason = nil
        do {
            _ = try await built.testConnection()
            connectionProblem = nil
            // The server is there: tell it what was played without it.
            await drainPendingPlays()
        } catch {
            connectionProblem = (error as? ProviderError)?.errorDescription
                ?? error.localizedDescription
            // A server that does not answer may be answering at the wrong
            // address — see `noteTrouble`.
            noteTrouble()
        }
        // After the connection was tried, so it reports the address that
        // was actually used rather than the one about to be.
        reachedAddress = await selector?.value.lastChoice
    }

    // MARK: Plays counted without the server

    private var isDrainingPlays = false

    /// Reports the plays queued while the server could not be reached, with
    /// the time they happened. One drain at a time.
    private func drainPendingPlays() async {
        guard let provider, !pendingPlays.isEmpty, !isDrainingPlays else { return }
        isDrainingPlays = true
        defer { isDrainingPlays = false }
        await pendingPlays.drain(using: provider)
    }

    // MARK: Keeping the server address right

    /// Starts listening for the network changing shape under a running app.
    private func startWatchingTheNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let signature = Mutex<String?>(nil)
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other]
                .filter { path.usesInterfaceType($0) }
                .map { String(describing: $0) }
                .joined(separator: ",")
            let now = "\(path.status == .satisfied)|\(interfaces)"
            // The first update is the state the app started in, not a change.
            let changed = signature.withLock { held -> Bool in
                defer { held = now }
                guard let held else { return false }
                return held != now
            }
            guard changed, path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.pathChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "\(AppIdentity.phone).watch.path"))
    }

    /// Debounced by a second: a wrist moving from Wi-Fi to the phone's relay
    /// is briefly several things on the way.
    private func pathChanged() {
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.requestEndpointRefresh(.pathChange)
        }
    }

    /// The app came forward.
    func appBecameActive() {
        // Transfers could not report while the app was asleep; their silence
        // starts counting now.
        downloads?.noteForeground()
        requestEndpointRefresh(.foreground)
    }

    /// Something that an unreachable address explains went wrong: a stream that would not start, a
    /// preparation or a transfer that timed out.
    func noteTrouble() {
        requestEndpointRefresh(.failure)
    }

    /// Asks for `refreshEndpoint()` without running two at once.
    private func requestEndpointRefresh(_ trigger: EndpointRefreshGate.Trigger) {
        guard endpoint != nil, provider != nil else { return }
        guard endpointGate.admit(
            trigger,
            hasAlternativeAddress: link.provisioning?.config?.addresses.probeOrder != nil,
            now: Date()
        ) else { return }
        guard !refreshingEndpoint else {
            refreshEndpointAgain = true
            return
        }
        refreshingEndpoint = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshEndpointAgain = false
                await refreshEndpoint()
            } while refreshEndpointAgain
            refreshingEndpoint = false
        }
    }

    /// Chooses the address again and moves the existing provider to it.
    private func refreshEndpoint() async {
        guard let handle = endpoint else { return }
        let generation = connectGeneration
        await handle.selector.invalidate()
        let url = await handle.selector.activeBaseURL()
        // A newer connect replaced the provider while the probe was out.
        guard generation == connectGeneration else { return }
        reachedAddress = await handle.selector.lastChoice
        guard url != handle.current else { return }
        await handle.apply(url)
        guard generation == connectGeneration else { return }
        endpoint?.current = url
        // Whatever was waiting on the old address gets another go at the new
        // one: songs queued behind a transfer that timed out there.
        await downloads?.restartQueue()
        guard let provider else { return }
        do {
            _ = try await provider.testConnection()
            guard generation == connectGeneration else { return }
            connectionProblem = nil
            await drainPendingPlays()
        } catch {
            guard generation == connectGeneration else { return }
            connectionProblem = (error as? ProviderError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// The watch's copy of `AppModel.buildProvider`, and it has to stay a copy: the phone's version
    /// reaches into `ServersStore`, which is an iOS-only object holding configs this device never
    /// has.
    private struct BuiltProvider {
        var provider: any MusicServerProvider
        var selector: EndpointSelector
        var url: URL
        var apply: @Sendable (URL) async -> Void
    }

    private func buildProvider(for config: ServerConfig) async -> BuiltProvider? {
        // A proxy sign-in captured on the phone and sent across, if this
        // server sits behind one.
        proxySessions.set(
            (try? secrets.secret(for: ServerSecretKeys.proxySession(config.id)))
                .flatMap { try? JSONDecoder().decode(ProxySession.self, from: $0) }
        )
        let transport = ServerHTTPTransport(config: config, proxySessions: proxySessions)
        let key = SelectorKey(
            server: config.id,
            addresses: config.addresses,
            pins: config.pinnedCertificates
        )
        if selector?.key != key {
            selector = (key, EndpointSelector(config: config))
        }
        let selector = self.selector?.value
        guard let selector else { return nil }

        switch config.kind {
        case .subsonic:
            guard let data = try? secrets.secret(for: ServerSecretKeys.credentials(config.id)),
                  let credentials = try? SubsonicCredentials.decode(data)
            else { return nil }
            var headers: [String: String] = [:]
            for name in config.customHeaderNames {
                if let value = try? secrets.secretString(for: ServerSecretKeys.header(config.id, name: name)) {
                    headers[name] = value
                }
            }
            let subsonic = SubsonicProvider(
                config: config,
                credentials: credentials,
                customHeaders: headers,
                transport: transport
            )
            let url = await selector.activeBaseURL()
            await subsonic.setBaseURL(url)
            return BuiltProvider(
                provider: subsonic, selector: selector, url: url,
                apply: { await subsonic.setBaseURL($0) }
            )

        case .plex:
            guard let token = try? secrets.secretString(for: ServerSecretKeys.plexToken(config.id)),
                  let library = config.library
            else { return nil }
            let plex = PlexProvider(
                serverID: LibraryStorage.id(for: config),
                config: PlexServerConfig(
                    baseURL: config.addresses.preferred,
                    token: token,
                    sectionKey: library.key,
                    sectionTitle: library.title,
                    machineIdentifier: library.machineIdentifier
                ),
                identity: identity,
                transport: transport
            )
            let url = await selector.activeBaseURL()
            plex.setBaseURL(url)
            return BuiltProvider(
                provider: plex, selector: selector, url: url,
                apply: { plex.setBaseURL($0) }
            )
        }
    }

    /// Plex granted its token to the phone's client identifier, so the watch must present that one
    /// rather than mint its own — a different identifier is a different client, and the token does
    /// not travel with it.
    private var identity: PlexIdentity {
        PlexIdentity(
            clientIdentifier: link.provisioning?.plexClientIdentifier ?? "",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            platform: "iOS",
            device: "Apple Watch",
            deviceName: "Plevi"
        )
    }
}
