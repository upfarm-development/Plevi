import Foundation
import UIKit
import CryptoKit
import Observation
import PleviAudio
import PleviDomain
import PleviTransport
import PleviSubsonicProvider
import PleviPlexProvider
import PleviLibraryIndex
import PleviRemote

/// Composition root. The only place in the app that knows the active backend
/// is Subsonic — everything downstream sees `any MusicServerProvider`.
@MainActor
@Observable
final class AppModel {
    enum ConnectionState {
        case idle
        case connecting
        case connected(ServerInfo)
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    enum SyncState {
        case idle
        case syncing(String)
        case synced(Date)
        case failed(String)
    }

    /// Whether the active library has anything in it yet.
    private(set) var libraryIsEmpty: Bool?

    /// What the running sync has counted so far, kept per stage so a stage
    /// that has finished can still say how much it did. Held here rather than
    /// in the screen: the screen comes and goes, the sync does not.
    private(set) var syncedAlbums: Int?
    private(set) var syncedTracks: Int?

    /// Which stage the running sync is on, kept beside the sentence in
    /// `syncState` so a screen can follow the stages themselves rather than
    /// reading the sentence back apart.
    private(set) var syncPhase: LibrarySyncEngine.Phase?

    let servers = ServersStore()
    /// The link to the watch app, if this phone has one. Inert otherwise.
    let watch = WatchCompanion()
    let settings = AppSettings()
    /// Keeps a copy of the settings in iCloud, for the install after this
    /// one. Inert without the iCloud capability — see `SettingsBackupStore`.
    let settingsBackup = SettingsBackupStore()
    /// What has been kept on the Home screen on purpose.
    let pins = PinBoard()
    /// What has been put on lately — records and playlists, not everything
    /// heard. See `PlayLog`.
    let playLog = PlayLog()
    /// Playlists held at the top of the playlists list.
    let playlistTopPins = TopPinnedPlaylists()
    /// Home shelves built from filters of the listener's own.
    let customSections = CustomSections()

    /// Keeps a custom shelf, and puts it on Home if it is not there yet.
    func saveCustomSection(_ section: CustomHomeSection) {
        let isNew = customSections.section(id: section.id) == nil
        customSections.save(section)
        guard isNew, !settings.homeSectionOrder.contains(.custom(section.id)) else { return }
        // New shelves arrive at the top, where they can be seen. Anything
        // that is not wanted there can be dragged down.
        settings.homeSectionOrder.insert(.custom(section.id), at: 0)
    }

    /// Gives a place on Home to any kept shelf that has not got one.
    private func placeOrphanedCustomSections() {
        let placed = Set(settings.homeSectionOrder.compactMap(\.customID))
        let orphans = customSections.sections.map(\.id).filter { !placed.contains($0) }
        guard !orphans.isEmpty else { return }
        settings.homeSectionOrder.insert(contentsOf: orphans.map { HomeSection.custom($0) }, at: 0)
    }
    /// Whether the connection costs money by the megabyte, for whatever in the app needs to ask.
    private let network = NetworkPathMonitor()
    // The engine is chosen once, at launch: swapping mid-session would drop whatever is playing, so
    // the setting takes effect next time the app starts and Settings says so.
    let player: PlayerModel
    /// What Now Playing, and every play/queue site, actually controls.
    var activePlayer: any PlaybackControlling {
        if remote.controlledPlayer == nil, let reconnecting = remote.reconnectingPlayer { return reconnecting }
        return player(for: playbackDestination) ?? player
    }
    /// Remote Control's identity, transport and (for now, Debug-only) live sessions.
    let remote: RemoteControl
    /// Last non-fatal failure, surfaced as a transient banner.
    private(set) var transientError: String?
    /// How many times playback has failed to start or carry on, and what the latest said.
    private(set) var playbackProblemCount = 0
    private(set) var lastPlaybackProblem: String?
    /// Songs awaiting a playlist choice. Held here so a context menu in any
    /// view can raise the picker, which only the root can present.
    var pendingPlaylistAddition: PlaylistAddition?

    /// Songs on their way into a playlist, and what a new one made for them should be called.
    struct PlaylistAddition: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let suggestedName: String?
    }
    /// A record or artist waiting to be filed into a collection. Raised from
    /// a menu anywhere; only the root can present the sheet.
    var pendingCollectionAddition: CollectionAddition?
    /// A destination requested from a sheet. The player is presented as a
    /// sheet, so it cannot push anything itself: it asks the root to dismiss
    /// it and navigate the tab underneath.
    var pendingNavigation: NavigationRequest?

    enum NavigationRequest: Hashable {
        /// The name comes along where the caller already has it, so a destination can always be
        /// built.
        case album(MediaID, name: String? = nil)
        /// Same reasoning, same fallback; see `album` above.
        case artist(MediaID, name: String? = nil)
    }

    /// Warms artist pages ahead of use; see `ArtistPrefetcher`. Not observed:
    /// nothing in the UI reads it as state.
    @ObservationIgnored private(set) lazy var artistPrefetcher = ArtistPrefetcher(app: self)

