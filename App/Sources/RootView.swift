import SwiftUI
import PleviDomain

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var showNowPlaying = false
    /// How far the player travels to leave the screen, worked out from the
    /// card itself. The going-out transition below cannot ask the
    /// card, so it reads the last answer from here.
    @State private var playerTravel: CGFloat = 1200
    /// Whether the offline line has been put away for this stretch of being
    /// offline — see `OfflineBanner`.
    @State private var offlineBannerDismissed = false
    @State private var selection: TabIdentifier = .home
    /// What is typed into the search field.
    @State private var searchQuery = ""
    @State private var showSleepTimer = false

    // Navigation paths live here rather than inside each tab.
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var playlistsPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    enum TabIdentifier: Hashable {
        case home
        case library
        case playlists
        case downloads
        case search
    }

    /// Set by "Skip for now", so the wait is never a trap.
    @State private var skippedFirstSync = false
    /// A server is set up but its library has not arrived yet.
    private var isFirstRun: Bool {
        // Not while something is playing: swapping the whole tab tree for
        // this screen would take the player out from under it.
        app.libraryIsEmpty == true && !skippedFirstSync && !app.settings.offlineMode
            && app.activePlayer.currentTrack == nil
    }

    /// Whether there is anything for the mini player and the full card to show:
    /// a song, or a connection to another device that has not given one yet.
    private var hasPlayback: Bool {
        app.activePlayer.currentTrack != nil || app.remote.isControlling || app.remote.isConnecting
    }

    /// Whether the offline line sits above the tabs rather than in the top safe area.
    private var offlineBannerAboveTabs: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && app.remote.controllingNames.isEmpty
            && app.isOffline && !offlineBannerDismissed
    }

    /// The tabs, with the offline line above them on an iPad. See
    /// `offlineBannerAboveTabs`.
    private var tabsBelowBanner: some View {
        VStack(spacing: 0) {
            if offlineBannerAboveTabs {
                OfflineBanner(isDismissed: $offlineBannerDismissed)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            tabsWithPlayer
        }
        .animation(.easeOut(duration: 0.2), value: offlineBannerAboveTabs)
    }

    var body: some View {
        Group {
            if app.servers.servers.isEmpty {
                WelcomeView()
            } else if isFirstRun {
                // A server has been added but nothing has arrived yet. The
                // tabs would be five empty rooms.
                FirstSyncView { skippedFirstSync = true }
            } else {
                tabsBelowBanner
                    // A layer of the app rather than something presented over it, so the bleeding
                    // artwork reaches the top edge of the screen.
                    .overlay {
                        if showNowPlaying {
                            // The player is grown to the full screen by arithmetic and put where it
                            // belongs by an offset — no `ignoresSafeArea` anywhere near it.
                            GeometryReader { box in
                                let insets = box.safeAreaInsets
                                NowPlayingView(
                                    onClose: { showNowPlaying = false },
                                    safeArea: insets
                                )
                                .frame(
                                    width: box.size.width + insets.leading + insets.trailing,
                                    height: box.size.height + insets.top + insets.bottom
                                )
                                // Reaching the screen's edges is done here, in layout, and *only*
                                // here.
                                .padding(.top, -insets.top)
                                .padding(.leading, -insets.leading)
                                // Arrives as one piece, by an offset of its own rather than by the
                                // transition below.
                                .modifier(RisesFromBelow(distance: box.size.height + insets.top + insets.bottom))
                                .onChange(of: box.size.height + insets.top + insets.bottom, initial: true) { _, height in
                                    // A fifth past the card's own height, so the slow last stretch
                                    // of the ease-out is spent off screen instead of showing a
                                    // strip of the card sliding the final few points.
                                    playerTravel = height * 1.2
                                }
                            }
                                // Different going out from coming in, because the two are not the
                                // same job.
                                .transition(
                                    .asymmetric(
                                        // Nothing: `RisesFromBelow` does the
                                        // arriving, so it can take everything
                                        // in the card with it.
                                        insertion: .identity,
                                        // Measured from the card rather than a fixed 1200, which
                                        // stops 176 points short of clearing a 13-inch iPad held
                                        // upright — 1376 points tall.
                                        removal: .offset(y: playerTravel)
                                            .animation(.easeOut(duration: 0.26))
                                    )
                                )
                        }
                    }
                    .sheet(isPresented: $showSleepTimer) {
                        SleepTimerView()
                    }
                    // An expired proxy session is explained before anything
                    // is put on screen: a login page appearing by itself is
                    // indistinguishable from the app misbehaving.
                    .alert(
                        "Sign-in expired",
                        isPresented: Binding(
                            get: { app.expiredProxySignIn != nil },
                            set: { if !$0 { app.expiredProxySignIn = nil } }
                        ),
                        presenting: app.expiredProxySignIn
                    ) { request in
                        Button("Sign In") {
                            app.expiredProxySignIn = nil
                            app.pendingProxySignIn = request
                        }
                        Button("Later", role: .cancel) {
                            app.expiredProxySignIn = nil
                        }
                    } message: { request in
                        Text("Your sign-in to \(request.url.host() ?? "the server") has expired, so Plevi can't reach your music. Sign in again to carry on — you can also do this any time from Settings.")
                    }
                    // Raised whenever a request comes back as an SSO login
                    // page instead of the API.
                    .sheet(item: Binding(
                        get: { app.pendingProxySignIn },
                        set: { if $0 == nil { app.pendingProxySignIn = nil } }
                    )) { request in
                        ProxySignInView(config: request.config, url: request.url) { session in
                            app.adoptProxySession(session)
                        }
                    }
                    // Raised from a context menu anywhere in the app; only the
                    // root can present it.
                    .sheet(item: Binding(
                        get: { app.pendingPlaylistAddition },
                        set: { if $0 == nil { app.pendingPlaylistAddition = nil } }
                    )) { addition in
                        AddToPlaylistView(
                            tracks: addition.tracks,
                            suggestedName: addition.suggestedName
                        )
                    }
                    .sheet(item: Binding(
                        get: { app.pendingCollectionAddition },
                        set: { if $0 == nil { app.pendingCollectionAddition = nil } }
                    )) { addition in
                        AddToCollectionView(
                            kind: addition.kind,
                            itemIDs: addition.itemIDs,
                            what: addition.what
                        )
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        // cannot be dismissed — it is the answer to "why
                        // did the music just change" — so, unlike OfflineBanner, no way out but
                        // Disconnect.
                        if !app.remote.controllingNames.isEmpty {
                            RemoteControlBanner(
                                controllerNames: app.remote.controllingNames,
                                onDisconnect: { app.remote.disconnectAllTargetSessions() }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        } else if app.isOffline, !offlineBannerDismissed,
                                  UIDevice.current.userInterfaceIdiom != .pad {
                            OfflineBanner(isDismissed: $offlineBannerDismissed)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    // Shown again the next time the connection goes, rather
                    // than staying hidden for good: the first time it says
                    // something you did not know.
                    .onChange(of: app.isOffline) { _, offline in
                        if !offline { offlineBannerDismissed = false }
                    }
                    // A pushed page belongs to the library it was opened in.
                    .onChange(of: app.libraryIndex?.server) { old, new in
                        // The very first index (launch) is not a switch.
                        guard old != nil else { return }
                        homePath = NavigationPath()
                        libraryPath = NavigationPath()
                        playlistsPath = NavigationPath()
                        searchPath = NavigationPath()
                        searchQuery = ""
                    }
                    // Below the status bar, not under it.
                    .overlay(alignment: .top) {
                        if let message = app.transientError {
                            Text(message)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                                .safeAreaPadding(.top, 4)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy, value: app.transientError)
                    // the target's own code-comparison prompt,
                    // presented from here so it covers whichever screen is actually up.
                    .overlay {
                        if let pending = app.remote.pendingCode {
                            ZStack {
                                Color.black.opacity(0.35).ignoresSafeArea()
                                RemoteAllowAlert(
                                    role: pending.role,
                                    // The target does not know who is asking
                                    // until after trust; the controller
                                    // knows who it dialled.
                                    deviceKind: pending.role == .target ? .phone : (app.remote.connectingDeviceKind ?? .pad),
                                    deviceName: pending.role == .target ? nil : app.remote.connectingDeviceObject,
                                    formattedCode: pending.formattedCode,
                                    onAllow: { pending.respond(true) },
                                    onDontAllow: { pending.respond(false) }
                                )
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.default, value: app.remote.pendingCode?.id)
                    // The player is a sheet and cannot push anything itself, so it hands
                    // destinations here to open on the tab underneath.
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIApplication.didReceiveMemoryWarningNotification
                        )
                    ) { _ in
                        app.songList.clear()
                        app.albumList.clear()
                        app.artistList.clear()
                    }
                    .task(id: app.navigationToken) {
                        guard let request = app.pendingNavigation else { return }
                        let token = app.navigationToken
                        await open(request, expecting: token)
                        // Guarded the same way `open` guards its own two effects: a superseded
                        // firing that is still running when a newer one lands must not clear the
                        // newer request out from under it.
                        if app.navigationToken == token { app.pendingNavigation = nil }
                    }
            }
        }
        // Disconnecting from a device that was playing leaves this one with
        // nothing: the mini player goes, and the full card is closed with it
        // rather than left open on an empty black page.
        .onChange(of: hasPlayback) { _, has in
            if !has && showNowPlaying { withAnimation { showNowPlaying = false } }
        }
        // How the window is held, for the album grids: an iPad fits more
        // across when it is on its side. The window's own shape rather than
        // the device's orientation, so a narrow split view counts as upright.
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: {
            app.settings.windowIsLandscape = $0
        }
        // Kept alive and in a live window for the whole app session, not just while some
        // remote-control screen happens to be on top — see `HardwareVolumeBridge`'s own header
        // (RemoteVolumeRow.swift) for why a view that came and went with a popover…
        .background {
            // Only while Remote Control wants it: see `needsVolumeView`.
            if app.remote.needsVolumeView {
                HardwareVolumeHost(bridge: app.remote.hardwareVolume, systemVolume: app.remote.systemVolume)
                    .frame(width: 1, height: 1)
                    .opacity(0.011)
                    .allowsHitTesting(false)
            }
        }
        // The app's own appearance, and only that.
        .windowAppearance(app.settings.theme)
        // Asked again whenever the library or the server changes: a finished first sync bumps
        // `libraryVersion`, which is what takes this screen away, and switching library brings it
        // back if that one is empty.
        .task(id: "\(app.servers.activeServerID?.rawValue.uuidString ?? "")|\(app.servers.activeServer?.library?.key ?? "")") {
            skippedFirstSync = false
        }
        // Set once at the top so every screen inherits it, rather than each
        // one remembering to. Anything that names its own colour — an accent
        // link, artwork-led type on an album page — still wins.
        .foregroundStyle(Color.ink)
        // Set once here rather than page by page: it reaches every scroll view below it, so a page
        // added later is covered without remembering to ask.
        .withoutBottomScrollEdgeBlur()
        .task {
            // Shared with the CarPlay scene, which may have started it
            // already — or may not exist at all.
            await app.bootIfNeeded()
        }
    }

    /// The accessory slot sits above the floating tab bar and merges into it as the bar minimises —
    /// a plain `safeAreaInset` lands on top of the bar instead.
    private var tabsWithPlayer: some View {
        tabs
            // The full-size sleeve, fetched while the mini player is still the only thing showing
            // it.
            .task(id: "\(app.activePlayer.currentTrack?.id.rawValue ?? "")|\(app.settings.progressStyle.rawValue)") {
                app.warmWaveform(for: app.activePlayer.currentTrack)
            }
            // Also keyed on the loader itself: a library switch builds a new
            // one with an empty memory, and the song playing on has not changed.
            .task(id: "\(app.activePlayer.currentTrack?.artwork?.rawValue ?? "")|\(app.artwork.map { ObjectIdentifier($0).hashValue } ?? 0)") {
                guard let artwork = app.activePlayer.currentTrack?.artwork,
                      let loader = app.artwork
                else { return }
                // Kept, not just fetched: see `ArtworkLoader.pin`.
                if let image = await loader.image(for: artwork, bucket: Self.playerSleeveBucket) {
                    loader.pin(image, for: artwork, bucket: Self.playerSleeveBucket)
                }
            }
            .tabViewBottomAccessory(isEnabled: hasPlayback) {
                MiniPlayerBar(
                    // Animated here, or the insertion below never runs at all: a transition is only
                    // played for a change that is animated, and this one was not.
                    onTap: { withAnimation { showNowPlaying = true } },
                    onShowSleepTimer: { showSleepTimer = true }
                )
            }
            .tabBarMinimizeBehavior(.onScrollDown)
    }

    /// The size both artwork-led player layouts ask for — the same number
    /// `holdForTheSleeve` waits on, and the reason this warms that bucket
    /// and not another.
    private static let playerSleeveBucket = 1200

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab("Home", systemImage: "house", value: TabIdentifier.home) {
                HomeView(path: $homePath)
            }
            Tab("Library", systemImage: "square.stack", value: TabIdentifier.library) {
                LibraryHubView(path: $libraryPath)
            }
            if app.settings.showsPlaylistsTab {
                Tab("Playlists", systemImage: "music.note.list", value: TabIdentifier.playlists) {
                    PlaylistsView(isRoot: true, path: $playlistsPath)
                }
            }
            if app.settings.showsDownloadsTab {
                Tab("Downloads", systemImage: "arrow.down.circle", value: TabIdentifier.downloads) {
                    DownloadsView()
                }
                // How many songs are still coming, on the tab you would go
                // to in order to find out. Zero draws nothing at all: a
                // badge that is always there stops being news.
                .badge(app.downloads?.activeCount ?? 0)
            }
            // The search role renders detached from the tab bar at a compact width — a standalone
            // button at the trailing end that expands into a search field.
            Tab(value: TabIdentifier.search, role: .search) {
                SearchView(query: $searchQuery, path: $searchPath)
                    // On the search tab, not on the tab view.
                    .searchable(
                        text: $searchQuery,
                        prompt: "Artists, playlists, albums, songs"
                    )
            }
        }
        // What carries the field from the tab up into the tab bar, and the half whose absence
        // looked like a broken tab: choosing the search tab is what opens and focuses the field.
        .tabViewSearchActivation(.searchTabSelection)
    }

    /// Pushes a destination onto whichever tab is showing, so leaving the player lands somewhere
    /// sensible rather than jumping tabs.
    private func open(_ request: AppModel.NavigationRequest, expecting token: Int) async {
        guard let destination = await app.resolveNavigation(request) else {
            guard app.navigationToken == token else { return }
            app.showTransientError("Couldn't open that from here.")
            return
        }
        guard app.navigationToken == token else { return }
        // Downloads has nothing to push onto; Library is the natural home.
        if selection == .downloads {
            selection = .library
        }
        switch destination {
        case .album(let album):
            activePath.wrappedValue.append(album)
        case .artist(let artist):
            activePath.wrappedValue.append(artist)
        }
    }

    /// The navigation path of whichever tab is showing.
    private var activePath: Binding<NavigationPath> {
        switch selection {
        case .home: $homePath
        case .library, .downloads: $libraryPath
        case .playlists: $playlistsPath
        case .search: $searchPath
        }
    }

    /// Reselecting a tab acts as "go back" and pops it to its root.
    private var tabSelection: Binding<TabIdentifier> {
        Binding(
            get: { selection },
            set: { newValue in
                // Search goes back to its root on the way *in*, not only on a reselect, and it is
                // the one tab that does.
                if newValue == .search, !searchPath.isEmpty {
                    searchPath = NavigationPath()
                }
                if newValue == selection {
                    switch newValue {
                    case .home:
                        homePath = NavigationPath()
                    case .library:
                        libraryPath = NavigationPath()
                    case .playlists:
                        playlistsPath = NavigationPath()
                    case .downloads, .search:
                        break
                    }
                }
                selection = newValue
            }
        )
    }
}

/// Wraps the songs awaiting a playlist choice so they can drive `sheet(item:)`.
/// Stands in until offline downloads ship, so the tab option is real rather
/// than a dead entry.
struct DownloadsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text("Offline downloads arrive in a later build. Until then this tab is a placeholder — you can hide it in Settings.")
            }
            .navigationTitle("Downloads")
        }
    }
}

/// Brings the full player up from below the screen as a single piece.
private struct RisesFromBelow: ViewModifier {
    /// The card's own height: far enough down that none of it shows.
    let distance: CGFloat
    /// Created false for each arrival, since the modifier is made afresh
    /// whenever the card is put on screen.
    @State private var risen = false
    /// True once the spring has had time to come to rest (response 0.42).
    @State private var landed = false

    func body(content: Content) -> some View {
        content
            // Told to everything inside, so a picture that arrives while the card is still climbing
            // is put in without a fade.
            .environment(\.cardIsRising, !landed)
            .offset(y: risen ? 0 : distance)
            .onAppear {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { risen = true }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(800))
                landed = true
            }
    }
}