    /// The first page of each playlist opened or about to be, kept so the page
    /// opens full and the server's answer corrects it a moment later.
    @ObservationIgnored let playlistPageStore = FilePlaylistPageStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PlaylistPages", directoryHint: .isDirectory)
    )
    @ObservationIgnored private var warmingPlaylists: Set<MediaID> = []

    /// Fetches a playlist's first page ahead of the tap, unless one saved in
    /// the last ten minutes is already there. At most two at a time, so a list
    /// scrolling past asks for a handful rather than all of them.
    func warmPlaylist(_ playlist: Playlist) async {
        guard !isOffline, let provider, warmingPlaylists.count < 2,
              !warmingPlaylists.contains(playlist.id) else { return }
        if await playlistPageStore.hasPage(for: playlist.id, newerThan: 600) { return }
        warmingPlaylists.insert(playlist.id)
        defer { warmingPlaylists.remove(playlist.id) }
        guard let page = try? await provider.playlistPage(
            id: playlist.id, offset: 0, limit: PlaylistLoader.pageSize
        ) else { return }
        await playlistPageStore.save(page, for: playlist.id)
    }

    /// What the Artist & Album Mixer has been asked to draw from. Held here
    /// rather than in the screen, so a selection survives leaving it and
    /// coming back — see `ArtistAlbumMixerStore`.
    let artistAlbumMixer = ArtistAlbumMixerStore()

    /// The one model, reachable from any scene.
    static let shared = AppModel()

    /// Connecting, once, whoever gets here first.
    private var bootTask: Task<Void, Never>?

    func bootIfNeeded() async {
        if let bootTask {
            await bootTask.value
            return
        }
        let task = Task<Void, Never> { await connectActive() }
        bootTask = task
        await task.value
    }

    init() {
        // The only engine now.
        player = PlayerModel(engine: StreamingAudioEngine(), network: network)
        remote = RemoteControl(servers: servers, settings: settings, player: player)
        // `RemoteControl.init` has already checked the install marker, before
        // it published anything to the iCloud device list.
        guessLibraryEmptiness()
        player.isAwayFromHome = { [weak self] in self?.isAwayFromHome ?? false }
        player.onPlaybackProblem = { [weak self] message in
            self?.lastPlaybackProblem = message
            self?.playbackProblemCount += 1
            self?.showTransientError(message, context: TranscodeLog.recentLines())
        }
        player.onStaleLibrary = { [weak self] in
            guard let self else { return }
            self.showTransientError(
                String(localized: "This library has changed on the server. Re-reading it now — try again in a moment.")
            )
            self.startBackgroundSync(force: true)
        }
        // local playback starting ends
        // control. The target keeps playing (disconnecting never stops
        // it) — only this device's own destination changes.
        player.onLocalPlaybackStarted = { [weak self] in
            // Also while a connection is still being made: two devices audible together is what D1
            // rules out, and a connection that lands a moment after the person pressed play here
            // would be exactly that.
            guard let self else { return }
            // Whatever the connection state: a device that dropped a moment ago
            // must not be redialled the next time the app comes forward, which
            // would pause this playback to take control back (R-12).
            self.remote.forgetRedialTarget()
            guard self.remote.isControlling || self.remote.isConnecting else { return }
            self.remote.disconnect()
        }

        // The watch asks for what it needs at the moment it needs it, rather
        // than being handed copies to hold. Nothing here runs on a phone with
        // no watch app installed.
        watch.provisioning = { [weak self] in self?.watchProvisioning() }
        watch.secrets = { [weak self] id in self?.watchSecrets(for: id) }
        watch.libraryIndex = { [weak self] in
            guard let self, let index = libraryIndex, let config = servers.activeServer else { return nil }
            return (index, Self.storageID(for: config))
        }
        watch.onPlayedOnWatch = { [weak self] source, date in
            // Recently Played is one shelf across both devices: something put
            // on at the wrist belongs at the top of it on the phone too.
            self?.recordFromWatch(source, at: date)
        }
        watch.start()
        // The address a server was reached on is chosen once, when the
        // connection is built. Nothing chose it again when the network
        // changed underneath a running app — see `refreshEndpoint`.
        network.onPathChange { [weak self] satisfied in
            Task { @MainActor in self?.networkPathChanged(satisfied: satisfied) }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.requestEndpointRefresh() }
        }
        servers.onLateLoad = { [weak self] in self?.serversArrivedLate() }
        // A servers file that could not be fully read, or a save that failed:
        // said once, and kept in Recent problems.
        servers.onNotice = { [weak self] message in self?.showTransientError(message) }
        if let notice = servers.notice { showTransientError(notice) }
        remote.libraryIndexProvider = { [weak self] in self?.libraryIndex }
        // A controller's play or enqueue is held to this device's own offline rule,
        // not the controller's.
        remote.trackIsPlayable = { [weak self] track in
            guard let self, self.isOffline, let downloads = self.downloads else { return true }
            return downloads.isDownloaded(track.id)
        }
        remote.libraryDidChange = { [weak self] in self?.bumpLibraryVersion() }
        // §4.8.3: outcomes are notes, failures go through
        // `showTransientError` and so land in Recent problems.
        remote.onNote = { [weak self] message in self?.showNote(message) }
        remote.onFailure = { [weak self] message in self?.showTransientError(message) }
        backfillPlexAccountIDs()
        // The toggle starts the first advertisement, but a relaunch with it already on needs to resume
        // listening itself — nothing else calls startListening() again.
        if settings.remoteAllowControl {
            let remote = remote
            Task { await remote.startListening() }
        }
    }

    /// Plex libraries added before step 5 have no `accountID` —
    /// the stored token is tried once at each launch, silently.
    private func backfillPlexAccountIDs() {
        // A round trip to plex.tv is not leaving the network alone. Run again
        // when Offline Mode goes off; it only ever fills in what is missing.
        guard !settings.offlineMode else { return }
        for config in servers.servers where config.kind == .plex && config.accountID == nil {
            guard let token = servers.plexToken(for: config.id) else { continue }
            RCDebugLog.shared.log("backfillPlexAccountIDs: trying \(config.name)")
            Task { [weak self] in
                let client = PlexClient(identity: PlexInstallation.identity)
                do {
                    let accountID = try await client.currentUser(token: token).uuid
                    self?.servers.setPlexSignIn(accountID: accountID, token: nil, for: config.id)
                    RCDebugLog.shared.log("backfillPlexAccountIDs: \(config.name) got accountID")
                } catch {
                    RCDebugLog.shared.log("backfillPlexAccountIDs: \(config.name) failed: \(error)")
                }
            }
        }
    }

    /// The server list could not be read when this process started — a background wake before the
    /// device's first unlock — and now has been.
    private func serversArrivedLate() {
        guard bootTask != nil else { return }
        Task { await connectActive() }
    }
    /// Plays the watch reported before the library was open. See the drain
    /// in `openLocalLibrary`.
    private var pendingWatchPlays: [(source: PlayedSource, date: Date)] = []

    private func recordFromWatch(_ source: PlayedSource, at date: Date) {
        guard playLog.isReady else {
            pendingWatchPlays.append((source, date))
            return
        }
        let library = source.mediaID.server
        if library == playLog.currentLibrary {
            playLog.recordReplayed(source, at: date)
        } else if servers.servers.contains(where: { knownStorageIDs(of: $0).contains(library) }) {
            // A library the watch was on and the phone has switched away
            // from. Dropped, these never appeared on the phone at all.
            PlayLog.recordReplayed(source, at: date, inLibrary: library)
        }
    }

    private(set) var provider: (any MusicServerProvider)?
    private(set) var artwork: ArtworkLoader?
    /// Whether the published loader has a server behind it yet.
    private(set) var artworkCanFetch = false

    /// How far artwork has got, as a token to key a `.task` on.
    var artworkStage: String {
        guard artwork != nil else { return "waiting" }
        return artworkCanFetch ? "ready" : "disk"
    }
    /// What has been kept for offline, and what is on its way.
    private(set) var downloads: DownloadManager?
    /// The live DJ agent — see `DJEngine` for why it shares `downloads`'
    /// lifetime rather than `player`'s.
    private(set) var dj: DJEngine?
    /// Ratings, hearts and plays made with no server to tell.
    private(set) var outbox: ChangeOutbox?
    private(set) var connection: ConnectionState = .idle {
        // Told to the player as it changes rather than read by it, because
        // the player deciding between a kept song and a stream has to know
        // whether the stream can arrive at all — see `serverUnreachable`.
        didSet {
            player.serverUnreachable = connection.isFailed
            // Every way the state changes passes here, so this is the one
            // place that has to know a failure wants asking again.
            updateReconnectLoop()
        }
    }
    /// Why the connection is failed, for the moments that need more than the
    /// sentence in `.failed`: what the banner says, and whether asking again
    /// can help. Meaningful only while `connection` is failed; set before it.
    private(set) var connectionFailure: ConnectionFailureKind = .other
    private(set) var libraryIndex: LibraryIndex?
    private(set) var syncState: SyncState = .idle
    /// Bumped when a sync lands so index-backed views re-read.
    private(set) var libraryVersion = 0 {
        // What another library's downloads were found to hold is remembered
        // only until the next change; see `foreignDownloadFile(for:)`.
        didSet { foreignFileCache.removeAll() }
    }
    /// Bumped only when a sync actually moved rows, unlike `libraryVersion`, which a star tap bumps
    /// too.
    private(set) var syncRevision = 0
    /// Ratings the user has just set, by song, until the next sync brings the server's own answer.
    private(set) var ratedLocally: [MediaID: StarRating?] = [:]

    /// The last songs list that was read, so opening it again is free.
    @ObservationIgnored let songList = SongListCache()
    @ObservationIgnored let albumList = AlbumListCache()
    @ObservationIgnored let artistList = ArtistListCache()

    /// The SSO session for a proxy in front of the active server, read by the
    /// transports on every request. Held rather than passed by value because
    /// it is captured long after the stack is built.
    private(set) var proxySessions = ProxySessionHolder()
    /// Thrown while offline by choice: every transport built for this server
    /// refuses requests, so no view can quietly go to the network behind the
    /// setting's back.
    private let suspension = NetworkSuspension()
    /// Cached media for the active server; also what Settings clears.
    private(set) var mediaStore: MediaFileStore?
    /// One store per library, kept for as long as the app runs.
    private var mediaStores: [ServerID: MediaFileStore] = [:]
    private let waveforms = WaveformSampler()
    /// Held so a manual sync can interrupt one that has stalled.
    private var syncTask: Task<Void, Never>?
    /// Which sync may still report progress.
    @ObservationIgnored private var syncGeneration = 0

    /// Peak levels for the waveform scrubber, or nil when the track is not on disk to read them
    /// from.
    private func backfillWaveforms() async {
        guard let provider, let libraryIndex, !settings.offlineMode else { return }
        // Off the main actor, both the asking and the writing.
        let wanted = await Task.detached(priority: .utility) {
            (try? libraryIndex.downloadedTracksWithoutWaveform()) ?? []
        }.value
        guard !wanted.isEmpty else { return }
        // Collected and written in batches rather than one transaction per
        // song: a sweep over a few hundred kept songs is a few hundred commits
        // otherwise, each with its own fsync, for shapes nobody is waiting on.
        var pending: [(MediaID, [Float])] = []
        func flush() async {
            guard !pending.isEmpty else { return }
            let batch = pending
            pending = []
            await Task.detached(priority: .utility) {
                for (id, bars) in batch {
                    try? libraryIndex.storeWaveform(bars, forTrack: id)
                }
            }.value
        }
        for id in wanted {
            if Task.isCancelled { await flush(); return }
            let fetched = try? await provider.loudnessEnvelope(
                for: id,
                bars: WaveformSampler.barCount
            )
            guard let bars = fetched ?? nil, !bars.isEmpty else { continue }
            pending.append((id, bars))
            if pending.count >= 25 { await flush() }
        }
        await flush()
    }

    /// The shape of the song that is playing, if it is already in hand.
    @ObservationIgnored private var readyShape: (id: MediaID, bars: [Float])?

    func readyWaveform(for track: Track?) -> [Float]? {
        guard let track, let readyShape, readyShape.id == track.id else { return nil }
        return readyShape.bars
    }

    /// Looks only in the index, never at a file or the server: it runs for
    /// every song that plays, whether or not the card is ever opened.
    func warmWaveform(for track: Track?) {
        guard let track, settings.progressStyle.needsWaveform else { return }
        if readyShape?.id == track.id { return }
        guard let stored = (try? libraryIndex?.waveform(forTrack: track.id)) ?? nil else { return }
        readyShape = (track.id, stored)
    }

    /// The waveform for a track, from the index if it has been worked out before, otherwise read
    /// from the cached audio and kept.
    func waveform(for track: Track?) async -> [Float]? {
        let bars = await workedOutWaveform(for: track)
        if let track, let bars { readyShape = (track.id, bars) }
        return bars
    }

    private func workedOutWaveform(for track: Track?) async -> [Float]? {
        guard let track else { return nil }
        if let stored = try? libraryIndex?.waveform(forTrack: track.id) ?? nil {
            return stored
        }

        // A song kept on the phone is read from the phone, before anything asks the server for
        // anything.
        if let file = downloads?.fileURL(for: track.id),
           // A decoded copy for Ogg Vorbis, which iOS cannot read; the file
           // itself for anything else.
           let bars = await waveforms.waveform(for: track.id, url: await DecodedAudioCache.shared.playable(file).url) {
            try? libraryIndex?.storeWaveform(bars, forTrack: track.id)
            return bars
        }

        guard let provider else { return nil }

        // The server may already know the shape — Plex does once a library
        // has been sonically analysed — and that answer costs a few kilobytes
        // instead of the whole track.
        if let fromServer = try? await provider.loudnessEnvelope(
            for: track.id,
            bars: WaveformSampler.barCount
        ) ?? nil, !fromServer.isEmpty {
            try? libraryIndex?.storeWaveform(fromServer, forTrack: track.id)
            return fromServer
        }

        guard let mediaStore else { return nil }
        let options = PlayerModel.streamOptions(
            for: track,
            policy: settings.streamingTranscode(expensiveNetwork: player.streamsWithMobilePolicy)
        )
        guard let request = try? await provider.streamRequest(for: track.id, options: options)
        else { return nil }
        let authenticated = proxySessions.authenticating(request)
        // The variant matters here as much as anywhere: ask about the original
        // while the cache holds a conversion and the answer is "not cached",
        // and the waveform quietly never appears for converted tracks.
        let variant = PlayerModel.variant(for: options)
        guard await mediaStore.isCached(track.id, request: authenticated, variant: variant),
              let file = try? await mediaStore.file(
                  for: track.id,
                  request: authenticated,
                  variant: variant,
                  markPlayed: false
              )
        else { return nil }
        guard let bars = await waveforms.waveform(for: track.id, url: await DecodedAudioCache.shared.playable(file).url) else { return nil }
        try? libraryIndex?.storeWaveform(bars, forTrack: track.id)
        return bars
    }
    /// Set when a request comes back as a login page; the root raises the
    /// sign-in sheet for it.
    var pendingProxySignIn: ProxySignInRequest?
    /// Set instead when a session we *had* stopped working, so the user gets
    /// an explanation before a web view appears out of nowhere.
    var expiredProxySignIn: ProxySignInRequest?

    struct ProxySignInRequest: Identifiable, Equatable {
        let id = UUID()
        let config: ServerConfig
        let url: URL

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    /// Handles an error that turns out to be a proxy wall rather than anything the music server
    /// said.
    @discardableResult
    func handleProxyWall(_ error: any Error) -> Bool {
        guard case ProviderError.proxySignInRequired(let url) = error,
              let config = servers.activeServer,
              pendingProxySignIn == nil, expiredProxySignIn == nil
        else { return false }

        let request = ProxySignInRequest(config: config, url: url)
        if servers.proxySession(for: config.id) != nil {
            // Stale beyond use — drop it so nothing keeps replaying a cookie
            // the proxy has already rejected.
            servers.setProxySession(nil, for: config.id)
            proxySessions.set(nil)
            expiredProxySignIn = request
        } else {
            pendingProxySignIn = request
        }
        return true
    }

    /// Offered in Settings so there is always a way back in: whenever this
    /// server is known to sit behind a proxy, or the connection is failing
    /// and a proxy could be why.
    var proxySignInOption: ProxySignInRequest? {
        guard let config = servers.activeServer else { return nil }
        let known = servers.proxySession(for: config.id) != nil
        guard known || connection.isFailed else { return nil }
        return ProxySignInRequest(
            config: config,
            url: config.addresses.remote ?? config.addresses.preferred
        )
    }

    /// A transport for asking a server one question from a settings screen — which libraries it has
    /// — under the same rules as everything else that talks to it: its certificate pins, no
    /// redirect off its host, its proxy session, and the Offline…
    func settingsTransport(for config: ServerConfig) -> ServerHTTPTransport {
        ServerHTTPTransport(
            config: config,
            timeout: PlexClient.setupTimeout,
            proxySessions: proxySessions,
            suspension: suspension
        )
    }

    /// One address's result from "Test connection".
    struct EndpointCheck: Identifiable {
        enum Outcome {
            case checking
            case reachable(String?)
            case signInRequired(URL)
            case failed(String)
        }

        let id = UUID()
        /// Which slot this address came out of. Not what to call it on
        /// screen — see `title`.
        let label: String
        let url: URL
        var outcome: Outcome

        /// What the address itself says about where it can be reached from.
        var kind: ServerAddressKind { url.addressKind }

        /// What to call it.
        var title: String { kind.label ?? label }
    }

    private(set) var endpointChecks: [EndpointCheck] = []

    /// Tests every configured address, not just the one in use.
    func testAllEndpoints() async {
        guard let config = servers.activeServer else {
            endpointChecks = []
            return
        }

        let addresses: [(String, URL)] = [
            config.addresses.local.map { ("Local", $0) },
            config.addresses.remote.map { ("Remote", $0) },
        ].compactMap(\.self)

        endpointChecks = addresses.map {
            EndpointCheck(label: $0.0, url: $0.1, outcome: .checking)
        }

        for (index, address) in addresses.enumerated() {
            let outcome = await testEndpoint(address.1, config: config)
            guard endpointChecks.indices.contains(index) else { return }
            endpointChecks[index].outcome = outcome
        }
    }

    /// One address, probed with whichever backend this server actually is.
    private func testEndpoint(_ url: URL, config: ServerConfig) async -> EndpointCheck.Outcome {
        let transport = ServerHTTPTransport(
            config: config, timeout: 12, proxySessions: proxySessions, suspension: suspension
        )
        do {
            let info: ServerInfo
            switch config.kind {
            case .subsonic:
                guard let credentials = servers.credentials(for: config.id) else {
                    return .failed("No sign-in stored for this server.")
                }
                let probe = SubsonicProvider(
                    config: config,
                    credentials: credentials,
                    customHeaders: servers.headerValues(for: config),
                    transport: transport
                )
                await probe.setBaseURL(url)
                info = try await probe.testConnection()
            case .plex:
                guard let token = servers.plexToken(for: config.id), let library = config.library else {
                    return .failed("No sign-in stored for this server.")
                }
                let probe = PlexProvider(
                    serverID: Self.storageID(for: config),
                    config: PlexServerConfig(
                        baseURL: url,
                        token: token,
                        sectionKey: library.key,
                        sectionTitle: library.title,
                        machineIdentifier: library.machineIdentifier
                    ),
                    identity: PlexInstallation.identity,
                    transport: transport
                )
                probe.setBaseURL(url)
                info = try await probe.testConnection()
            }
            let product = [info.productName, info.productVersion]
                .compactMap(\.self)
                .joined(separator: " ")
            return .reachable(product.isEmpty ? nil : product)
        } catch ProviderError.proxySignInRequired(let signInURL) {
            return .signInRequired(signInURL)
        } catch {
            let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            return .failed(message)
        }
    }

    /// Stores a captured proxy session and reconnects through it.
    func adoptProxySession(_ session: ProxySession) {
        guard let config = servers.activeServer else { return }
        servers.setProxySession(session, for: config.id)
        proxySessions.set(session)
        Task {
            await connectActive()
            // Signing in is the answer to a failed check, so the check that
            // prompted it should settle by itself rather than leaving the
            // user to run it again to find out whether it worked.
            if !endpointChecks.isEmpty {
                await testAllEndpoints()
            }
        }
    }

    /// Whether the library should be shown as what is on the phone.
    var isOffline: Bool {
        settings.offlineMode || connection.isFailed
    }

    /// Called when the switch is flipped, so the player stops reporting plays and the pages re-read
    /// the index through the offline filter.
    func offlineModeChanged(forcingSync: Bool = false) {
        suspension.isSuspended = settings.offlineMode
        player.isOffline = settings.offlineMode
        libraryVersion &+= 1
        if settings.offlineMode {
            goOffline()
        } else {
            goOnline(forcingSync: forcingSync)
        }
    }

    /// Nothing more is to be asked of the server: stop asking again, and stop
    /// the sync that is running against it.
    private func goOffline() {
        pendingForcedSync = false
        noNetworkTask?.cancel()
        updateReconnectLoop()
        standDownRunningSync()
    }

    /// Offline Mode has been switched off.
    private func goOnline(forcingSync: Bool) {
        if forcingSync { pendingForcedSync = true }
        // The one thing launching offline held back — see the call in `init`.
        backfillPlexAccountIDs()
        switch GoOnlinePlan.action(hasProvider: provider != nil, hasEndpoint: endpointControl != nil) {
        case .connect:
            Task { await connectActive() }
        case .refresh:
            requestEndpointRefresh(includingIdle: true)
        }
    }

    var isOfflineByChoice: Bool { settings.offlineMode }

    /// Background download sessions are named after the library they belong
    /// to, with this in front so a relaunch can tell ours from anything else.
    static let downloadSessionPrefix = AppIdentity.phone + ".downloads."

    /// Rebuilds the session iOS is asking about and waits for it to hand over what it finished
    /// while we were gone.
    func resumeBackgroundDownloads(identifier: String) async {
        let suffix = String(identifier.dropFirst(Self.downloadSessionPrefix.count))
        guard let uuid = UUID(uuidString: suffix),
              let config = config(owningStorage: ServerID(rawValue: uuid))
        else { return }

        let downloader = BackgroundDownloader.shared(
            identifier: identifier,
            pins: config.pinnedCertificates,
            allowedOrigins: config.allowedOrigins
        )
        // The files are put in place by the session itself; the bookkeeping
        // catches up at the next proper launch. This only has to outlast the
        // hand-over — and not for ever, in case there is nothing to hand.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await downloader.waitForSavedEvents() }
            group.addTask { try? await Task.sleep(for: .seconds(20)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Storage identities

    /// The libraries each server has filed things under, written down as they are first used.
    @ObservationIgnored private var storageRegistry: StorageRegistry?

    /// Where the app keeps its own files: the index, the downloads and this.
    nonisolated private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Plevi", directoryHint: .isDirectory)
    }

    private static var storageRegistryURL: URL {
        supportDirectory.appending(path: "storage-registry.json")
    }

    private func loadedStorageRegistry() -> StorageRegistry? {
        if storageRegistry == nil {
            storageRegistry = try? StorageRegistry.load(from: Self.storageRegistryURL)
        }
        return storageRegistry
    }

    /// Notes that `server` files something under `storage`, once.
    private func noteStorageInUse(_ storage: ServerID, forServer server: ServerID) {
        guard var registry = loadedStorageRegistry() else { return }
        guard registry.record(storage: storage, forServer: server) else { return }
        storageRegistry = registry
        try? registry.save(to: Self.storageRegistryURL)
    }

    /// Every storage identity `config` has used: what the registry recorded, the library it points
    /// at now, and — for a registry that started after the libraries were first used — the other
    /// Quick Switch libraries of the same Plex server, whose…
    private func knownStorageIDs(of config: ServerConfig) -> Set<ServerID> {
        var ids = loadedStorageRegistry()?.storageIDs(ofServer: config.id) ?? []
        ids.insert(Self.storageID(for: config))
        if config.kind == .plex, let machine = config.library?.machineIdentifier {
            for selection in settings.quickSwitchLibraries where selection.machineIdentifier == machine {
                var other = config
                other.library = selection
                ids.insert(Self.storageID(for: other))
            }
        }
        return ids
    }

    /// The server a storage identity belongs to, when there still is one.
    private func config(owningStorage storage: ServerID) -> ServerConfig? {
        if let owner = loadedStorageRegistry()?.server(owningStorage: storage),
           let config = servers.servers.first(where: { $0.id == owner }) {
            return config
        }
        return servers.servers.first { knownStorageIDs(of: $0).contains(storage) }
    }

    /// Deletes everything a server's libraries left on this phone: index, downloads, play and
    /// artwork caches, and the transfers still running for them.
    func forgetLibraries(of serverID: ServerID) {
        guard let config = servers.servers.first(where: { $0.id == serverID }) else { return }
        let ids = knownStorageIDs(of: config)

        // Nothing may hold a file open, or keep writing to it, when it goes.
        if let open = openLibrary, ids.contains(open) {
            standDownRunningSync()
            downloads?.removeEverything()
            tearDownStack()
            mediaStore = nil
            artwork = nil
            artworkCanFetch = false
            libraryIndex = nil
            openLibrary = nil
        }
        for id in ids {
            siblingIndexes.removeValue(forKey: id)
            // The store keeps a folder and a transport for its library; a
            // library added again under the same identity must get a new one.
            mediaStores.removeValue(forKey: id)
        }

        for id in ids {
            BackgroundDownloader.shared(
                identifier: Self.downloadSessionPrefix + id.rawValue.uuidString,
                pins: config.pinnedCertificates,
                allowedOrigins: config.allowedOrigins
            ).cancelAll()
        }

        if var registry = loadedStorageRegistry() {
            registry.forget(server: serverID)
            storageRegistry = registry
            try? registry.save(to: Self.storageRegistryURL)
        }

        // Off the main actor: a library of downloads is gigabytes.
        Task.detached(priority: .utility) {
            for id in ids { Self.removeFiles(of: id) }
        }
    }

    nonisolated private static func removeFiles(of id: ServerID) {
        let fileManager = FileManager.default
        let name = id.rawValue.uuidString
        let index = LibraryStorage.indexURL(for: id)
        let support = supportDirectory
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let doomed = [
            support.appending(path: "Downloads", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory),
            index,
            URL(fileURLWithPath: index.path + "-wal"),
            URL(fileURLWithPath: index.path + "-shm"),
            caches.appending(path: "Media", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory),
            caches.appending(path: "Artwork", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory),
            KeptArtwork.root.appending(path: name, directoryHint: .isDirectory),
        ]
        for url in doomed { try? fileManager.removeItem(at: url) }
    }

    /// Points the active server at another of its libraries and reconnects.
    func switchLibrary(to selection: LibrarySelection) async {
        guard let id = servers.activeServerID,
              selection.key != servers.activeServer?.library?.key
        else { return }
        // The library being left, noted before it changes: a queue of its songs
        // is still good on this server's other libraries. See
        // `stopPlaybackIfForeign`.
        let leaving = servers.activeServer.map(Self.storageID(for:))
        guard // Refused for a selection that belongs to another server: the
              // Quick Switch list is shared by all of them.
              servers.setLibrary(selection, for: id)
        else { return }
        if let leaving, let arriving = servers.activeServer.map(Self.storageID(for:)) {
            librariesOfServer[id, default: []].formUnion([leaving, arriving])
        }
        // Playback carries on through a switch between this server's own libraries, since a Plex
        // song's id means the same to every library on its server.
        guard await connectActive() else { return }
        showNote("Switched to \(selection.title)")
        // Forced: a switch is exactly the moment to re-read, and a sync
        // already running for the library being left has nothing to say about
        // the one being joined.
        startBackgroundSync(force: true)
    }

    /// (Re)builds the provider stack for the active server and tests the
    /// connection. Called at launch, after setup, and from Settings.
    // MARK: Keeping the server address right

    /// What is needed to move a live connection to a different address: the selector that chose the
    /// current one, what it chose, and how to tell the provider.
    @MainActor
    private final class EndpointControl {
        var selector: EndpointSelector
        var current: URL
        let apply: @Sendable (URL) async -> Void

        init(selector: EndpointSelector, current: URL, apply: @escaping @Sendable (URL) async -> Void) {
            self.selector = selector
            self.current = current
            self.apply = apply
        }
    }

    /// The transports and selectors one run of `connectActive()` built, so
    /// the ones a later run replaces can be let go of. Each holds a
    /// `URLSession`, which keeps itself alive until invalidated.
    @MainActor
    private final class StackTransports {
        private var transports: [ServerHTTPTransport] = []
        private var selectors: [EndpointSelector] = []

        @discardableResult
        func track(_ transport: ServerHTTPTransport) -> ServerHTTPTransport {
            transports.append(transport)
            return transport
        }

        @discardableResult
        func track(_ selector: EndpointSelector) -> EndpointSelector {
            selectors.append(selector)
            return selector
        }

        /// Selectors always: only the connection's own address refresh ever reads one, and that has
        /// been handed the new one.
        func retire(includingTransports: Bool) {
            if includingTransports {
                for transport in transports { transport.close() }
                transports = []
            }
            let doomed = selectors
            selectors = []
            Task { for selector in doomed { await selector.close() } }
        }
    }

    @ObservationIgnored private var endpointControl: EndpointControl?

    /// Whether the connection is using the server's remote address although it has a home one to
    /// prefer — which is what "away from home" means here.
    var isAwayFromHome: Bool {
        guard let control = endpointControl,
              let home = servers.activeServer?.addresses.probeOrder?.first
        else { return false }
        return control.current != home
    }
    @ObservationIgnored private var stackTransports: StackTransports?
    @ObservationIgnored private var noNetworkTask: Task<Void, Never>?
    @ObservationIgnored private var refreshingEndpoint = false
    @ObservationIgnored private var refreshEndpointAgain = false
    @ObservationIgnored private var refreshIncludesIdle = false
    /// The task asking a failed connection again; nil when none is wanted.
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Set by Go Online, and used up by the next time the connection is
    /// known good.
    @ObservationIgnored private var pendingForcedSync = false
    /// A connection just came back, so playback that gave up on the network
    /// may start again — after the refresh below, which is what makes the
    /// retry go to the right address. See `PlayerModel.networkReturned`.
    @ObservationIgnored private var resumeAfterRefresh = false

    /// The connection changed shape under a running app.
    private func networkPathChanged(satisfied: Bool) {
        noNetworkTask?.cancel()
        guard !settings.offlineMode else { return }
        guard satisfied else {
            // Nothing at all can be reached.
            noNetworkTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self, self.provider != nil,
                      case .connected = self.connection else { return }
                self.markFailed(
                    String(localized: "There's no network connection."),
                    kind: .noNetwork
                )
            }
            return
        }
        // The song that gave up on the network is started again once the
        // address has been re-chosen, not before: see `resumeAfterRefresh`.
        resumeAfterRefresh = true
        requestEndpointRefresh()
    }

    /// Asks for `refreshEndpoint()` without running two at once — a run in progress is left to
    /// finish and told to go round again, never cancelled, because the probe inside it caches
    /// whatever it decides and a cancelled probe decides "unreachable".
    private func requestEndpointRefresh(includingIdle: Bool = false) {
        if includingIdle { refreshIncludesIdle = true }
        guard !refreshingEndpoint else {
            refreshEndpointAgain = true
            return
        }
        refreshingEndpoint = true
        Task {
            repeat {
                refreshEndpointAgain = false
                let includingIdle = refreshIncludesIdle
                refreshIncludesIdle = false
                await refreshEndpoint(includingIdle: includingIdle)
            } while refreshEndpointAgain
            refreshingEndpoint = false
            if resumeAfterRefresh {
                resumeAfterRefresh = false
                player.networkReturned()
            }
        }
    }

    private var connectionPhase: EndpointRefreshPlan.Phase {
        switch connection {
        case .idle: .idle
        case .connecting: .connecting
        case .connected: .connected
        case .failed: .failed
        }
    }

    /// Chooses the address again, and tests the connection when there is something to learn: the
    /// address moved, the connection was marked unreachable and the network may have come back — or
    /// the address did not move and the network did, in which…
    func refreshEndpoint(includingIdle: Bool = false) async {
        guard !settings.offlineMode, let provider, let control = endpointControl else { return }
        guard EndpointRefreshPlan.action(
            phase: connectionPhase, addressMoved: true, includingIdle: includingIdle
        ) != .skip else { return }
        let generation = providerGeneration
        await control.selector.invalidate()
        let url = await control.selector.activeBaseURL()
        guard generation == providerGeneration, !settings.offlineMode else { return }
        let moved = url != control.current
        if moved {
            await control.apply(url)
            control.current = url
        }
        // Read again: what the connection is may have changed while the
        // address was being chosen.
        switch EndpointRefreshPlan.action(
            phase: connectionPhase, addressMoved: moved, includingIdle: includingIdle
        ) {
        case .skip:
            return
        case .fullTest:
            do {
                let info = try await provider.testConnection()
                guard generation == providerGeneration, !settings.offlineMode else { return }
                markConnected(info, generation: generation)
            } catch {
                guard generation == providerGeneration, !settings.offlineMode else { return }
                markFailed(error)
                handleProxyWall(error)
            }
        case .quickCheck:
            let verdict = await ReachabilityCheck.run { try await provider.testConnection() }
            guard generation == providerGeneration, !settings.offlineMode else { return }
            switch verdict {
            case .answered(let info):
                // Nothing changed, and nothing to tell anybody — unless this is the moment the
                // connection came back from being off, or something is waiting to be sent, which is
                // what an answer is the evidence for.
                if includingIdle || (outbox?.pending ?? 0) > 0 {
                    markConnected(info, generation: generation)
                }
            case .unreachable(let error):
                markFailed(
                    error.map(Self.failureMessage)
                        ?? String(localized: "The server did not answer."),
                    kind: error.map(ConnectionFailureKind.classify) ?? .unreachable
                )
            case .answeredBadly(let error):
                markFailed(error)
                handleProxyWall(error)
            }
        }
    }

    // MARK: Connection state

    private static func failureMessage(_ error: any Error) -> String {
        (error as? ProviderError)?.errorDescription ?? error.localizedDescription
    }

    /// The connection is failed, and this is why. The kind is set first: the
    /// state's observer reads it to decide whether to keep asking.
    private func markFailed(_ message: String, kind: ConnectionFailureKind) {
        connectionFailure = kind
        connection = .failed(message)
    }

    private func markFailed(_ error: any Error) {
        markFailed(Self.failureMessage(error), kind: ConnectionFailureKind.classify(error))
    }

    /// The server has answered.
    private func markConnected(_ info: ServerInfo, generation: Int) {
        connection = .connected(info)
        let force = pendingForcedSync
        pendingForcedSync = false
        let outbox = outbox
        Task { [weak self] in
            await outbox?.drain()
            guard let self, generation == providerGeneration,
                  case .connected = connection, !settings.offlineMode else { return }
            resyncIfMappingChanged()
            if force {
                startBackgroundSync(force: true)
            } else {
                startBackgroundSyncIfDue()
            }
        }
    }

    // MARK: Asking a failed connection again

    private var reconnectIsWanted: Bool {
        connection.isFailed && ConnectionRetrySchedule.shouldRun(
            failure: connectionFailure,
            offlineByChoice: settings.offlineMode,
            pathSatisfied: network.isSatisfied
        )
    }

    /// Keeps one retry loop running while a connection is failed for a reason that time can put
    /// right, and none otherwise.
    private func updateReconnectLoop() {
        guard reconnectIsWanted else {
            reconnectTask?.cancel()
            reconnectTask = nil
            return
        }
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await ConnectionRetrySchedule.run(
                isStillFailing: { [weak self] in self?.reconnectIsWanted ?? false },
                attempt: { [weak self] in self?.requestEndpointRefresh() }
            )
            // A loop that was cancelled has already been replaced or dropped
            // by whoever cancelled it.
            guard let self, !Task.isCancelled else { return }
            reconnectTask = nil
        }
    }

    /// Rebuilds the provider stack for the active server and tests the connection.
    @discardableResult
    func connectActive() async -> Bool {
        await Task { await connect() }.value
    }

    /// One run of `connectActive()`.
    private func connect() async -> Bool {
        let generation = runs.begin()
        // What this run builds that holds a `URLSession`. Let go of at the end
        // unless the run published it — a run that was overtaken or could not
        // build never had a user for any of it.
        let transports = StackTransports()
        var published = false
        defer { if !published { transports.retire(includingTransports: true) } }
        guessLibraryEmptiness()
        // Before anything is built, so nothing built here can make a request
        // the setting forbids.
        suspension.isSuspended = settings.offlineMode
        player.isOffline = settings.offlineMode
        // The library's own file first, and before the server is so much as
        // probed: browsing reads that file and nothing else.
        openLocalLibrary()
        // This run's own index. `libraryIndex` is shared, and a newer run
        // replaces it while this one is waiting on the network.
        let index = libraryIndex
        // Whether this is a different library from the stack that is published, worked out once and
        // before anything is awaited.
        let incoming = servers.activeServer.map(Self.storageID(for:))
        let storageChanged = runs.storageChanged(incoming: incoming)
        // The DJ first: it puts back the queue it displaced, and the queue is
        // about to be stopped if it came from another library.
        if storageChanged { dj?.deactivate() }
        stopPlaybackIfForeign(to: incoming)
        guard let config = servers.activeServer else {
            // A sync of the library being left has nothing to say about a
            // phone with no server, and the handles below are its stack's.
            standDownRunningSync()
            tearDownStack()
            provider = nil
            artwork = nil
            artworkCanFetch = false
            libraryIndex = nil
            openLibrary = nil
            noteLibraryEmptiness()
            connection = .idle
            // The watch is told there is no server now, which is how it knows to go back to its
            // waiting screen.
            if servers.isLoaded { provisionWatch() }
            // Sessions other devices hold with this one were built under a
            // library that is no longer open.
            remote.libraryChanged(to: nil)
            return true
        }
        // Everything cached is keyed by server *and* library.
        let storage = Self.storageID(for: config)
        // Written down the first time it is used: a Plex library switched
        // away from cannot be found again from the configuration, and
        // removing the server has to delete it too.
        noteStorageInUse(storage, forServer: config.id)
        // "Switching library or server on the controller ends control."
        // remote.controllingLibraryID is the library the current controlling session started under;
        // a reconnect to the same one leaves it alone, so this only ever…
        if let controllingLibraryID = remote.controllingLibraryID, controllingLibraryID != storage {
            remote.disconnect(farewell: .libraryChanged)
        }
        // And the other direction: devices controlling this one (R-19).
        remote.libraryChanged(to: storage)
        // Before the server is reached, beside the index and for the same reason.
        let loader = ArtworkLoader(
            transport: transports.track(
                ServerHTTPTransport(config: config, proxySessions: proxySessions, suspension: suspension)
            ),
            serverID: storage,
            diskLimit: ArtworkLoader.limit(megabytes: settings.artworkCacheMegabytes)
        )
        // The sleeve of the song playing comes across with the player, so the
        // card opened after a switch between this server's libraries has it on
        // its first frame. See `ArtworkLoader.pin`.
        loader.adoptPin(from: artwork)
        // Pictures inside downloaded files are read from where the download
        // is kept, whichever manager holds it by then.
        await loader.useEmbeddedSource { [weak self] id in
            await MainActor.run { self?.downloads?.embeddedArtworkFile(for: id) }
        }
        artwork = loader
        // Reading only, until the server is reached below.
        artworkCanFetch = false
        let build = await buildProvider(for: config, generation: generation, transports: transports)
        guard runs.isCurrent(generation) else { return false }
        guard let build else {
            // The server couldn't be reached, but the local index opened fine above — keep it, so
            // browsing still works offline instead of being wiped out by a failed connection
            // attempt.
            if storageChanged {
                // Nothing to carry a queue on any more: the transports it
                // would stream through are being closed, so it would run out
                // song by song instead of stopping.
                player.stop()
                tearDownStack()
            }
            provider = nil
            noteLibraryEmptiness()
            // A failure, not an idle.
            markFailed(
                String(localized: "Couldn't set up this server — check it in Settings."),
                kind: .setupIncomplete
            )
            provisionWatch()
            return true
        }
        let built = build.provider

        // Now it can fetch as well as read. Anything asked for while the
        // server was still being reached was answered from disk or not at
        // all, and `ArtworkView` asks again for whatever came back empty.
        await loader.use(built)
        // Past the last await before publishing: from here to the end of the
        // block below nothing suspends, so what is published is one run's
        // and only that run's. An overtaken run drops what it built.
        guard runs.isCurrent(generation) else { return false }
        runs.publish(storage, run: generation)
        published = true
        // What the stack this replaces was holding. Its selectors always, its
        // transports when the library changed and nothing that is still on
        // screen can be asking them for more.
        let outgoing = stackTransports
        stackTransports = transports
        outgoing?.retire(includingTransports: storageChanged)
        endpointControl = build.endpoint
        provider = built
        // Only if this run's loader is still the published one — see the
        // note where it was built. A run that has been overtaken must not
        // tell the views that somebody else's loader can fetch.
        if artwork === loader { artworkCanFetch = true }
        // The index and everything filed beside it were opened at the top of this, before the
        // server was reached — see `openLocalLibrary`.
        let mediaTransport = transports.track(ServerHTTPTransport(
            config: config,
            resourceTimeout: 3600,
            proxySessions: proxySessions,
            suspension: suspension
        ))
        let mediaLimit = Int64(settings.mediaCacheGigabytes) * 1024 * 1024 * 1024
        // A conversion the store cuts off part-way is still running on
        // the server until somebody says otherwise.
        let releaseConversion: @Sendable (MediaID) async -> Void = { id in await built.endPlayback(for: id) }
        let store: MediaFileStore
        if let existing = mediaStores[storage] {
            await existing.update(
                transport: mediaTransport,
                limit: mediaLimit,
                releaseConversion: releaseConversion
            )
            store = existing
        } else {
            store = MediaFileStore(
                transport: mediaTransport,
                serverID: storage,
                limit: mediaLimit,
                releaseConversion: releaseConversion
            )
            mediaStores[storage] = store
        }
        // Once per launch and library, whichever run gets here first: the only
        // moment a half-written file can be known to belong to nobody.
        await store.sweepOncePerLaunch()
        // The two awaits above (the store being pointed at this connection, and its once-per-launch
        // sweep) are the only suspensions after the publish.
        guard runs.isCurrent(generation) else { return false }
        mediaStore = store
        trimCachesAcrossLibraries()
        // Again, now: this is the last moment before the player is handed the new provider, and
        // something from the previous library may have been started in the seconds the connection
        // took.
        stopPlaybackIfForeign(to: storage)
        player.configure(
            provider: built,
            artwork: artwork,
            index: index,
            proxySessions: proxySessions,
            mediaStore: store,
            waveforms: waveforms
        )
        // Transfers the system runs for us, per library: one background session identifier each, so
        // pinning and any client certificate belong to the server they were configured for and
        // never travel to another.
        downloads?.stop()
        if let index {
            let downloader = BackgroundDownloader.shared(
                identifier: "\(AppIdentity.phone).downloads.\(storage.rawValue.uuidString)",
                pins: config.pinnedCertificates,
                allowedOrigins: config.allowedOrigins
            )
            let manager = DownloadManager(
                serverID: storage,
                index: index,
                provider: built,
                downloader: downloader,
                transport: transports.track(ServerHTTPTransport(
                    config: config,
                    proxySessions: proxySessions,
                    suspension: suspension
                )),
                settings: settings,
                network: network,
                proxySessions: proxySessions,
                readsEmbeddedArtwork: config.kind == .plex
            )
            downloads = manager
            manager.artworkLoader = { [weak self] in self?.artwork }
            manager.foreignFile = { [weak self] id in self?.foreignDownloadFile(for: id) }
            manager.otherLibraries = { [weak self] in self?.otherQuickLibraryIndexes().map(\.index) ?? [] }
            manager.onRefused = { [weak self] message in
                self?.showTransientError(message)
            }
            // A transfer met the proxy's sign-in page: the same prompt a
            // browse request gets, once for the whole queue.
            let wallPage = config.addresses.remote ?? config.addresses.preferred
            manager.onProxyWall = { [weak self] page in
                self?.handleProxyWall(ProviderError.proxySignInRequired(url: page ?? wallPage))
            }
            player.downloads = manager
            // Downloads give way while a song is being converted to listen
            // to, and start again the moment it is not.
            manager.playbackIsFetching = { [weak self] in
                self?.player.isFetchingForPlayback ?? false
            }


            // A DJ's repeat-avoidance history and its picks are meaningless once the server or
            // library underneath them has changed, so then whatever was running stops (it was
            // deactivated above, which put its queue back) and a fresh engine takes over.
            if !storageChanged, let dj {
                dj.rebind(index: index, provider: built)
            } else {
                dj?.stop()
                dj = DJEngine(
                    index: index,
                    provider: built,
                    player: player,
                    settings: settings,
                    isOffline: { [weak self] in self?.isOffline ?? false }
                )
            }

            // One queue per library, not one per connection: the table it drains is shared, and a
            // second outbox draining over it (a Retry during a slow drain) sent every waiting play
            // twice.
            let outbox: ChangeOutbox
            if let existing = self.outbox, existing.serves(index) {
                existing.rebind(provider: built)
                outbox = existing
            } else {
                self.outbox?.stop()
                outbox = ChangeOutbox(
                    index: index,
                    provider: built,
                    isOffline: { [weak self] in self?.isOffline ?? false }
                )
            }
            outbox.onDropped = { [weak self] message in
                self?.showTransientError(message)
            }
            self.outbox = outbox
            // Plays go through the same queue as everything else, so a flight
            // of listening arrives with the times it happened.
            player.onPlaySubmitted = { id, date in
                Task { await outbox.play(id: id, at: date) }
            }
            player.onSourcePlayed = { [weak self] source, date in
                self?.playLog.record(source, at: date)
            }
            // Not drained here: the server has not been reached yet, and `markConnected` empties it
            // once it has — after the test, and before the sync, which is the order that keeps a
            // walk from overwriting what is still waiting to be sent.
            Task { [weak self] in
                // A manager that was replaced before this got to run is already stopped and must
                // not start: it would sweep and listen for a library that is no longer the active
                // one.
                guard let self, downloads === manager else { return }
                await manager.start()
                // After the files have been settled, not before: either of these running first
                // would be asking about songs while the manager was still working out which it
                // already had.
                let refreshPlaylists = settings.refreshPlaylistsAtLaunch
                let refreshDetails = settings.refreshDownloadedDetailsAtLaunch
                async let playlists: Void = {
                    if refreshPlaylists {
                        await manager.refreshDownloadedPlaylists()
                    }
                }()
                async let details: Void = {
                    if refreshDetails {
                        await manager.refreshDownloadedDetails(askingServer: true)
                    }
                }()
                async let waveforms: Void = backfillWaveforms()
                _ = await (playlists, details, waveforms)
            }
        } else {
            // No index means no queue and no downloads — and the player must
            // be told, or it keeps the last library's objects and a listen
            // goes nowhere at all.
            downloads = nil
            outbox?.stop()
            outbox = nil
            player.downloads = nil
            dj?.stop()
            dj = nil
            player.onPlaySubmitted = { id, date in
                Task { try? await built.scrobble(id: id, at: date, submission: true) }
            }
            player.onSourcePlayed = { [weak self] source, date in
                self?.playLog.record(source, at: date)
            }
        }
        player.applyAudioSettings(settings)
        // Before the offline guard below: which server this is and how to
        // sign in to it are true whether or not this phone is going to talk
        // to it, and the watch may well be the device that can.
        provisionWatch()

        // Offline by choice: the stack is built so the index, the downloads and the queue all work,
        // and the server is simply not asked.
        guard !settings.offlineMode else {
            connection = .idle
            return true
        }

        do {
            let info = try await built.testConnection()
            // Not the verdict of a run that has been overtaken: it is about
            // a server this app may no longer be pointed at.
            guard runs.isCurrent(generation) else { return false }
            markConnected(info, generation: generation)
            return true
        } catch {
            guard runs.isCurrent(generation) else { return false }
            markFailed(error)
            handleProxyWall(error)
            // A Plex server that cannot be reached at all is the other way the stored address can
            // turn out to be wrong, and the only evidence a one-address entry can produce.
            if config.kind == .plex, !settings.offlineMode, config.addresses.local != nil {
                // Both, and in this order: `betterLocalAddress` is the ask, and the token says the
                // ask already happened while this test was still running.
                recoveries += 1
                defer { recoveries -= 1 }
                let repaired = await betterLocalAddress(for: config) != nil
                let alreadyRepaired = addressRepaired.remove(config.id) != nil
                // Not if somebody has connected in the meantime: this would
                // overtake their run with a reconnect to what may no longer
                // be the active server.
                guard runs.isCurrent(generation) else { return false }
                if repaired || alreadyRepaired { return await connectActive() }
            }
            // The other half: the remote address is the one in use, the network is there, and
            // nothing answers on it.
            if config.kind == .plex, !settings.offlineMode, network.isSatisfied,
               ConnectionFailureKind.classify(error).isReachabilityProblem,
               await build.endpoint.selector.lastChoice?.isLocal != true {
                recoveries += 1
                defer { recoveries -= 1 }
                let repaired = await betterRemoteAddress(for: config) != nil
                guard runs.isCurrent(generation) else { return false }
                if repaired { return await connectActive() }
            }
            return true
        }
    }

    /// Ends playback when the queue is of a library other than the one being connected (or of any
    /// library, when the last server has gone).
    private func stopPlaybackIfForeign(to incoming: ServerID?) {
        let queueServer = player.currentItem?.track.id.server ?? player.queue.first?.track.id.server
        // Not for another library on the same Plex server.
        if let queueServer, queueServer != incoming, librariesOnActiveServer().contains(queueServer) {
            return
        }
        if ServerSwitching.playbackMustStop(queueServer: queueServer, incoming: incoming) {
            player.stop()
        }
    }

    /// Storage identities of the libraries of the active Plex server that this
    /// app knows of: every one it has switched between this session, and those
    /// Quick Switch offers. Empty for any other kind of server, which has one.
    private func librariesOnActiveServer() -> Set<ServerID> {
        guard let config = servers.activeServer, config.kind == .plex else { return [] }
        var known = librariesOfServer[config.id] ?? []
        known.insert(Self.storageID(for: config))
        for sibling in siblingSelections() { known.insert(sibling.id) }
        return known
    }

    /// Lets go of everything built for the published library: its downloads,
    /// the DJ, the outbox and the hooks that fed them. For a library that is
    /// no longer the active one and has no replacement.
    private func tearDownStack() {
        downloads?.stop()
        downloads = nil
        player.downloads = nil
        dj?.stop()
        dj = nil
        outbox?.stop()
        outbox = nil
        player.onPlaySubmitted = nil
        player.onSourcePlayed = nil
        stackTransports?.retire(includingTransports: true)
        stackTransports = nil
        runs.tearDown()
    }

    /// Ends the sync that is running, because the index it is filling is no longer the open one.
    private func standDownRunningSync() {
        guard case .syncing = syncState else { return }
        syncTask?.cancel()
        syncGeneration &+= 1
        syncState = .idle
        syncPhase = nil
        syncedAlbums = nil
        syncedTracks = nil
    }

    /// Kicks a full library sync without blocking the UI; index-backed views refresh via
    /// `libraryVersion` when it lands.
    static let indexMappingVersion = 6

    /// A stored library built by an older mapping is refreshed once, without waiting for the user
    /// to wonder why a fix did not take.
    private func resyncIfMappingChanged() {
        guard let libraryIndex else { return }
        let library = libraryIndex.server
        guard settings.indexMapping(for: library) != Self.indexMappingVersion else { return }
        // A library that has never been synced is about to be walked with
        // this mapping anyway.
        if ((try? libraryIndex.lastSyncAt()) ?? nil) == nil {
            settings.markIndexMapped(Self.indexMappingVersion, for: library)
            return
        }
        startBackgroundSync(force: true)
    }

    /// Syncs the library, optionally interrupting one already running.
    func drainOutbox() {
        Task { await outbox?.drain() }
    }

    /// How long a sync stays good enough that opening the app does not start another one.
    static let automaticSyncInterval: TimeInterval = 30 * 60

    /// The sync a launch starts on its own, which happens only if the last
    /// one is old enough to be worth replacing.
    func startBackgroundSyncIfDue() {
        if let last = (try? libraryIndex?.lastSyncAt()) ?? nil,
           Date().timeIntervalSince(last) < Self.automaticSyncInterval {
            return
        }
        startBackgroundSync()
    }

    // MARK: Background refresh

    /// The identifiers iOS knows these two jobs by.
    nonisolated static let refreshTaskID = AppIdentity.phone + ".refresh"
    nonisolated static let walkTaskID = AppIdentity.phone + ".walk"
    nonisolated static let watchTaskID = AppIdentity.phone + ".watch"

    /// The watch's own daily job: make sure it has been sent a library lately.
    func backgroundWatchSend() async {
        guard servers.isLoaded, openLocalLibrary() else { return }
        await watch.sendLibraryIfStale()
    }

    /// The short wake: ask the server whether the library has moved, and say whether a walk is now
    /// owed.
    func backgroundRefreshFoundChanges() async -> Bool {
        guard !settings.offlineMode, servers.isLoaded else { return false }
        guard let provider, let libraryIndex else {
            // Woken into a cold process, which is the usual way of it.
            return true
        }
        let engine = LibrarySyncEngine(provider: provider, index: libraryIndex)
        return await engine.walkIsDue() ?? false
    }

    /// The overnight job: the same sync the app runs at launch, awaited.
    func backgroundWalk() async {
        guard !settings.offlineMode, servers.isLoaded else { return }
        // Joined rather than owned, for the same reason, so an expiry while
        // connecting is only noticed once the connect is done.
        await bootIfNeeded()
        guard !Task.isCancelled, provider != nil, libraryIndex != nil else { return }
        // A sync already running is the answer to this one.
        let alreadySyncing = if case .syncing = syncState { true } else { false }
        if !alreadySyncing { startBackgroundSync() }
        guard let sync = syncTask else { return }
        await withTaskCancellationHandler {
            await sync.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.standDown(sync) }
        }
    }

    /// Stops a sync the system has run out of time for.
    private func standDown(_ sync: Task<Void, Never>) {
        guard syncTask == sync, case .syncing = syncState else { return }
        sync.cancel()
        syncGeneration &+= 1
        syncState = .idle
        syncPhase = nil
        syncedAlbums = nil
        syncedTracks = nil
    }

    func startBackgroundSync(force: Bool = false) {
        // A sync pairs a provider with an index, so it needs both to be the same library's.
        guard let provider = providerForActiveLibrary, let libraryIndex,
              provider.serverID == libraryIndex.server
        else { return }
        // Offline by choice means off the network, and a sync is the largest
        // thing the app does with it.
        guard !settings.offlineMode else { return }
        if case .syncing = syncState {
            guard force else { return }
            syncTask?.cancel()
        }
        syncState = .syncing("Starting…")
        syncPhase = nil
        syncedAlbums = nil
        syncedTracks = nil
        let engine = LibrarySyncEngine(provider: provider, index: libraryIndex)
        syncGeneration &+= 1
        let generation = syncGeneration
        syncTask = Task {
            do {
                let summary = try await engine.fullSync(force: force) { phase in
                    Task { @MainActor [weak self] in
                        guard let self, syncGeneration == generation else { return }
                        syncPhase = phase
                        switch phase {
                        case .artists:
                            syncState = .syncing("Artists…")
                        case .albums(let count):
                            syncedAlbums = count
                            syncState = .syncing("\(count) albums…")
                        case .tracks(let count):
                            syncedTracks = count
                            syncState = .syncing("\(count) tracks…")
                        case .finishing:
                            syncState = .syncing("Finishing…")
                        }
                    }
                }
                // Only if this sync is still the current one.
                guard syncGeneration == generation else {
                    drainOutbox()
                    return
                }
                syncState = .synced(Date())
                syncPhase = nil
                // Only a walk that finished has read every row with this
                // build's mapping; see `resyncIfMappingChanged`.
                if summary.outcome == .walked {
                    settings.markIndexMapped(Self.indexMappingVersion, for: libraryIndex.server)
                }
                // Counted once and used three times over.
                let stats = try? libraryIndex.stats()
                noteLibraryEmptiness(stats)
                // Only when rows actually moved. Twenty-odd screens reload
                // on this, and a sync the server told us to skip changed
                // nothing for any of them to show.
                if summary.outcome != .unchanged {
                    libraryVersion += 1
                    syncRevision += 1
                    ratedLocally = [:]
                }
                // The server answered, so anything waiting can go now — this
                // is the path that covers a connection simply coming back,
                // with nobody flipping a switch.
                drainOutbox()
                // Behind everything else: a shelf built on a playlist rule
                // needs songs that only the server has. See
                // `fillPlaylistMembershipForShelves`.
                Task { await self.fillPlaylistMembershipForShelves() }
                // And the watch, if the library actually changed.
                offerLibraryToWatch(stamp: stats.map(Self.libraryStamp))
                // What the sync just changed about a downloaded song — a new cover, a corrected
                // title — is in the library now and not yet on its download row.
                if settings.refreshDownloadedDetailsAtLaunch, summary.outcome != .unchanged, let downloads {
                    Task { await downloads.refreshDownloadedDetails(askingServer: false) }
                }
                // This library first, then the others under Quick Switch, so a
                // search across them has something to read.
                syncOtherQuickLibraries()
            } catch is CancellationError {
                // A sync asked to stand down for a newer one. Saying so on
                // screen would replace the sync that is now running with the
                // failure of the one it replaced.
            } catch {
                guard !Task.isCancelled, syncGeneration == generation else { return }
                let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
                syncState = .failed(message)
                syncPhase = nil
                noteLibraryEmptiness()
            }
        }
    }

    /// Applies a changed cache size to the running store, and reports what is held so the setting
    /// can show it.
    func applyMediaCacheLimit() async {
        await mediaStore?.setLimit(mediaCacheLimit)
        trimCachesAcrossLibraries()
    }

    func mediaCacheUsage() async -> Int64 {
        await Task.detached(priority: .utility) { CacheTree.usage(of: MediaFileStore.rootDirectory) }.value
    }

    func applyArtworkCacheLimit() async {
        await artwork?.setDiskLimit(artworkCacheLimit)
        trimCachesAcrossLibraries()
    }

    func artworkCacheUsage() async -> Int64 {
        await Task.detached(priority: .utility) { CacheTree.usage(of: ArtworkLoader.rootDirectory) }.value
    }

    func clearArtworkCache() async {
        await artwork?.clear()
        let open = openLibrary?.rawValue.uuidString
        await Task.detached(priority: .utility) {
            CacheTree.clear(root: ArtworkLoader.rootDirectory, except: open)
        }.value
    }

    func dropConvertedFiles() async {
        await mediaStore?.dropAllConversions()
    }

    func clearMediaCache() async {
        await mediaStore?.clear()
        let open = openLibrary?.rawValue.uuidString
        await Task.detached(priority: .utility) {
            CacheTree.clear(root: MediaFileStore.rootDirectory, except: open)
        }.value
    }

    private var mediaCacheLimit: Int64 { Int64(settings.mediaCacheGigabytes) * 1024 * 1024 * 1024 }
    private var artworkCacheLimit: Int64 { ArtworkLoader.limit(megabytes: settings.artworkCacheMegabytes) }

    /// Keeps the caches of the libraries that are not open inside the limit the open one is held
    /// to.
    func trimCachesAcrossLibraries() {
        let open = openLibrary?.rawValue.uuidString
        let media = mediaCacheLimit
        let art = artworkCacheLimit
        Task.detached(priority: .utility) {
            CacheTree.trim(root: MediaFileStore.rootDirectory, to: media, sparing: open)
            CacheTree.trim(root: ArtworkLoader.rootDirectory, to: art, sparing: open)
        }
    }

    // MARK: Searching the other quick libraries

    /// Indexes of the other Quick Switch libraries, opened only so Search can read them.
    @ObservationIgnored private var siblingIndexes: [ServerID: LibraryIndex] = [:]
    /// Which libraries of one server this session has moved between, by server,
    /// so a queue from the one left is known to belong to the same server.
    @ObservationIgnored private var librariesOfServer: [ServerID: Set<ServerID>] = [:]

    /// The titles of the other libraries ticked under Quick Switch, by the identity their rows
    /// carry — what a search result uses to say which library it came from.
    var siblingLibraryTitles: [ServerID: String] {
        var titles: [ServerID: String] = [:]
        for sibling in siblingSelections() { titles[sibling.id] = sibling.selection.title }
        return titles
    }

    /// The Quick Switch libraries that belong to the active server. The
    /// setting is one list for every server; only these can be switched to.
    var quickSwitchChoices: [LibrarySelection] {
        servers.activeServer?.quickSwitchChoices(from: settings.quickSwitchLibraries) ?? []
    }

    /// The other libraries on the active Plex server that Quick Switch offers.
    private func siblingSelections() -> [(id: ServerID, selection: LibrarySelection, config: ServerConfig)] {
        guard let config = servers.activeServer, config.kind == .plex,
              let active = config.library else { return [] }
        let activeStorage = Self.storageID(for: config)
        var found: [(id: ServerID, selection: LibrarySelection, config: ServerConfig)] = []
        for selection in quickSwitchChoices where selection.key != active.key {
            var other = config
            other.library = selection
            let id = Self.storageID(for: other)
            guard id != activeStorage, !found.contains(where: { $0.id == id }) else { continue }
            found.append((id, selection, other))
        }
        return found
    }

    // MARK: Keeping the other quick libraries read

    @ObservationIgnored private var siblingSyncTask: Task<Void, Never>?
    /// Which background read a task belongs to, so one that was cancelled and
    /// finishes late does not clear the handle of the one that replaced it.
    @ObservationIgnored private var siblingSyncGeneration = 0
    /// When a read of a library last failed, so a library that cannot be read
    /// (taken off the server, no access) is not tried again after every sync.
    @ObservationIgnored private var siblingFailures: [ServerID: Date] = [:]
    /// Libraries already announced this session: the note says a library is
    /// being read once, not each time a read that failed is begun again.
    @ObservationIgnored private var siblingAnnounced: Set<ServerID> = []

    /// Reads the other libraries ticked under Quick Switch into their own indexes, without
    /// switching to them.
    func syncOtherQuickLibraries() {
        // A walk of a whole library is hundreds of requests: not over a
        // connection that costs, and not on a battery that is being spared.
        guard siblingSyncTask == nil, !settings.offlineMode, network.isSatisfied,
              !network.isExpensive, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              let config = servers.activeServer, config.kind == .plex,
              let token = servers.plexToken(for: config.id)
        else { return }
        let baseURL = endpointControl?.current ?? config.addresses.preferred
        let wanted = siblingSelections().filter { sibling in
            if let failed = siblingFailures[sibling.id],
               Date().timeIntervalSince(failed) < Self.automaticSyncInterval { return false }
            return siblingNeedsSync(sibling.id)
        }
        guard !wanted.isEmpty else { return }
        siblingSyncGeneration &+= 1
        let generation = siblingSyncGeneration
        siblingSyncTask = Task { [weak self] in
            for sibling in wanted {
                guard let self, !Task.isCancelled else { break }
                await self.syncSibling(sibling, baseURL: baseURL, token: token)
            }
            guard let self, siblingSyncGeneration == generation else { return }
            siblingSyncTask = nil
        }
    }

    private func siblingNeedsSync(_ id: ServerID) -> Bool {
        guard let index = siblingIndexes[id] ?? openIndexFile(for: id) else { return false }
        siblingIndexes[id] = index
        guard let last = (try? index.lastSyncAt()) ?? nil else { return true }
        return Date().timeIntervalSince(last) >= Self.automaticSyncInterval
    }

    private func syncSibling(
        _ sibling: (id: ServerID, selection: LibrarySelection, config: ServerConfig),
        baseURL: URL,
        token: String
    ) async {
        guard let index = siblingIndexes[sibling.id] else { return }
        noteStorageInUse(sibling.id, forServer: sibling.config.id)
        let transport = ServerHTTPTransport(
            config: sibling.config,
            resourceTimeout: Self.apiResourceTimeout,
            proxySessions: proxySessions,
            suspension: suspension
        )
        defer { transport.close() }
        let plex = PlexProvider(
            serverID: sibling.id,
            config: PlexServerConfig(
                baseURL: baseURL,
                token: token,
                sectionKey: sibling.selection.key,
                sectionTitle: sibling.selection.title,
                machineIdentifier: sibling.selection.machineIdentifier
            ),
            identity: PlexInstallation.identity,
            transport: transport
        )
        plex.setBaseURL(baseURL)
        let firstTime = ((try? index.lastSyncAt()) ?? nil) == nil
        let announce = firstTime && siblingAnnounced.insert(sibling.id).inserted
        if announce { showNote("Reading \(sibling.selection.title) so search can find it…") }
        do {
            let summary = try await LibrarySyncEngine(provider: plex, index: index).fullSync(force: false) { _ in }
            siblingFailures[sibling.id] = nil
            if summary.outcome == .walked {
                settings.markIndexMapped(Self.indexMappingVersion, for: sibling.id)
            }
            if announce, summary.outcome == .walked { showNote("\(sibling.selection.title) is ready to search") }
            // Only when rows moved: some twenty screens reload on this.
            if summary.outcome != .unchanged { bumpLibraryVersion() }
        } catch {
            if !(error is CancellationError) { siblingFailures[sibling.id] = Date() }
            TranscodeLog.record("reading \(sibling.selection.title) in the background failed: \(error.localizedDescription)")
        }
    }

    /// The index of one of the other Quick Switch libraries, if it has been
    /// opened before. Nil for a library that has never been, which has
    /// nothing to read and is not created empty to find out.
    private func siblingIndex(_ id: ServerID) -> LibraryIndex? {
        if let cached = siblingIndexes[id] { return cached }
        let url = Self.indexURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path),
              let opened = try? LibraryIndex(databaseURL: url, serverID: id)
        else { return nil }
        siblingIndexes[id] = opened
        return opened
    }

    /// The library a row's identity names, when it is one of the other Quick Switch libraries: what
    /// is needed to look something up there, and what to call it.
    func quickLibrary(named storage: ServerID) -> (index: LibraryIndex, title: String)? {
        guard let sibling = siblingSelections().first(where: { $0.id == storage }),
              let index = siblingIndex(sibling.id) else { return nil }
        return (index, sibling.selection.title)
    }

    /// The index a row's own library keeps: the open one's for its own rows, a sibling's for a
    /// record found through a search across libraries or kept in another library's downloads.
    func index(for server: ServerID) -> LibraryIndex? {
        if server == libraryIndex?.server { return libraryIndex }
        return quickLibrary(named: server)?.index ?? libraryIndex
    }

    // MARK: Downloads kept in another library

    /// A song downloaded while another of this server's libraries was open: the copy of its file,
    /// when there is one.
    func foreignDownloadFile(for id: MediaID) -> URL? {
        guard id.server != libraryIndex?.server else { return nil }
        // Asked a great many times a frame by lists and album pages, and each
        // answer is a database read and a look at the disk: remembered until
        // the library next changes.
        if let known = foreignFileCache[id] { return known }
        var found: URL?
        if let other = quickLibrary(named: id.server),
           let record = try? other.index.download(forTrack: id),
           record.state == .done {
            found = DownloadStore(lookingIn: id.server).existingFile(named: record.fileName)
        }
        foreignFileCache[id] = .some(found)
        return found
    }

    @ObservationIgnored private var foreignFileCache: [MediaID: URL?] = [:]

    /// What the other Quick Switch libraries have downloaded and finished,
    /// one entry per library that has anything.
    struct SiblingDownloads {
        let storage: ServerID
        let title: String
        let index: LibraryIndex
        var songs: [Track]
        var albums: [Album]
        var artists: [Artist]
    }

    /// - Parameter withSongs: false for a caller that wants only the albums
    ///   and artists (CarPlay): reading every song of every library to throw
    ///   the list away is the expensive part.
    func siblingDownloads(withSongs: Bool = true) -> [SiblingDownloads] {
        guard settings.mergesDownloads else { return [] }
        var found: [SiblingDownloads] = []
        for sibling in siblingSelections() {
            guard let index = siblingIndex(sibling.id),
                  let records = try? index.downloads()
            else { continue }
            let store = DownloadStore(lookingIn: sibling.id)
            var songs: [Track] = []
            var hasAny = false
            for record in records where record.state == .done {
                guard store.existingFile(named: record.fileName) != nil else { continue }
                hasAny = true
                guard withSongs else { break }
                let id = MediaID(server: sibling.id, rawValue: record.trackId)
                if let track = (try? index.track(id: id)) ?? record.rememberedTrack(server: sibling.id) {
                    songs.append(track)
                }
            }
            if hasAny {
                let deliberate = DownloadManager.deliberate(in: index)
                found.append(SiblingDownloads(
                    storage: sibling.id, title: sibling.selection.title, index: index,
                    songs: songs, albums: deliberate.albums, artists: deliberate.artists))
            }
        }
        return found
    }

    /// The albums and artists on the phone because they were asked for, the open library's and —
    /// with "Merge downloads from all libraries" on — the other Quick Switch libraries', each
    /// listed once.
    func downloadedShelves(including siblings: [SiblingDownloads]? = nil) -> (albums: [Album], artists: [Artist]) {
        let own = downloads?.deliberate()
        var albums = own?.albums ?? []
        var artists = own?.artists ?? []
        for other in siblings ?? siblingDownloads(withSongs: false) {
            albums += other.albums
            artists += other.artists
        }
        var seenAlbums: Set<String> = []
        var seenArtists: Set<String> = []
        return (
            albums.filter { seenAlbums.insert($0.id.rawValue).inserted },
            artists.filter { seenArtists.insert($0.id.rawValue).inserted }
        )
    }

    /// Takes back songs whose downloads belong to another library: the file
    /// and the row that names it. Only that library's own manager could do it
    /// properly, and it is not running; its table is read afresh when it is.
    func removeForeignDownloads(_ ids: [MediaID], outright: Bool = false) {
        for id in ids where id.server != libraryIndex?.server {
            guard let other = quickLibrary(named: id.server),
                  var record = try? other.index.download(forTrack: id)
            else { continue }
            // A record or an artist being let go takes only its own claim on a song; one still kept
            // for a playlist, or on its own, stays — as `DownloadManager.removeAlbum` does for its
            // own library.
            if !outright {
                let left = record.reasons.filter { !$0.hasPrefix("album:") && !$0.hasPrefix("artist:") }
                if !left.isEmpty {
                    record.setReasons(left)
                    try? other.index.saveDownload(record)
                    continue
                }
            }
            if let name = record.fileName { DownloadStore(lookingIn: id.server).remove(named: name) }
            try? other.index.deleteDownload(forTrack: id)
        }
        bumpLibraryVersion()
    }

    /// Every other Quick Switch library that has been opened before.
    func otherQuickLibraryIndexes() -> [(index: LibraryIndex, title: String)] {
        siblingSelections().compactMap { sibling in
            siblingIndex(sibling.id).map { ($0, sibling.selection.title) }
        }
    }

    /// Searches every other Quick Switch library that has been opened before, when the setting asks
    /// for it — the results are added after the active library's own, in the order Quick Switch
    /// lists them.
    func searchOtherQuickLibraries(_ query: String, limit: Int) async -> SearchResults {
        guard settings.searchesAllQuickLibraries, !isOffline else { return SearchResults() }
        var indexes: [LibraryIndex] = []
        for sibling in siblingSelections() {
            if let index = siblingIndex(sibling.id) { indexes.append(index) }
        }
        guard !indexes.isEmpty else { return SearchResults() }
        let offline = isOffline
        let answers = await withTaskGroup(of: (Int, SearchResults).self) { group in
            for (position, index) in indexes.enumerated() {
                group.addTask {
                    (position, (try? index.search(query, limit: limit, downloadedOnly: offline)) ?? SearchResults())
                }
            }
            var all: [(Int, SearchResults)] = []
            for await answer in group { all.append(answer) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var merged = SearchResults()
        for answer in answers {
            merged.artists += answer.artists
            merged.albums += answer.albums
            merged.tracks += answer.tracks
        }
        return merged
    }

    /// Remembers a rating set on this device so rows drawn from a list read
    /// earlier show it straight away. See `ratedLocally`.
    func noteRated(_ rating: StarRating?, id: MediaID) {
        ratedLocally[id] = .some(rating)
    }

    /// Where small writes to the index are made from, one at a time and in the
    /// order they were asked, so a tap does not make the main thread wait for the
    /// database. See `MediaActions.setRating`.
    let indexWriter = IndexWriter()

    /// Signals index-backed views to re-read after a local change.
    func bumpLibraryVersion() {
        libraryVersion += 1
    }

    /// Re-reads whether the library has anything in it. Called wherever the
    /// index is replaced or filled.
    /// - Parameter counted: stats already in hand, where the caller has them.
    private func noteLibraryEmptiness(_ counted: LibraryIndex.Stats? = nil) {
        guard let libraryIndex else {
            guessLibraryEmptiness()
            return
        }
        // A stats read that fails is not grounds for declaring the library
        // empty and holding someone on the setting-up screen.
        libraryIsEmpty = (counted ?? (try? libraryIndex.stats()))?.isEmpty ?? false
    }

    /// The answer from the file system alone, before any index is opened or any server reached.
    private func guessLibraryEmptiness() {
        guard let config = servers.activeServer else {
            libraryIsEmpty = nil
            return
        }
        let storage = Self.storageID(for: config)
        if openLibrary == storage, libraryIndex != nil { return }
        let url = Self.indexURL(for: storage)
        libraryIsEmpty = !FileManager.default.fileExists(atPath: url.path)
    }

    /// The provider, but only while it is the one for the library that is active now.
    var providerForActiveLibrary: (any MusicServerProvider)? {
        guard let provider, let config = servers.activeServer,
              provider.serverID == Self.storageID(for: config)
        else { return nil }
        return provider
    }

    /// What the active server will be able to do, before it has answered.
    var expectedCapabilities: ServerCapabilities {
        if let provider = providerForActiveLibrary { return provider.capabilities }
        switch servers.activeServer?.kind {
        case .plex: return PlexProvider.expectedCapabilities
        case .subsonic: return SubsonicProvider.baseCapabilities
        case nil: return []
        }
    }

    /// Changes whenever the active connection changes, retriggering loads.
    var connectionKey: String {
        switch connection {
        case .connected:
            "connected-\(servers.activeServerID?.rawValue.uuidString ?? "")"
        case .idle:
            "idle"
        case .connecting:
            "connecting"
        case .failed:
            "failed"
        }
    }

    func reportTransientError(_ error: any Error) {
        showTransientError((error as? ProviderError)?.errorDescription ?? error.localizedDescription)
    }

    /// Bumped per request, so a repeat of the same destination still counts
    /// as a new one — and so the task acting on it is not keyed to a value it
    /// clears itself.
    private(set) var navigationToken = 0

    func requestNavigation(_ request: NavigationRequest) {
        navigationToken += 1
        pendingNavigation = request
    }

    /// A destination with its record already fetched.
    enum ResolvedDestination {
        case album(Album)
        case artist(Artist)
    }

    /// Resolves a requested destination into a full record, so the page opens with its artwork
    /// rather than filling in later.
    func resolveNavigation(_ request: NavigationRequest) async -> ResolvedDestination? {
        switch request {
        case .album(let id, let name):
            if let indexed = try? libraryIndex?.albumDetail(id: id)?.album {
                return .album(indexed)
            }
            if let fetched = try? await provider?.album(id: id).album {
                return .album(fetched)
            }
            return name.map { .album(Album(id: id, name: $0)) }
        case .artist(let id, let name):
            if let indexed = try? libraryIndex?.artist(id: id) {
                return .artist(indexed)
            }
            if let fetched = try? await provider?.artist(id: id).artist {
                return .artist(fetched)
            }
            // The name the caller had is enough for the page to open and
            // resolve the rest itself.
            return name.map { .artist(Artist(id: id, name: $0)) }
        }
    }

    func requestAddToCollection(_ addition: CollectionAddition) {
        pendingCollectionAddition = addition
    }

    /// Fetches the songs of any playlist a filter asks about by name.
    private static let playlistsResolvedAtOnce = 3
    private static let membershipPassLimit = 200

    /// Playlists whose songs were fetched but could not be saved, so asking
    /// again this session would only fetch them again to fail the same way.
    /// Kept for the library they were seen in and dropped with it.
    private var membershipSaveFailures: (library: ServerID, ids: Set<String>)?

    @discardableResult
    func fillPlaylistMembership(askedBy filter: LibraryFilter) async -> Bool {
        guard let index = libraryIndex, let provider, !isOffline else { return false }
        if membershipSaveFailures?.library != index.server { membershipSaveFailures = nil }
        var learned = false
        var budget = Self.playlistsResolvedAtOnce
        for text in filter.playlistNamesAskedAbout {
            guard let everyOwed = try? index.playlistsAwaitingMembers(matching: text) else { continue }
            let owed = everyOwed.filter { !(membershipSaveFailures?.ids.contains($0.id) ?? false) }
            // Capped.
            for playlist in owed.prefix(budget) {
                // A rule is asked again on every keystroke, and the request this one replaced is
                // not owed any more work: without this an abandoned prefix goes on fetching, and
                // each playlist it reaches is stamped as fetched on the way past.
                if Task.isCancelled { return learned }
                let id = MediaID(server: index.server, rawValue: playlist.id)
                guard let detail = try? await provider.playlist(id: id) else { continue }
                do {
                    try index.saveMembers(
                        ofPlaylist: playlist.id,
                        trackIds: detail.entries.map(\.track.id.rawValue)
                    )
                } catch {
                    // Nothing was stamped as fetched, so nothing was learned:
                    // reporting it as learned sent every caller round again,
                    // and the playlist was still owed each time.
                    var failures = membershipSaveFailures ?? (index.server, [])
                    failures.ids.insert(playlist.id)
                    membershipSaveFailures = failures
                    continue
                }
                learned = true
                budget -= 1
                if budget == 0 { return learned }
            }
        }
        return learned
    }

    /// Fetches the songs of every playlist the saved shelves ask about.
    func fillPlaylistMembershipForShelves() async {
        var learned = false
        for filter in customSections.sections.map(\.filter)
        where !filter.playlistNamesAskedAbout.isEmpty {
            // Bounded as well: each pass resolves a few playlists, so this is
            // many times more than a library has owing, and a pass that
            // somehow kept finding something new still ends.
            var passes = 0
            while passes < Self.membershipPassLimit, await fillPlaylistMembership(askedBy: filter) {
                passes += 1
                learned = true
                if Task.isCancelled { break }
            }
            if Task.isCancelled { break }
        }
        // Once, at the end. Twenty-odd screens re-read on this, and a shelf
        // filling three playlists at a time does not need to redraw them all
        // fifteen times over.
        if learned { bumpLibraryVersion() }
    }

    /// Whether `id` names one of the stand-in tracks a controlled device's mirrored player shows
    /// while its library is not confirmed to be this one's (`PlaybackControlling.canActOnLibrary`).
    func isForeignTrack(_ id: MediaID) -> Bool {
        let active = activePlayer
        guard !active.canActOnLibrary else { return false }
        return active.currentTrack?.id == id
            || active.queue.contains { $0.track.id == id }
            || active.history.contains { $0.track.id == id }
    }

    /// The DJ works on this device's own queue, which is hidden while another device is being
    /// controlled — turning one on would rewrite a queue the person cannot see and nothing on the
    /// other device would change (remote-21).
    static let djUnavailableNote = "The DJ isn't available on another device yet."

    /// Runs `open` (the DJ sheet) unless another device is being controlled.
    func openDJ(_ open: () -> Void) {
        guard !remote.isControlling else {
            showNote(Self.djUnavailableNote)
            return
        }
        open()
    }

    /// What is said when a write is refused for that reason.
    static let foreignTrackNote = "Ratings, favourites and playlists aren't available for songs on another device until its library is confirmed to be the same as this one."

    func requestAddToPlaylist(_ tracks: [Track], suggesting name: String? = nil) {
        guard !tracks.isEmpty else { return }
        guard !tracks.contains(where: { isForeignTrack($0.id) }) else {
            showNote(Self.foreignTrackNote)
            return
        }
        pendingPlaylistAddition = PlaylistAddition(tracks: tracks, suggestedName: name)
    }

    /// The last few things that went wrong, newest first.
    private(set) var recentProblems: [Problem] = []

    struct Problem: Identifiable, Hashable {
        let id = UUID()
        let at: Date
        let message: String
        /// The `transcode` log lines leading up to this failure, oldest
        /// first — empty unless this came from playback. So a copy carries
        /// the story, not just the ending.
        var context: [String] = []
    }

    private static let problemsKept = 25

    func showTransientError(_ message: String, context: [String] = []) {
        recentProblems.insert(Problem(at: Date(), message: message, context: context), at: 0)
        if recentProblems.count > Self.problemsKept { recentProblems.removeLast() }
        show(message)
    }

    /// Says what just happened, without calling it a problem.
    func showNote(_ message: String) {
        show(message)
    }

    private func show(_ message: String) {
        transientError = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            // Only if nothing has been said since: a later message must not
            // be wiped by an earlier one's timer.
            if transientError == message { transientError = nil }
        }
    }

    /// Builds the right provider for a server.
    private var openLibrary: ServerID?

    /// Opens the active library's own file and points everything filed per library at it — the
    /// index, the pins, the play log, the home shelves.
    @discardableResult
    func openLocalLibrary() -> Bool {
        guard let config = servers.activeServer else { return false }
        // Everything cached is keyed by server *and* library.
        let storage = Self.storageID(for: config)
        // Same library, already open: nothing to do. But if the last attempt
        // at this same storage failed, `libraryIndex` is nil and this must
        // fall through and retry rather than report the old failure forever.
        guard storage != openLibrary || libraryIndex == nil else { return true }
        // A sync fills the index it was started on.
        if storage != openLibrary { standDownRunningSync() }
        // A library being read in the background for search is about to be
        // opened as the active one; two writers on one file is not wanted.
        siblingSyncTask?.cancel()
        siblingSyncTask = nil
        siblingSyncGeneration &+= 1
        openLibrary = storage
        siblingIndexes.removeValue(forKey: storage)
        libraryIndex = openIndexFile(for: storage)
        noteLibraryEmptiness()
        // A settings backup restored onto this install sets each library's
        // Home aside under what names the library; this is the library it
        // was for connecting. Before anything below reads its keys.
        let fingerprint = libraryFingerprint(for: config)
        SettingsBackup.adoptPending(
            into: .standard, scope: storage.rawValue.uuidString, fingerprint: fingerprint
        )
        // What is pinned belongs to the library it was pinned from: a playlist of eighties pop is
        // not on the shelf of a Christmas library, and a record pinned there does not exist here.
        songList.clear()
        albumList.clear()
        artistList.clear()
        pins.use(library: storage)
        playLog.use(library: storage)
        // Anything the watch reported before there was a library to file it against.
        let waiting = pendingWatchPlays
        pendingWatchPlays = []
        for play in waiting { recordFromWatch(play.source, at: play.date) }
        playlistTopPins.use(library: storage)
        customSections.use(library: storage)
        settings.useForHome(library: storage)
        // Which library Home is arranged for, so the arrangement can be backed up without the UUID
        // it is filed under — that UUID is minted fresh on every install, and a copy of it would
        // restore a key nothing ever reads.
        settingsBackup.libraryScope = storage.rawValue.uuidString
        settingsBackup.libraryFingerprint = fingerprint
        settingsBackup.record()
        placeOrphanedCustomSections()
        return libraryIndex != nil
    }

    /// What names this library across installs, for the settings backup. The
    /// account is part of it for a Subsonic server: two accounts on one
    /// server have libraries of their own.
    private func libraryFingerprint(for config: ServerConfig) -> String? {
        var username: String?
        if case .usernamePassword(let name, _)? = servers.credentials(for: config.id) { username = name }
        return LibraryFingerprint.of(config: config, username: username)
    }

    /// Points what is on screen at the Home arrangement a restore by hand has
    /// just written. The rest of the restored settings are read once at
    /// launch and take effect then.
    func homeRestoredFromBackup() {
        playLog.reload()
        customSections.reload()
        settings.reloadHome()
    }

    /// Opens a library's index file.
    private func openIndexFile(for storage: ServerID) -> LibraryIndex? {
        do {
            switch try LibraryIndexOpening.open(databaseURL: Self.indexURL(for: storage), serverID: storage) {
            case .opened(let index):
                return index
            case .rebuilt(let index, let quarantined):
                showTransientError(
                    String(localized: "This library's file on the phone was damaged, so it is being read from the server again. Downloaded songs may need to be fetched again."),
                    context: ["The damaged file was kept as \(quarantined.lastPathComponent)"]
                )
                return index
            }
        } catch {
            TranscodeLog.record("library index would not open: \(error.localizedDescription)")
            return nil
        }
    }

    /// What `buildProvider` hands back: the provider, and the means to move it to another address.
    private struct BuiltProvider {
        let provider: any MusicServerProvider
        let endpoint: EndpointControl
    }

    /// The longest a single API request may take from start to finish.
    private static let apiResourceTimeout: TimeInterval = 120

    private func buildProvider(
        for config: ServerConfig,
        generation: Int,
        transports: StackTransports
    ) async -> BuiltProvider? {
        connection = .connecting
        // A previously captured proxy session, if this server sits behind one.
        proxySessions.set(servers.proxySession(for: config.id))
        let transport = transports.track(ServerHTTPTransport(
            config: config,
            resourceTimeout: Self.apiResourceTimeout,
            proxySessions: proxySessions,
            suspension: suspension
        ))

        switch config.kind {
        case .subsonic:
            guard let credentials = servers.credentials(for: config.id) else { return nil }
            // Subsonic has one library, so its storage identity is the
            // entry's own — but it is derived the same way, so the two can
            // never drift apart.
            let subsonic = SubsonicProvider(
                config: config,
                credentials: credentials,
                customHeaders: servers.headerValues(for: config),
                transport: transport,
                // Straight from the client's own context: the record is kept in memory and the
                // Keychain is only touched when it would change, so there is no reason left to hop
                // to the main actor for every call.
                onAuthOutcome: { [health = remote.credentialHealth] outcome in
                    health.record(outcome, for: config.id)
                }
            )
            // Home/remote selection by reachability; credentials are never
            // sent while probing.
            let selector = transports.track(EndpointSelector(config: config))
            // Not probed while Offline Mode is on: it means leave the network
            // alone. The first refresh after it goes off chooses properly.
            let url = settings.offlineMode ? config.addresses.preferred : await selector.activeBaseURL()
            await subsonic.setBaseURL(url)
            return BuiltProvider(
                provider: subsonic,
                endpoint: EndpointControl(selector: selector, current: url) { await subsonic.setBaseURL($0) }
            )

        case .plex:
            guard let token = servers.plexToken(for: config.id),
                  let library = config.library
            else { return nil }
            let plex = PlexProvider(
                // The *storage* identity, not the entry's: a `MediaID` carries the server it came
                // from, and the index stamps every row with this same value.
                serverID: Self.storageID(for: config),
                config: PlexServerConfig(
                    baseURL: config.addresses.preferred,
                    token: token,
                    sectionKey: library.key,
                    sectionTitle: library.title,
                    machineIdentifier: library.machineIdentifier
                ),
                identity: PlexInstallation.identity,
                transport: transport
            )
            let selector = transports.track(EndpointSelector(config: config))
            let chosen = settings.offlineMode ? config.addresses.preferred : await selector.activeBaseURL()
            plex.setBaseURL(chosen)
            let control = EndpointControl(selector: selector, current: chosen) { plex.setBaseURL($0) }
            // The stored local address did not answer.
            if !settings.offlineMode,
               await selector.lastChoice?.isLocal == false,
               config.addresses.local != nil,
               runs.isCurrent(generation) {
                recoveries += 1
                Task { [weak self] in
                    guard let self else { return }
                    defer { self.recoveries -= 1 }
                    guard await self.betterLocalAddress(for: config) != nil else { return }
                    // The repair moved the stored address, and told nobody else: the controller
                    // kept its selector on the addresses it was built with, so away from home it
                    // went on choosing the repaired LAN address for a provider that no longer used
                    // it, and…
                    guard generation == self.providerGeneration,
                          self.servers.activeServerID == config.id,
                          let repaired = self.servers.servers.first(where: { $0.id == config.id })
                    else { return }
                    let fresh = transports.track(EndpointSelector(config: repaired))
                    let url = await fresh.activeBaseURL()
                    guard generation == self.providerGeneration else {
                        await fresh.close()
                        return
                    }
                    plex.setBaseURL(url)
                    let outgoing = control.selector
                    control.selector = fresh
                    control.current = url
                    await outgoing.close()
                    // The address was the thing that was wrong and it is now right, but the
                    // connection was tested against the old one.
                    await self.retestIfFailed(plex, for: config, generation: generation)
                }
            }
            return BuiltProvider(provider: plex, endpoint: control)
        }
    }

    /// Tests again on an address that has just been repaired, when the last attempt failed on the
    /// old one.
    private func retestIfFailed(
        _ provider: any MusicServerProvider,
        for config: ServerConfig,
        generation: Int
    ) async {
        guard stillCurrent(config, generation) else { return }
        // Taken here, before the test rather than after it: this attempt is the one the repair was
        // worth, spent the moment it is used whether or not the test itself succeeds.
        addressRepaired.remove(config.id)
        guard let info = try? await provider.testConnection() else { return }
        guard stillCurrent(config, generation) else { return }
        markConnected(info, generation: generation)
    }

    /// Whether an answer worked out a moment ago is still about the stack
    /// that is running now — the same server, the same build of it, and the
    /// network still something this app is willing to touch.
    private func stillCurrent(_ config: ServerConfig, _ generation: Int) -> Bool {
        connection.isFailed
            && generation == providerGeneration
            && servers.activeServerID == config.id
            && !settings.offlineMode
    }

    /// How many attempts to put a failed connection right are in flight.
    private var recoveries = 0

    /// Whether the app is still working on a connection that has failed.
    var isRecovering: Bool { recoveries > 0 }

    /// Counts rebuilds of the provider stack. A repair that finishes after
    /// its own stack has been replaced — a second `connectActive`, a library
    /// switched in Settings — must not publish a verdict about it.
    private var providerGeneration: Int { runs.generation }

    /// The bookkeeping for overlapping runs of `connectActive()` and for
    /// which library the published stack belongs to.
    private var runs = ConnectionRuns()

    /// Servers whose stored address this launch has actually rewritten, and
    /// which are therefore worth one more attempt. Consumed when it is taken,
    /// so a server that keeps failing is not retried round and round.
    private var addressRepaired: Set<ServerID> = []

    /// Servers this launch has already asked Plex about, so a phone that is
    /// genuinely away from home asks once and then leaves it alone.
    private var addressRepairsTried: Set<ServerID> = []

    /// The same, for the remote address.
    private var remoteRepairsTried: Set<ServerID> = []

    /// Finds a local address that works, when the stored one does not.
    private func betterLocalAddress(for config: ServerConfig) async -> URL? {
        guard !addressRepairsTried.contains(config.id) else { return nil }
        guard let token = servers.plexToken(for: config.id),
              let library = config.library
        else { return nil }

        // Latched before the round trip below, and given back if that round trip turns out not to
        // be an answer.
        addressRepairsTried.insert(config.id)

        let client = PlexClient(identity: PlexInstallation.identity)
        guard let resources = try? await client.servers(token: token),
              let resource = resources.first(where: {
                  $0.clientIdentifier == library.machineIdentifier
              })
        else {
            // plex.tv could not be reached, or has not heard of this server.
            addressRepairsTried.remove(config.id)
            return nil
        }

        // Everything except the address that has just failed.
        let alreadyFailed = config.addresses.probeOrder?.first ?? config.addresses.local
        let untried = resource.connectionsInPreferenceOrder
            .filter(\.isLocal)
            .map(\.uri)
            .filter { $0 != alreadyFailed }
        guard !untried.isEmpty else { return nil }

        // The token goes out on this server's own transport: its pins, and its refusal to follow a
        // redirect off the host.
        guard let (url, _) = try? await client.firstReachableLibrary(
            among: untried.map { PlexResource.Connection(uri: $0, isLocal: true, isRelay: false) },
            token: resource.accessToken ?? token,
            transport: ServerHTTPTransport(
                config: config,
                timeout: PlexClient.setupTimeout,
                proxySessions: proxySessions,
                suspension: suspension
            )
        ) else { return nil }

        servers.setLocalAddress(url, for: config.id)
        // Remembered as well as returned.
        addressRepaired.insert(config.id)
        return url
    }

    /// Finds a public address that works, when the stored remote one does not.
    private func betterRemoteAddress(for config: ServerConfig) async -> URL? {
        guard !remoteRepairsTried.contains(config.id) else { return nil }
        guard let token = servers.plexToken(for: config.id),
              let library = config.library,
              let stored = config.addresses.remote
        else { return nil }
        // Latched before the round trip, as `betterLocalAddress` does, and
        // given back if plex.tv was not reached.
        remoteRepairsTried.insert(config.id)

        let client = PlexClient(identity: PlexInstallation.identity)
        guard let resources = try? await client.servers(token: token),
              let resource = resources.first(where: {
                  $0.clientIdentifier == library.machineIdentifier
              })
        else {
            remoteRepairsTried.remove(config.id)
            return nil
        }
        let others = resource.connectionsInPreferenceOrder.filter { !$0.isLocal && $0.uri != stored }
        guard !others.isEmpty else { return nil }
        let storedFirst = PlexResource.Connection(uri: stored, isLocal: false, isRelay: false)

        guard let (url, _) = try? await client.firstReachableLibrary(
            among: [storedFirst] + others,
            token: resource.accessToken ?? token,
            transport: settingsTransport(for: config)
        ), url != stored else { return nil }

        servers.setRemoteAddress(url, for: config.id)
        return url
    }

    // MARK: - The watch

    /// Provisions the watch, if there is one.
    func forgetServerOnWatch(_ id: ServerID) {
        // Named, because the watch cannot work out which of its libraries
        // belonged to the server that went: a Plex server is one entry with
        // several libraries, each filed under its own storage identity.
        let storage = servers.servers.first(where: { $0.id == id })
            .map { knownStorageIDs(of: $0) } ?? []
        watch.forgetServer(id, storage: storage)
    }

    func provisionWatch() {
        watch.sendProvisioning()
        if let id = servers.activeServerID { watch.sendSecrets(for: id) }
        // Called once the index is open, which is the first moment a library
        // can actually be sent — the session activated long before this, back
        // when there was nothing to hand over.
        if watch.owesLibrary { watch.sendLibrary(force: true) }
    }

    /// What the library looked like, for deciding whether the watch needs it again.
    private static func libraryStamp(_ stats: LibraryIndex.Stats) -> String {
        "\(stats.artistCount)/\(stats.albumCount)/\(stats.trackCount)"
    }

    /// Sends the library across when it has actually changed since last time.
    func offerLibraryToWatch(stamp: String?) {
        watch.sendProvisioning()
        guard let stamp, watch.libraryChanged(stamp: stamp) else { return }
        // The stamp travels with the send and is recorded by whoever
        // completes it, rather than here — see `sendLibrary(force:stamp:)`.
        watch.sendLibrary(stamp: stamp)
    }

    /// Everything the watch needs to know that is not a secret.
    /// Nil while the server list is unread, so nothing is sent: an empty
    /// provisioning is how the watch is told the server has been removed.
    private func watchProvisioning() -> WatchLink.Provisioning? {
        guard servers.isLoaded else { return nil }
        guard let config = servers.activeServer else { return WatchLink.Provisioning() }
        return WatchLink.Provisioning(
            config: config,
            storageID: Self.storageID(for: config),
            // The watch has to present the identifier the Plex token was
            // granted to; one of its own would be a different client.
            plexClientIdentifier: config.kind == .plex ? PlexInstallation.identity.clientIdentifier : nil,
            playLog: playLog.entries,
            librarySentAt: watch.librarySentAt
        )
    }

    private func watchSecrets(for id: ServerID) -> WatchLink.Secrets? {
        guard let config = servers.servers.first(where: { $0.id == id }) else { return nil }
        return WatchLink.Secrets(
            serverID: id,
            subsonicCredentials: try? servers.credentials(for: id)?.encoded(),
            plexToken: servers.plexToken(for: id),
            headerValues: servers.headerValues(for: config),
            proxySession: servers.proxySession(for: id).flatMap { try? JSONEncoder().encode($0) }
        )
    }

    /// Both of these moved to `LibraryStorage` in Shared, where the watch app can reach them: it
    /// has to file the copy of the library it is sent under the name this phone would have used.
    private static func storageID(for config: ServerConfig) -> ServerID {
        LibraryStorage.id(for: config)
    }

    private static func indexURL(for id: ServerID) -> URL {
        LibraryStorage.indexURL(for: id)
    }
}


/// Runs small pieces of work against the library index off the main thread, in
/// the order they arrive.
actor IndexWriter {
    func perform<T: Sendable>(_ work: @Sendable () -> T) -> T { work() }
}
