import CarPlay
import PleviDomain
import PleviLibraryIndex

/// Builds and keeps the car's templates.
@MainActor
final class CarPlayCoordinator: NSObject {
    private let interfaceController: CPInterfaceController
    private let app: AppModel

    private let home: CPListTemplate
    private let library: CPListTemplate
    private let playlists: CPListTemplate
    private let downloads: CPListTemplate

    private var refreshTask: Task<Void, Never>?
    private var upNextButtonWatch: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Watches the connection, Offline Mode and the library on show, and has
    /// the tabs redrawn when one of them changes. See `start()`.
    private var stateWatch: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?
    /// Watches for a song that would not play, so the car can say so.
    private var problemWatch: Task<Void, Never>?
    private var noticeDismissal: Task<Void, Never>?
    /// The "can't reach your library" alert while it is up, so reaching the
    /// library can take it down again.
    private var troubleAlert: CPAlertTemplate?
    /// Whether the app's own connect has finished, for `whenReady`.
    private var hasBooted = false
    /// Bumped by every playlists refresh, so a slow fetch that was replaced
    /// cannot write its list over the newer one (or over "Offline").
    private var playlistsGeneration = 0
    /// Playlists whose rows are waiting on their songs, so a second tap on
    /// the same row does not queue a second push.
    private var openingPlaylists: Set<MediaID> = []

    /// The playlists the Playlists tab already holds, kept here too so a search only filters a list
    /// already in memory rather than fetching one — mirrors `SearchView.allPlaylists` on the phone.
    private var allPlaylists: [Playlist] = []

    /// The tracks the last search turned up, so a tapped one starts the rest
    /// of them playing rather than just itself — the same thing a tap in
    /// Songs or an album already does.
    private var searchTracks: [Track] = []
    /// Sleeves already fetched, so redrawing Home does not ask for them again — and so a second
    /// shelf holding the same record draws instantly.
    private let artworkCache = NSCache<NSString, UIImage>()
    /// Row thumbnails, keyed by artwork rather than by album — a song and the record it is on share
    /// one.
    private let rowArtworkCache = NSCache<NSString, UIImage>()

    /// One drain per pushed list, kept only so unplugging can stop them.
    private var sleeveFills: [Int: Task<Void, Never>] = [:]
    private var nextSleeveFill = 0

    /// The size the car actually draws a row's thumbnail at. Asked once the
    /// controller is up; everything below the main actor is handed the
    /// number rather than the lookup.
    private var sleeveSize = SleeveSize(points: 44, scale: 2)

    init(interfaceController: CPInterfaceController, app: AppModel) {
        self.interfaceController = interfaceController
        self.app = app

        // Reduced sleeves run about 31KB each at the scale most cars draw at,
        // so this is fifteen hundred of them — three full lists, and clear of
        // one list evicting its own first rows while it is still filling.
        rowArtworkCache.totalCostLimit = 48 * 1_000_000

        home = CPListTemplate(title: "Home", sections: [])
        home.tabTitle = "Home"
        home.tabImage = UIImage(systemName: "house.fill")

        library = CPListTemplate(title: "Library", sections: [])
        library.tabTitle = "Library"
        library.tabImage = UIImage(systemName: "music.note.list")

        playlists = CPListTemplate(title: "Playlists", sections: [])
        playlists.tabTitle = "Playlists"
        playlists.tabImage = UIImage(systemName: "list.bullet")

        downloads = CPListTemplate(title: "Downloads", sections: [])
        downloads.tabTitle = "Downloads"
        downloads.tabImage = UIImage(systemName: "arrow.down.circle.fill")
    }

    /// The four tabs, held to whatever this car will show.
    private var tabs: [CPTemplate] {
        let all: [CPTemplate] = [home, library, playlists, downloads]
        return Array(all.prefix(CPTabBarTemplate.maximumTabCount))
    }

    func start() {
        let bar = CPTabBarTemplate(templates: tabs)
        interfaceController.setRootTemplate(bar, animated: false, completion: nil)

        // Once, here, rather than each time the playing screen goes up.
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.upNextTitle = "Up Next"
        nowPlaying.add(self)
        upNextButtonWatch = Task { [weak self] in
            // The button is only true while something is still queued, and that changes under the
            // driver: the last track starts, or a DJ tops the queue up, while the screen is already
            // open.
            for await queued in Observations({ self?.app.player.hasUpNext ?? false }) {
                CPNowPlayingTemplate.shared.isUpNextButtonEnabled = queued
            }
        }

        // The size a sleeve is drawn at is the car's to state, not ours to guess.
        let scale = interfaceController.carTraitCollection.displayScale
        if scale > 0 {
            sleeveSize = SleeveSize(points: CPListItem.maximumImageSize.width, scale: scale)
        }

        // Placeholders first, so the car has something the moment it connects
        // rather than four empty lists while the library is read.
        showLoading()

        // Then the library, straight away.
        if app.openLocalLibrary() { refreshAll() }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            // The same boot the phone does, and the reason it is not the
            // phone's to do: launched from the car, no view of ours is ever
            // created and this is the only thing that asks.
            await app.bootIfNeeded()
            hasBooted = true
            // Again, now that there is a server: Downloads and the offline
            // wording depend on knowing whether one was reached.
            refreshAll()
            reportConnectionTrouble()
        }

        // The tabs are drawn from the app's state, and used to be drawn twice — at the start and
        // once the boot finished — and then never again.
        stateWatch = Task { [weak self] in
            var last: ViewState?
            for await state in Observations({ self?.viewState() ?? ViewState() }) {
                guard let self else { return }
                defer { last = state }
                // The first value is what `start()` has just drawn.
                guard let previous = last, state != previous else { continue }
                stateChanged(from: previous, to: state)
            }
        }

        // A song that would not play was told to the phone's window and to
        // nobody else. The count moves only for playback problems — not for
        // the notes and library messages `transientError` also carries.
        problemWatch = Task { [weak self] in
            var seen: Int?
            for await count in Observations({ self?.app.playbackProblemCount ?? 0 }) {
                guard let self else { return }
                defer { seen = count }
                guard let previous = seen, count != previous else { continue }
                showPlaybackProblem(app.lastPlaybackProblem)
            }
        }
    }

    /// What the tabs are drawn from, compared to see whether they need drawing again.
    private struct ViewState: Equatable {
        var isOffline = false
        var hasProvider = false
        var libraryIsEmpty: Bool?
        var library: ServerID?
        var index: ObjectIdentifier?
    }

    private func viewState() -> ViewState {
        ViewState(
            isOffline: app.isOffline,
            hasProvider: app.provider != nil,
            libraryIsEmpty: app.libraryIsEmpty,
            library: app.libraryIndex?.server,
            index: app.libraryIndex.map { ObjectIdentifier($0) }
        )
    }

    private func stateChanged(from old: ViewState, to new: ViewState) {
        if new.hasProvider, !old.hasProvider {
            // Reached. The alert said it could not be, and may be up still.
            hasReportedTrouble = false
            if let alert = troubleAlert, interfaceController.presentedTemplate === alert {
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
            troubleAlert = nil
        }
        if new.library != old.library || new.index != old.index {
            // Another library: every list on the stack is about the last one, and a pinned record
            // or a row in it would answer "nothing on this record".
            for fill in sleeveFills.values { fill.cancel() }
            sleeveFills.removeAll()
            if !(interfaceController.topTemplate is CPNowPlayingTemplate) {
                interfaceController.popToRootTemplate(animated: false, completion: nil)
            }
        }
        // Flapping signal is common in a car, and the tabs are cheap but not
        // free to redraw; wait for it to settle.
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            refreshAll()
        }
    }

    /// Says so, briefly, when a song would not start.
    private func showPlaybackProblem(_ message: String?) {
        guard interfaceController.presentedTemplate == nil else { return }
        var titles = ["Couldn't play that", "Can't play"]
        // The phone's own wording where it is short enough for a car screen.
        if let message, !message.isEmpty, message.count <= 60 { titles.insert(message, at: 0) }
        showNotice(titles)
    }

    /// A short alert that takes itself down after a few seconds, with a way
    /// to try again where there is one.
    private func showNotice(_ title: String, retry: (() -> Void)? = nil) {
        showNotice([title], retry: retry)
    }

    private func showNotice(_ titles: [String], retry: (() -> Void)? = nil) {
        guard interfaceController.presentedTemplate == nil else { return }
        var actions = [CPAlertAction(title: retry == nil ? "OK" : "Not Now", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }]
        if let retry {
            actions.insert(CPAlertAction(title: "Try Again", style: .default) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                retry()
            }, at: 0)
        }
        let alert = CPAlertTemplate(titleVariants: titles, actions: actions)
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
        noticeDismissal?.cancel()
        noticeDismissal = Task { [weak self] in
            // Longer where there is something to tap.
            try? await Task.sleep(for: .seconds(retry == nil ? 5 : 10))
            guard !Task.isCancelled, let self,
                  interfaceController.presentedTemplate === alert
            else { return }
            interfaceController.dismissTemplate(animated: true, completion: nil)
        }
    }

    /// Holds a tap that would start playback until the app has finished connecting, for a few
    /// seconds at most.
    private func whenReady(_ start: @escaping @MainActor () -> Void) {
        guard !hasBooted else { return start() }
        Task { [weak self] in
            guard let self else { return }
            // `hasBooted` is set by the connect that `start()` began.
            var waited = 0
            while !hasBooted, waited < 25, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 1
            }
            start()
        }
    }

    /// Says so when there is no library to browse.
    private func reportConnectionTrouble() {
        guard !app.isOffline, app.provider == nil, !hasReportedTrouble else { return }
        hasReportedTrouble = true
        let alert = CPAlertTemplate(
            titleVariants: [
                "Can't reach your music library",
                "Can't reach your library",
                "No library",
            ],
            actions: [
                CPAlertAction(title: "Try Again", style: .default) { [weak self] _ in
                    guard let self else { return }
                    interfaceController.dismissTemplate(animated: true, completion: nil)
                    hasReportedTrouble = false
                    refreshTask = Task { [weak self] in
                        guard let self else { return }
                        await app.connectActive()
                        refreshAll()
                        reportConnectionTrouble()
                    }
                },
                CPAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
                    self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                },
            ]
        )
        troubleAlert = alert
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    /// Asked once per connection, so a car that cannot reach the server does
    /// not put the same alert up every time a tab is refreshed.
    private var hasReportedTrouble = false

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        upNextButtonWatch?.cancel()
        upNextButtonWatch = nil
        stateWatch?.cancel()
        stateWatch = nil
        refreshDebounce?.cancel()
        refreshDebounce = nil
        problemWatch?.cancel()
        problemWatch = nil
        noticeDismissal?.cancel()
        noticeDismissal = nil
        searchTask?.cancel()
        searchTask = nil
        CPNowPlayingTemplate.shared.remove(self)
        artworkTask?.cancel()
        artworkTask = nil
        for fill in sleeveFills.values { fill.cancel() }
        sleeveFills.removeAll()
        // The car has gone and none of this will be drawn again. On a
        // reconnect flap a fill still finishing would otherwise hold this
        // coordinator alive beside the new one.
        rowArtworkCache.removeAllObjects()
    }

    // MARK: Content

    private func showLoading() {
        for template in [home, library, playlists, downloads] {
            template.updateSections([
                CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
            ])
        }
    }

    private func refreshAll() {
        refreshHome()
        refreshLibrary()
        refreshPlaylists()
        refreshDownloads()
    }

    // MARK: Home

    private func refreshHome() {
        guard let index = app.libraryIndex else {
            home.updateSections([offlineSection(
                "Nothing to show yet",
                detail: app.isOffline ? "Offline. Downloads still play." : "Connecting to your library…"
            )])
            return
        }

        var sections: [CPListSection] = []

        let pinned = app.pins.items
        if !pinned.isEmpty {
            sections.append(CPListSection(
                items: capped(pinned.map { item in
                    let row = CPListItem(text: item.title, detailText: item.subtitle)
                    row.handler = { [weak self] _, completion in
                        self?.open(pin: item)
                        completion()
                    }
                    return row
                }),
                header: "Pinned",
                sectionIndexTitle: nil
            ))
        }

        for (title, filter) in [
            ("New Releases", AlbumFilter.recentlyReleased),
            ("Just Added", AlbumFilter.recentlyAdded),
        ] {
            let albums = (try? index.albums(
                filter: filter, offset: 0, limit: Self.shelfLimit, downloadedOnly: app.isOffline
            )) ?? []
            guard !albums.isEmpty else { continue }
            sections.append(CPListSection(items: [carousel(
                of: albums, titled: title,
                // Asked again for the full list rather than handed the ten the shelf had room for:
                // the chevron is there to show more, and showing the same ten again is the same
                // complaint one screen further in.
                more: { [weak self] in self?.pushShelf(filter: filter, titled: title) }
            )]))
        }

        // Recently Played is the play log rather than a query — see `PlayLog`,
        // which is what the phone's own shelf reads.
        let played = app.playLog.entries
        if !played.isEmpty {
            let cards = played.map { entry in
                Card(
                    id: entry.source.mediaID,
                    title: entry.source.title,
                    subtitle: entry.source.subtitle,
                    artwork: entry.source.artwork,
                    play: { [weak self] in self?.open(played: entry.source) }
                )
            }
            sections.append(CPListSection(items: [carousel(
                cards, titled: "Recently Played",
                more: { [weak self] in self?.pushCards(cards, titled: "Recently Played") }
            )]))
        }

        let stations = RadioStations.all(index: index, downloadedOnly: app.isOffline)
            .filter { if case .play = $0.action { true } else { false } }
        if !stations.isEmpty {
            // Tiles rather than a column of names: a station is a colour and
            // a mark long before it is a word, which is the same argument the
            // phone's own shelf makes for them.
            let elements = stations.map { station in
                CPListImageRowItemCardElement(
                    image: Self.tile(for: station),
                    showsImageFullHeight: false,
                    title: station.title,
                    subtitle: station.subtitle,
                    tintColor: nil
                )
            }
            let row = CPListImageRowItem(
                text: "Radio", cardElements: elements, allowsMultipleLines: false
            )
            row.listImageRowHandler = { [weak self] _, index, completion in
                guard let self, stations.indices.contains(index),
                      case .play(let rule) = stations[index].action
                else { return completion() }
                whenReady { [weak self] in
                    guard let self else { return }
                    RadioStations.play(rule, named: stations[index].title, app: app, on: app.player)
                    pushNowPlaying()
                }
                completion()
            }
            // The row's own tap, which is the chevron — see `carousel`.
            row.handler = { [weak self] _, completion in
                guard let self else { return completion() }
                push(CPListTemplate(
                    title: "Radio",
                    sections: [CPListSection(items: stations.compactMap { radioRow($0) })]
                ), emptyMessage: "No stations")
                completion()
            }
            sections.append(CPListSection(items: [row]))
        }

        home.updateSections(sections.isEmpty
            ? [offlineSection("Nothing on Home yet", detail: "Play something and it will show up here.")]
            : sections)
    }

    /// A station that starts on a tap. The pickers — Decades, Genres — and the
    /// Mixer are left out: choosing from a list of eleven decades or building
    /// a mix is not something to do while driving.
    private func radioRow(_ station: RadioStation) -> CPListItem? {
        guard case .play(let rule) = station.action else { return nil }
        let row = CPListItem(text: station.title, detailText: station.subtitle)
        row.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            whenReady { [weak self] in
                guard let self else { return }
                RadioStations.play(rule, named: station.title, app: app, on: app.player)
                pushNowPlaying()
            }
            completion()
        }
        return row
    }

    // MARK: Library

    private func refreshLibrary() {
        // Independent of whatever the tab holds — one way into the whole
        // library, rather than four tabs each wanting their own search.
        library.leadingNavigationBarButtons = [searchButton()]
        guard app.libraryIndex != nil else {
            library.updateSections([offlineSection(
                "Library unavailable",
                detail: app.isOffline ? "Offline. Downloads still play." : "Connecting…"
            )])
            return
        }
        var rows: [CPListItem] = []
        rows.append(drillRow("Artists", detail: "Everyone in your library") { [weak self] in
            self?.pushArtists(downloadedOnly: false)
        })
        rows.append(drillRow("Albums", detail: "Every record") { [weak self] in
            self?.pushAlbums(downloadedOnly: false)
        })
        rows.append(drillRow("Artist Collections", detail: nil) { [weak self] in
            self?.pushCollections(kind: .artists)
        })
        rows.append(drillRow("Album Collections", detail: nil) { [weak self] in
            self?.pushCollections(kind: .albums)
        })
        library.updateSections([CPListSection(items: rows)])
    }

    /// A row that opens another list. Always the whole row, never a control
    /// inside it: a tap target in a car is the row.
    private func drillRow(
        _ title: String,
        detail: String?,
        action: @escaping () -> Void
    ) -> CPListItem {
        let row = CPListItem(text: title, detailText: detail)
        row.accessoryType = .disclosureIndicator
        row.handler = { _, completion in
            action()
            completion()
        }
        return row
    }

    private func pushArtists(downloadedOnly: Bool) {
        guard let index = app.libraryIndex else { return }
        // Downloaded means what the phone's own Downloads screen means by it: the artists and
        // records you asked for by name, not every record a downloaded playlist happens to touch.
        if downloadedOnly, app.downloads != nil {
            // With "Merge downloads from all libraries" on, the other
            // libraries' too — the same list the phone's screen shows.
            presentArtists(app.downloadedShelves().artists, downloadedOnly: true)
            return
        }
        let offline = downloadedOnly || app.isOffline
        Task { [weak self] in
            // Off the main actor: a library of a few thousand artists takes long enough to read
            // that doing it here would hold up the very tap that asked for the list.
            let artists = await Task.detached(priority: .userInitiated) {
                (try? index.artists(downloadedOnly: offline)) ?? []
            }.value
            guard let self, !Task.isCancelled else { return }
            self.presentArtists(artists, downloadedOnly: downloadedOnly)
        }
    }

    private func presentArtists(_ artists: [Artist], downloadedOnly: Bool) {
        var pending: [PendingSleeve] = []
        let (shown, isCut) = cutToFit(artists)
        let rows = shown.map { artist in
            let row = CPListItem(text: artist.name, detailText: artist.albumCount.map { "\($0) albums" })
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                self?.pushArtist(artist, downloadedOnly: downloadedOnly)
                completion()
            }
            attachArtwork(artist.artwork, to: row, into: &pending)
            return row
        }
        push(CPListTemplate(
            title: downloadedOnly ? "Downloaded Artists" : "Artists",
            // By the key the query sorted on, not by the name on screen.
            sections: isCut
                ? [CPListSection(items: rows + [cutNotice(showing: shown.count)])]
                : Self.filed(rows, by: shown.map { $0.sortName ?? $0.name })
        ), emptyMessage: "No artists", waitingOn: pending)
    }

    private func pushArtist(_ artist: Artist, downloadedOnly: Bool) {
        // The artist's own library, which is another one for a downloaded
        // artist from the merged list.
        guard let index = app.index(for: artist.id.server) else { return }
        let albums = (try? index.albums(
            forArtist: artist.id, downloadedOnly: downloadedOnly || app.isOffline
        )) ?? []

        var pending: [PendingSleeve] = []
        var rows: [CPListItem] = []
        rows.append(contentsOf: truncated(albums).map { album in
            let row = CPListItem(text: album.displayName, detailText: album.year.map(String.init))
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                self?.pushAlbum(album)
                completion()
            }
            attachArtwork(album.artwork, to: row, into: &pending)
            return row
        })
        let template = CPListTemplate(
            title: artist.name, sections: [CPListSection(items: rows)]
        )
        template.trailingNavigationBarButtons = playbackButtons(
            play: { [weak self] in
                guard let self else { return }
                whenReady { [weak self] in
                    guard let self else { return }
                    MediaActions(app: app, destination: .here).playArtist(artist)
                    pushNowPlaying()
                }
            },
            shuffle: { [weak self] in
                guard let self else { return }
                whenReady { [weak self] in
                    guard let self else { return }
                    MediaActions(app: app, destination: .here).playArtist(artist, shuffled: true)
                    pushNowPlaying()
                }
            }
        )
        push(template, emptyMessage: "Nothing by this artist", waitingOn: pending)
    }

    private func pushAlbums(downloadedOnly: Bool) {
        guard let index = app.libraryIndex else { return }
        // See `pushArtists`: the same rule, from the same place.
        if downloadedOnly, app.downloads != nil {
            presentAlbums(app.downloadedShelves().albums, downloadedOnly: true)
            return
        }
        let offline = downloadedOnly || app.isOffline
        // One more than the car draws, to learn whether the list is cut.
        let limit = CPListTemplate.maximumItemCount + 1
        Task { [weak self] in
            let albums = await Task.detached(priority: .userInitiated) {
                (try? index.albums(
                    filter: .alphabeticalByName, offset: 0,
                    limit: limit, downloadedOnly: offline
                )) ?? []
            }.value
            guard let self, !Task.isCancelled else { return }
            self.presentAlbums(albums, downloadedOnly: downloadedOnly)
        }
    }

    /// A Home shelf opened out: the same question, without the shelf's limit.
    private func pushShelf(filter: AlbumFilter, titled title: String) {
        guard let index = app.libraryIndex else { return }
        let offline = app.isOffline
        let limit = CPListTemplate.maximumItemCount + 1
        Task { [weak self] in
            let albums = await Task.detached(priority: .userInitiated) {
                (try? index.albums(
                    filter: filter, offset: 0, limit: limit, downloadedOnly: offline
                )) ?? []
            }.value
            guard let self, !Task.isCancelled else { return }
            presentAlbums(albums, downloadedOnly: false, titled: title)
        }
    }

    private func presentAlbums(_ albums: [Album], downloadedOnly: Bool, titled: String? = nil) {
        var pending: [PendingSleeve] = []
        let (shown, isCut) = cutToFit(albums)
        let rows = shown.map { album -> CPListItem in
            let row = CPListItem(text: album.displayName, detailText: album.artistName)
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                self?.pushAlbum(album)
                completion()
            }
            attachArtwork(album.artwork, to: row, into: &pending)
            return row
        }
        push(CPListTemplate(
            title: titled ?? (downloadedOnly ? "Downloaded Albums" : "Albums"),
            sections: isCut
                ? [CPListSection(items: rows + [cutNotice(showing: shown.count)])]
                : Self.filed(rows, by: shown.map(\.displayName))
        ), emptyMessage: "No albums", waitingOn: pending)
    }

    /// A record: play it, shuffle it, or start from any song on it.
    private func pushAlbum(_ album: Album) {
        Task { [weak self] in
            guard let self else { return }
            let actions = MediaActions(app: app, destination: .here)
            let tracks = actions.playable(await actions.tracks(inAlbum: album.id), destination: .here)
            var rows: [CPListItem] = []

            rows.append(contentsOf: truncated(tracks).enumerated().map { index, track in
                let row = CPListItem(text: track.title, detailText: track.artistName)
                row.handler = { [weak self] _, completion in
                    guard let self else { return completion() }
                    // In its context, from where it was tapped, so the rest
                    // of the record follows it.
                    whenReady { [weak self] in
                        guard let self else { return }
                        app.player.play(tracks, startingAt: index, from: .album(album))
                        pushNowPlaying()
                    }
                    completion()
                }
                return row
            })

            let template = CPListTemplate(
                title: album.displayName, sections: [CPListSection(items: rows)]
            )
            template.trailingNavigationBarButtons = playbackButtons(
                play: { [weak self] in
                    guard let self else { return }
                    whenReady { [weak self] in
                        guard let self else { return }
                        app.player.play(tracks, from: .album(album))
                        pushNowPlaying()
                    }
                },
                shuffle: { [weak self] in
                    guard let self else { return }
                    whenReady { [weak self] in
                        guard let self else { return }
                        app.player.shuffle(tracks, from: .album(album))
                        pushNowPlaying()
                    }
                }
            )
            push(template, emptyMessage: "Nothing on this record")
        }
    }

    private func pushCollections(kind: MediaCollection.Kind) {
        let title = kind == .albums ? "Album Collections" : "Artist Collections"
        guard let provider = app.provider, !app.isOffline else {
            push(CPListTemplate(title: title, sections: []), emptyMessage: "Offline")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // A failed request is not an empty server.
            let found: [MediaCollection]
            switch await FetchOutcome.attempt({ try await provider.collections() }) {
            case .answered(let all): found = all.filter { $0.kind == kind }
            case .cancelled: return
            case .failed:
                showNotice("Couldn't load collections") { [weak self] in self?.pushCollections(kind: kind) }
                return
            }
            let rows = truncated(found).map { collection in
                let row = CPListItem(text: collection.name, detailText: collection.itemCount.map {
                    "\($0) \(kind == .albums ? "albums" : "artists")"
                })
                row.accessoryType = .disclosureIndicator
                row.handler = { [weak self] _, completion in
                    self?.pushCollection(collection)
                    completion()
                }
                return row
            }
            push(CPListTemplate(title: title, sections: [CPListSection(items: rows)]),
                 emptyMessage: "No collections")
        }
    }

    private func pushCollection(_ collection: MediaCollection) {
        guard let provider = app.provider else { return }
        Task { [weak self] in
            guard let self else { return }
            switch collection.kind {
            case .albums:
                let albums: [Album]
                switch await FetchOutcome.attempt({ try await provider.albums(inCollection: collection.id) }) {
                case .answered(let answered): albums = answered
                case .cancelled: return
                case .failed:
                    showNotice("Couldn't load this collection") { [weak self] in self?.pushCollection(collection) }
                    return
                }
                let rows = truncated(albums).map { album -> CPListItem in
                    let row = CPListItem(text: album.displayName, detailText: album.artistName)
                    row.accessoryType = .disclosureIndicator
                    row.handler = { [weak self] _, completion in
                        self?.pushAlbum(album)
                        completion()
                    }
                    return row
                }
                push(CPListTemplate(title: collection.name, sections: [CPListSection(items: rows)]),
                     emptyMessage: "Empty collection")
            case .artists:
                let artists: [Artist]
                switch await FetchOutcome.attempt({ try await provider.artists(inCollection: collection.id) }) {
                case .answered(let answered): artists = answered
                case .cancelled: return
                case .failed:
                    showNotice("Couldn't load this collection") { [weak self] in self?.pushCollection(collection) }
                    return
                }
                let rows = truncated(artists).map { artist -> CPListItem in
                    let row = CPListItem(text: artist.name, detailText: nil)
                    row.accessoryType = .disclosureIndicator
                    row.handler = { [weak self] _, completion in
                        self?.pushArtist(artist, downloadedOnly: false)
                        completion()
                    }
                    return row
                }
                push(CPListTemplate(title: collection.name, sections: [CPListSection(items: rows)]),
                     emptyMessage: "Empty collection")
            }
        }
    }

    // MARK: Search

    /// The button that opens it — leading, not trailing: the play/shuffle
    /// buttons already own the trailing side on every list this app pushes.
    private func searchButton() -> CPBarButton {
        CPBarButton(image: UIImage(systemName: "magnifyingglass") ?? UIImage()) { [weak self] _ in
            self?.pushSearch()
        }
    }

    private func pushSearch() {
        let template = CPSearchTemplate()
        template.delegate = self
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// What a search result row stands for, so a tap can act on the right
    /// thing without re-deriving it from the row's own text.
    private enum SearchHit {
        case artist(Artist)
        case album(Album)
        case playlist(Playlist)
        case track(Track)
    }

    /// The same two-tier search the phone's own search screen runs: the
    /// local index whenever it holds anything, a debounced server search
    /// only before the first sync has landed — see `SearchView.search()`.
    private func search(_ query: String) async -> SearchResults {
        guard let index = app.libraryIndex, let stats = try? index.stats(), !stats.isEmpty else {
            guard let provider = app.provider else { return SearchResults() }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return SearchResults() }
            var results = (try? await provider.search(query, limit: Self.searchLimit)) ?? SearchResults()
            results.playlists = matchingPlaylists(query)
            return results
        }
        // Off the main actor, same reasoning as `pushArtists`: a query over a large index is real
        // work, and it should not be done on the thread the car is waiting on to draw anything
        // else.
        let offline = app.isOffline
        let limit = Self.searchLimit
        let searchWork = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return SearchResults() }
            return (try? index.search(query, limit: limit, downloadedOnly: offline)) ?? SearchResults()
        }
        var results = await withTaskCancellationHandler {
            await searchWork.value
        } onCancel: {
            searchWork.cancel()
        }
        results.playlists = matchingPlaylists(query)
        return results
    }

    /// Neither backend has a playlist-search endpoint, so this is a plain
    /// name match over the list the Playlists tab already fetched — see
    /// `PlaylistNameSearch`, shared with `SearchView.matchingPlaylists`.
    private func matchingPlaylists(_ query: String) -> [Playlist] {
        PlaylistNameSearch.matching(query, in: allPlaylists)
    }

    /// Rows for a search template's own result list. Flat, with no
    /// sections — unlike everywhere else in this file, that is all a search
    /// template's completion handler takes.
    private func searchRows(for results: SearchResults) -> (items: [CPListItem], pending: [PendingSleeve]) {
        var pending: [PendingSleeve] = []
        var items: [CPListItem] = []

        items.append(contentsOf: results.artists.map { artist in
            let row = CPListItem(text: artist.name, detailText: artist.albumCount.map { "\($0) albums" })
            row.accessoryType = .disclosureIndicator
            row.userInfo = SearchHit.artist(artist)
            attachArtwork(artist.artwork, to: row, into: &pending)
            return row
        })
        items.append(contentsOf: results.albums.map { album in
            let row = CPListItem(text: album.displayName, detailText: album.artistName)
            row.accessoryType = .disclosureIndicator
            row.userInfo = SearchHit.album(album)
            attachArtwork(album.artwork, to: row, into: &pending)
            return row
        })
        items.append(contentsOf: results.playlists.map { playlist in
            let row = CPListItem(text: playlist.name, detailText: playlist.trackCount.map { "\($0) songs" })
            row.accessoryType = .disclosureIndicator
            row.userInfo = SearchHit.playlist(playlist)
            attachArtwork(playlist.artwork, to: row, into: &pending)
            return row
        })
        items.append(contentsOf: results.tracks.map { track in
            let row = CPListItem(text: track.title, detailText: track.artistName)
            row.userInfo = SearchHit.track(track)
            attachArtwork(track.artwork, to: row, into: &pending)
            return row
        })
        // Held to what a car will draw — see `truncated`.
        return (truncated(items), pending)
    }

    private static let searchLimit = 60

    /// A row waiting for its sleeve.
    private struct PendingSleeve {
        let id: ArtworkID
        weak var row: CPListItem?
    }

    /// The size a sleeve is drawn at, in the car's own terms.
    private struct SleeveSize: Sendable {
        let points: CGFloat
        let scale: CGFloat
        var pixels: Int { Int((points * scale).rounded()) }
    }

    /// Writes a row down to be dressed later.
    private func attachArtwork(
        _ id: ArtworkID?,
        to row: CPListItem,
        into pending: inout [PendingSleeve]
    ) {
        guard let id, app.artwork != nil else { return }
        pending.append(PendingSleeve(id: id, row: row))
    }

    /// Dresses a list's rows, a handful at a time, once the list is up.
    private func fillSleeves(_ pending: [PendingSleeve]) {
        guard !pending.isEmpty, app.artwork != nil else { return }
        let ticket = nextSleeveFill
        nextSleeveFill += 1
        sleeveFills[ticket] = Task { [weak self] in
            await self?.drainSleeves(pending)
            self?.sleeveFills[ticket] = nil
        }
    }

    /// Fetches what a list is missing and hands the pictures over in batches.
    private func drainSleeves(_ pending: [PendingSleeve]) async {
        guard let loader = app.artwork else { return }
        let size = sleeveSize

        // One fetch per sleeve however many rows want it, in the order they
        // are listed, so the rows the driver is actually looking at are
        // dressed first.
        var order: [ArtworkID] = []
        var waiting: [ArtworkID: [PendingSleeve]] = [:]
        for item in pending {
            if waiting[item.id] == nil { order.append(item.id) }
            waiting[item.id, default: []].append(item)
        }

        // Sleeves already reduced. Nothing to fetch, but not free to hang
        // either, so they are paced through the same handfuls.
        var held: [(ArtworkID, UIImage)] = []
        var missing: [ArtworkID] = []
        for id in order {
            if let image = rowArtworkCache.object(forKey: Self.sleeveKey(id)) {
                held.append((id, image))
            } else {
                missing.append(id)
            }
        }

        var batch: [(ArtworkID, UIImage)] = []

        // Hands what has gathered over a turn at a time, giving the main actor back between them.
        func handOver() async -> Bool {
            while !batch.isEmpty {
                if Task.isCancelled { return false }
                batch = apply(batch, to: &waiting)
                await Task.yield()
            }
            return true
        }

        for pair in held {
            batch.append(pair)
            guard batch.count >= Self.sleeveHandful else { continue }
            guard await handOver() else { return }
            // The list went while this was pacing itself. Nothing below is
            // worth doing to rows that are no longer anywhere.
            guard Self.anyoneWaiting(waiting) else { return }
        }
        guard await handOver() else { return }
        guard !missing.isEmpty, Self.anyoneWaiting(waiting) else { return }

        await withTaskGroup(of: (ArtworkID, UIImage?).self) { group in
            var next = 0
            func fetch() {
                guard next < missing.count else { return }
                let id = missing[next]
                next += 1
                group.addTask {
                    let image = await loader.image(for: id, bucket: Self.rowArtworkBucket)
                    return (id, image.map { Self.reduced($0, to: size) })
                }
            }
            for _ in 0..<Self.sleevesInTheAir { fetch() }

            while let (id, image) = await group.next() {
                if let image {
                    batch.append((id, image))
                } else {
                    // Nothing came back for this one.
                    waiting[id] = nil
                }
                if batch.count >= Self.sleeveHandful {
                    guard await handOver() else { break }
                }
                // Asked every time round rather than only when a handful lands: every row this list
                // was holding has gone, either dressed or because the driver moved on and the list
                // went with them.
                guard Self.anyoneWaiting(waiting) else { break }
                if Task.isCancelled { break }
                fetch()
            }
            group.cancelAll()
        }
        // Not on the way out: `stop()` has just emptied the cache, and this
        // would put a last handful back into it.
        if !Task.isCancelled { _ = await handOver() }
    }

    /// Hands out as much as one turn of the main actor should carry, and gives back whatever would
    /// not fit.
    private func apply(
        _ ready: [(ArtworkID, UIImage)],
        to waiting: inout [ArtworkID: [PendingSleeve]]
    ) -> [(ArtworkID, UIImage)] {
        var budget = Self.sleeveHandful
        var left: [(ArtworkID, UIImage)] = []
        for (id, image) in ready {
            guard budget > 0 else {
                left.append((id, image))
                continue
            }
            rowArtworkCache.setObject(
                image, forKey: Self.sleeveKey(id), cost: Self.bytes(of: image)
            )
            var rows = waiting[id] ?? []
            let taken = min(budget, rows.count)
            for pending in rows.prefix(taken) { pending.row?.setImage(image) }
            rows.removeFirst(taken)
            budget -= taken
            if rows.isEmpty {
                waiting[id] = nil
            } else {
                // More rows want this one than a turn has room for.
                waiting[id] = rows
                left.append((id, image))
            }
        }
        return left
    }

    private static func anyoneWaiting(_ waiting: [ArtworkID: [PendingSleeve]]) -> Bool {
        waiting.values.contains { $0.contains { $0.row != nil } }
    }

    /// The same sleeve, shrunk to the bitmap the car will actually draw.
    private nonisolated static func reduced(_ image: UIImage, to size: SleeveSize) -> UIImage {
        let pixels = size.pixels
        guard pixels > 0, let source = image.cgImage else { return image }
        // Orientation lives on the picture rather than on the bitmap, so it is carried across
        // rather than dropped — and rather than being a reason to give up, which is what it was: a
        // sideways cover came back its full size, cost the car the very…
        let fit = min(pixels, max(source.width, source.height))
        let over = max(CGFloat(source.width), CGFloat(source.height)) / CGFloat(fit)
        let width = max(1, Int((CGFloat(source.width) / over).rounded()))
        let height = max(1, Int((CGFloat(source.height) / over).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bitmap = context.makeImage() else { return image }
        return UIImage(cgImage: bitmap, scale: size.scale, orientation: image.imageOrientation)
    }

    /// Exact, because these are bitmaps we made ourselves: four bytes a pixel and a real stride.
    private nonisolated static func bytes(of image: UIImage) -> Int {
        guard let bitmap = image.cgImage else { return 0 }
        return bitmap.bytesPerRow * bitmap.height
    }

    private static func sleeveKey(_ id: ArtworkID) -> NSString {
        "\(id.server.rawValue.uuidString)|\(id.rawValue)" as NSString
    }

    /// How many *rows* are dressed in one turn.
    private static let sleeveHandful = 8

    /// A few at a time, not five hundred: the phone holds a handful of
    /// connections to any one server, and asking past that only queues the
    /// rest somewhere nothing can pace them.
    private static let sleevesInTheAir = 6

    /// Small: a row's thumbnail, not a cover to look at.
    private static let rowArtworkBucket = 120

    /// Held to what a car will draw.
    private func playbackButtons(
        play: @escaping () -> Void,
        shuffle: @escaping () -> Void
    ) -> [CPBarButton] {
        let playButton = CPBarButton(image: UIImage(systemName: "play.fill") ?? UIImage()) { _ in
            play()
        }
        let shuffleButton = CPBarButton(image: UIImage(systemName: "shuffle") ?? UIImage()) { _ in
            shuffle()
        }
        return [shuffleButton, playButton]
    }

    /// A shelf's worth of cards as a plain list, for the chevron on a row
    /// whose contents are not all records.
    private func pushCards(_ cards: [Card], titled title: String) {
        var pending: [PendingSleeve] = []
        let rows = truncated(cards).map { card -> CPListItem in
            let row = CPListItem(text: card.title, detailText: card.subtitle)
            row.handler = { _, completion in
                card.play()
                completion()
            }
            attachArtwork(card.artwork, to: row, into: &pending)
            return row
        }
        push(CPListTemplate(title: title, sections: [CPListSection(items: rows)]),
             emptyMessage: "Nothing here yet", waitingOn: pending)
    }

    private func truncated<T>(_ items: [T]) -> [T] {
        Array(items.prefix(CPListTemplate.maximumItemCount))
    }

    /// A list held to what the car will draw, with one place kept back for the row that says it was
    /// cut.
    private func cutToFit<T>(_ items: [T]) -> (shown: [T], isCut: Bool) {
        let limit = CPListTemplate.maximumItemCount
        guard items.count > limit else { return (items, false) }
        return (Array(items.prefix(limit - 1)), true)
    }

    private func cutNotice(showing count: Int) -> CPListItem {
        let row = CPListItem(
            text: "Showing the first \(count)",
            detailText: "Use Search in Library to find the rest"
        )
        row.isEnabled = false
        return row
    }

    /// Files rows under their first letter, so the car draws its index down the side of the screen.
    private static func filed(_ rows: [CPListItem], by names: [String]) -> [CPListSection] {
        guard rows.count == names.count, !rows.isEmpty else {
            return [CPListSection(items: rows)]
        }
        // An index is only true of a list already in that order.
        let letters = names.map(Self.initial(of:))
        guard zip(letters, letters.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            return [CPListSection(items: rows)]
        }
        var sections: [CPListSection] = []
        var current: [CPListItem] = []
        var letter: String?
        for (row, initial) in zip(rows, letters) {
            if initial != letter {
                if let letter, !current.isEmpty {
                    sections.append(CPListSection(
                        items: current, header: letter, sectionIndexTitle: letter
                    ))
                }
                letter = initial
                current = []
            }
            current.append(row)
        }
        if let letter, !current.isEmpty {
            sections.append(CPListSection(
                items: current, header: letter, sectionIndexTitle: letter
            ))
        }
        // The car draws only so many sections. Past that the index would be
        // partial, which is worse than none: it would point at letters and
        // silently miss the rest.
        guard sections.count <= CPListTemplate.maximumSectionCount else {
            return [CPListSection(items: rows)]
        }
        return sections
    }

    /// The letter a name files under.
    private static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        return first.isLetter ? String(first).uppercased() : "#"
    }

    /// Pushes a list, or says plainly that it is empty rather than showing a
    /// blank screen.
    private func push(
        _ template: CPListTemplate,
        emptyMessage: String,
        waitingOn pending: [PendingSleeve] = []
    ) {
        if template.sections.flatMap(\.items).isEmpty {
            template.updateSections([offlineSection(
                emptyMessage,
                detail: app.isOffline ? "Offline." : nil
            )])
        }
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        // After the push, never before: the fetching competes for the same
        // main actor that is putting the list on screen.
        fillSleeves(pending)
    }

    // MARK: Playlists

    private func refreshPlaylists() {
        playlistsGeneration += 1
        let mine = playlistsGeneration
        guard let provider = app.provider, !app.isOffline else {
            allPlaylists = []
            playlists.updateSections([offlineSection(
                "Offline",
                detail: "Playlists need a connection. Downloads still play."
            )])
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await FetchOutcome.attempt { try await provider.playlists() }
            // Replaced by a newer refresh, or by "Offline", while it waited.
            guard mine == playlistsGeneration else { return }
            let found: [Playlist]
            switch outcome {
            case .answered(let list): found = list
            case .cancelled: return
            case .failed:
                playlists.updateSections([retrySection("Couldn't load playlists") { [weak self] in
                    self?.refreshPlaylists()
                }])
                return
            }
            allPlaylists = found
            // Held at the top here as on the phone — the two or three you
            // actually use should be first, and a car is where that matters
            // most.
            let pinned = app.playlistTopPins.ids
            let ordered = app.settings.playlistSorting.sorted(found, pinnedToTop: pinned)
            let held = ordered.filter { pinned.contains($0.id.rawValue) }
            let rest = ordered.filter { !pinned.contains($0.id.rawValue) }

            var pending: [PendingSleeve] = []
            var sections: [CPListSection] = []
            if !held.isEmpty {
                sections.append(CPListSection(
                    // Cut to length before the rows are built, not after: every other list does it
                    // this way, and a library with more playlists than a car will draw was building
                    // — and asking for a sleeve for — every one it then discarded.
                    items: truncated(held).map { playlistRow($0, into: &pending) },
                    header: "Pinned",
                    sectionIndexTitle: nil
                ))
            }
            if !rest.isEmpty {
                // Filed under first letters where the order is alphabetical, which is what draws
                // the index down the side.
                let shown = truncated(rest)
                let rows = shown.map { playlistRow($0, into: &pending) }
                let filed = Self.filed(rows, by: shown.map(\.name))
                if filed.count > 1 {
                    sections.append(contentsOf: filed)
                } else {
                    sections.append(CPListSection(
                        items: rows,
                        header: held.isEmpty ? nil : "All Playlists",
                        sectionIndexTitle: nil
                    ))
                }
            }
            playlists.updateSections(sections.isEmpty
                ? [offlineSection("No playlists", detail: nil)]
                : sections)
            // A tab filled in place rather than a list pushed, so the drain
            // is started here instead of by `push`.
            fillSleeves(pending)
        }
    }

    private func playlistRow(
        _ playlist: Playlist,
        into pending: inout [PendingSleeve]
    ) -> CPListItem {
        let row = CPListItem(
            text: playlist.name,
            detailText: playlist.trackCount.map { "\($0) songs" }
        )
        row.accessoryType = .disclosureIndicator
        row.handler = { [weak self] _, completion in
            // The row's spinner runs until the list is up (or has failed),
            // which is also what stops a second tap queueing a second push.
            guard let self else { return completion() }
            pushPlaylist(playlist, completion: completion)
        }
        attachArtwork(playlist.artwork, to: row, into: &pending)
        return row
    }

    /// Whether the phone holds this playlist's songs.
    private func isKeptOnPhone(_ id: MediaID) -> Bool {
        guard let index = app.libraryIndex else { return false }
        return ((try? index.downloadedPlaylists()) ?? []).contains { $0.id == id.rawValue }
    }

    /// Opens a playlist: from the phone's copy when there is one and the connection is not to be
    /// trusted, from the server otherwise.
    private func pushPlaylist(_ playlist: Playlist, completion: @escaping () -> Void = {}) {
        let kept = isKeptOnPhone(playlist.id)
        let link = DownloadedPlaylistLink(id: playlist.id, name: playlist.name, artwork: playlist.artwork)
        if kept, app.isOffline || app.provider == nil {
            pushDownloadedPlaylist(link)
            return completion()
        }
        guard let provider = app.provider else {
            showNotice("Not connected to your library")
            return completion()
        }
        guard openingPlaylists.insert(playlist.id).inserted else { return completion() }
        Task { [weak self] in
            guard let self else { return completion() }
            defer {
                openingPlaylists.remove(playlist.id)
                completion()
            }
            let detail: PlaylistDetail
            switch await FetchOutcome.attempt({ try await provider.playlist(id: playlist.id) }) {
            case .answered(let answered):
                detail = answered
            case .cancelled:
                return
            case .failed:
                if kept {
                    pushDownloadedPlaylist(link)
                } else {
                    showNotice("Couldn't load this playlist") { [weak self] in
                        self?.pushPlaylist(playlist)
                    }
                }
                return
            }
            let tracks = MediaActions(app: app).playable(detail.entries.map(\.track), destination: .here)
            var rows: [CPListItem] = []

            rows.append(contentsOf: truncated(tracks).enumerated().map { index, track in
                let row = CPListItem(text: track.title, detailText: track.artistName)
                row.handler = { [weak self] _, completion in
                    guard let self else { return completion() }
                    whenReady { [weak self] in
                        guard let self else { return }
                        app.player.play(tracks, startingAt: index, from: .playlist(playlist))
                        pushNowPlaying()
                    }
                    completion()
                }
                return row
            })
            let template = CPListTemplate(
                title: playlist.name, sections: [CPListSection(items: rows)]
            )
            template.trailingNavigationBarButtons = playbackButtons(
                play: { [weak self] in
                    guard let self else { return }
                    whenReady { [weak self] in
                        guard let self else { return }
                        app.player.play(tracks, from: .playlist(playlist))
                        pushNowPlaying()
                    }
                },
                shuffle: { [weak self] in
                    guard let self else { return }
                    whenReady { [weak self] in
                        guard let self else { return }
                        app.player.shuffle(tracks, from: .playlist(playlist))
                        pushNowPlaying()
                    }
                }
            )
            push(template, emptyMessage: "Nothing in this playlist")
        }
    }

    // MARK: Downloads

    /// The one tab that must work with no network at all: everything here is
    /// on the phone by definition, and the index answers for all of it.
    private func refreshDownloads() {
        guard app.libraryIndex != nil else {
            downloads.updateSections([offlineSection("Nothing downloaded yet", detail: nil)])
            return
        }
        var rows: [CPListItem] = []
        rows.append(drillRow("Artists", detail: "Downloaded only") { [weak self] in
            self?.pushArtists(downloadedOnly: true)
        })
        rows.append(drillRow("Albums", detail: "Downloaded only") { [weak self] in
            self?.pushAlbums(downloadedOnly: true)
        })
        rows.append(drillRow("Playlists", detail: "Kept on this phone") { [weak self] in
            self?.pushDownloadedPlaylists()
        })
        downloads.updateSections([CPListSection(items: rows)])
    }

    private func pushDownloadedPlaylists() {
        guard let index = app.libraryIndex else { return }
        let kept = (try? index.downloadedPlaylists()) ?? []
        let server = index.server
        let rows = truncated(kept).map { record -> CPListItem in
            let link = DownloadedPlaylistLink(
                id: MediaID(server: server, rawValue: record.id),
                name: record.name,
                artwork: record.artworkId.map { ArtworkID(server: server, rawValue: $0) }
            )
            let row = CPListItem(text: record.name, detailText: nil)
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                self?.pushDownloadedPlaylist(link)
                completion()
            }
            return row
        }
        push(CPListTemplate(
            title: "Downloaded Playlists",
            sections: Self.filed(rows, by: truncated(kept).map(\.name))
        ), emptyMessage: "No playlists kept on this phone")
    }

    private func pushDownloadedPlaylist(_ link: DownloadedPlaylistLink) {
        // From the download manager, which is what the phone's own screen
        // reads — and which answers with no network at all.
        let tracks: [Track] = app.downloads?.tracks(inDownloadedPlaylist: link.id) ?? []
        var rows: [CPListItem] = []
        let source = PlayedSource(
            kind: .playlist, mediaID: link.id, title: link.name, artwork: link.artwork
        )
        rows.append(contentsOf: truncated(tracks).enumerated().map { index, track in
            let row = CPListItem(text: track.title, detailText: track.artistName)
            row.handler = { [weak self] _, completion in
                guard let self else { return completion() }
                whenReady { [weak self] in
                    guard let self else { return }
                    app.player.play(tracks, startingAt: index, from: .playlist(of: source))
                    pushNowPlaying()
                }
                completion()
            }
            return row
        })
        let template = CPListTemplate(
            title: link.name, sections: [CPListSection(items: rows)]
        )
        template.trailingNavigationBarButtons = playbackButtons(
            play: { [weak self] in
                guard let self else { return }
                whenReady { [weak self] in
                    guard let self else { return }
                    app.player.play(tracks, from: .playlist(of: source))
                    pushNowPlaying()
                }
            },
            shuffle: { [weak self] in
                guard let self else { return }
                whenReady { [weak self] in
                    guard let self else { return }
                    app.player.shuffle(tracks, from: .playlist(of: source))
                    pushNowPlaying()
                }
            }
        )
        push(template, emptyMessage: "Nothing kept from this playlist")
    }

    /// An empty state that offers the way out rather than only stating the
    /// problem — a blank list with no way to try again is the thing this
    /// exists to avoid.
    private func retrySection(_ message: String, retry: @escaping () -> Void) -> CPListSection {
        let row = CPListItem(text: message, detailText: "Tap to try again")
        row.handler = { _, completion in
            retry()
            completion()
        }
        return CPListSection(items: [row])
    }

    // MARK: Rows

    /// One thing in a carousel: enough to draw it and something to do when
    /// it is tapped.
    private struct Card {
        let id: MediaID
        let title: String
        let subtitle: String?
        let artwork: ArtworkID?
        let play: () -> Void
    }

    /// A station drawn as a tile: its own gradient with its mark on top.
    private static func tile(for station: RadioStation) -> UIImage {
        if let held = tileCache[station.id] { return held }
        let size = CPListImageRowItemCardElement.maximumImageSize
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = station.ramp.map { UIColor($0).cgColor } as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            let side = min(size.width, size.height) * 0.42
            let config = UIImage.SymbolConfiguration(pointSize: side, weight: .semibold)
            guard let glyph = UIImage(systemName: station.tileSymbol, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            else { return }
            glyph.draw(in: CGRect(
                x: (size.width - glyph.size.width) / 2,
                y: (size.height - glyph.size.height) / 2,
                width: glyph.size.width,
                height: glyph.size.height
            ))
        }
        tileCache[station.id] = image
        return image
    }

    /// The same six tiles are redrawn every time Home refreshes, so they are
    /// drawn once. Main-actor isolated with the rest of this type rather than
    /// opted out of it — there is no need to reach this from anywhere else.
    private static var tileCache: [String: UIImage] = [:]

    /// A shelf as a row of sleeves that scrolls sideways.
    private func carousel(
        of albums: [Album],
        titled title: String,
        more: (() -> Void)? = nil
    ) -> CPListImageRowItem {
        carousel(albums.map { album in
            Card(
                id: album.id,
                title: album.displayName,
                subtitle: album.artistName,
                artwork: album.artwork,
                // Opens the record rather than starting it. A cover is how
                // you recognise something you then want to look inside, and
                // Play and Shuffle are waiting on the record's own screen.
                play: { [weak self] in self?.pushAlbum(album) }
            )
        }, titled: title, more: more)
    }

    /// A shelf of sleeves.
    private func carousel(
        _ cards: [Card],
        titled title: String,
        more: (() -> Void)? = nil
    ) -> CPListImageRowItem {
        let shown = Array(cards.prefix(min(
            Self.shelfLimit,
            min(CPListTemplate.maximumItemCount, CPMaximumNumberOfGridImages)
        )))
        let images = shown.map { card in
            artworkCache.object(forKey: card.id.rawValue as NSString)
                ?? Self.placeholderArtwork
        }
        let row = CPListImageRowItem(text: title, images: images)
        row.listImageRowHandler = { _, index, completion in
            guard shown.indices.contains(index) else { return completion() }
            shown[index].play()
            completion()
        }
        if let more {
            row.handler = { _, completion in
                more()
                completion()
            }
        }
        loadArtwork(for: shown)
        return row
    }

    /// Fetches the sleeves a carousel is missing and redraws Home once they are in.
    private func loadArtwork(for cards: [Card]) {
        let wanted = cards.filter {
            artworkCache.object(forKey: $0.id.rawValue as NSString) == nil && $0.artwork != nil
        }
        guard !wanted.isEmpty, let loader = app.artwork else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            var found = false
            for card in wanted {
                guard !Task.isCancelled else { return }
                guard let art = card.artwork,
                      let image = await loader.image(for: art, bucket: Self.artworkBucket)
                else { continue }
                self?.artworkCache.setObject(image, forKey: card.id.rawValue as NSString)
                found = true
            }
            guard let self, found, !Task.isCancelled else { return }
            // Only this tab's sections are replaced. The stack above is left
            // alone, so a listener who has drilled into a record while the
            // sleeves were loading stays where they are.
            refreshHome()
        }
    }

    /// A plain square so the row has its shape before any picture arrives —
    /// without one the cards jump about as the sleeves land.
    private static let placeholderArtwork: UIImage = {
        // Square, like the sleeves it stands in for, and at the size the grid
        // asks for rather than the card element's — they are different, and
        // a picture built for the wrong one is resized by the system.
        let asked = CPListImageRowItem.maximumImageSize
        let longest = max(asked.width, asked.height)
        let size = CGSize(width: longest, height: longest)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.secondarySystemFill.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }()

    /// A carousel card, at the size the phone's own grid cells use — see
    /// `rowArtworkBucket` for why matching a real bucket matters.
    private static let artworkBucket = 300

    private func albumRow(_ album: Album) -> CPListItem {
        let row = CPListItem(text: album.displayName, detailText: album.artistName)
        row.handler = { [weak self] _, completion in
            self?.play(album: album)
            completion()
        }
        return row
    }

    private func offlineSection(_ title: String, detail: String?) -> CPListSection {
        CPListSection(items: [CPListItem(text: title, detailText: detail)])
    }

    /// Held to what a list will actually show.
    private func capped(_ items: [CPListItem]) -> [CPListItem] {
        Array(items.prefix(min(Self.shelfLimit, CPListTemplate.maximumItemCount)))
    }

    private static let shelfLimit = 10

    // MARK: Playing

    private func play(album: Album) {
        Task {
            let tracks = MediaActions(app: app).playable(await MediaActions(app: app).tracks(inAlbum: album.id), destination: .here)
            guard !tracks.isEmpty else { return }
            whenReady { [weak self] in
                guard let self else { return }
                app.player.play(tracks, from: .album(album))
                pushNowPlaying()
            }
        }
    }

    private func open(pin: PinnedItem) {
        switch pin.kind {
        case .album:
            guard let album = try? app.libraryIndex?.album(id: pin.mediaID) else { return }
            pushAlbum(album)
        case .artist:
            guard let artist = try? app.libraryIndex?.artist(id: pin.mediaID) else { return }
            whenReady { [weak self] in
                guard let self else { return }
                MediaActions(app: app, destination: .here).playArtist(artist, shuffled: true)
                pushNowPlaying()
            }
        case .playlist:
            pushPlaylist(pin.asPlaylist)
        case .collection:
            // Needs the server to say what is in it; the list is one tap
            // away under Library.
            break
        }
    }

    private func open(played source: PlayedSource) {
        switch source.kind {
        case .album:
            guard let album = try? app.libraryIndex?.album(id: source.mediaID) else { return }
            play(album: album)
        case .playlist:
            pushPlaylist(source.asPlaylist)
        }
    }

    /// The queue, from the button the car's own playing screen offers.
    private func pushUpNext() {
        var pending: [PendingSleeve] = []
        let items = app.player.upNext(limit: CPListTemplate.maximumItemCount)
        let rows = items.enumerated().map { offset, item -> CPListItem in
            let row = CPListItem(text: item.track.title, detailText: item.track.artistName)
            row.handler = { [weak self] _, completion in
                guard let self else { return completion() }
                app.player.play(item)
                completion()
            }
            attachArtwork(app.player.artwork(for: item.track), to: row, into: &pending)
            return row
        }
        let template = CPListTemplate(
            title: "Up Next", sections: [CPListSection(items: rows)]
        )
        push(template, emptyMessage: "Nothing else queued", waitingOn: pending)
    }

    private func pushNowPlaying() {
        // Only ever one of these on the stack: pushing a second would leave
        // the driver tapping Back twice to get out of the same screen.
        guard !(interfaceController.topTemplate is CPNowPlayingTemplate) else { return }
        // The button and the observer are set up once in `start()`.
        interfaceController.pushTemplate(
            CPNowPlayingTemplate.shared, animated: true, completion: nil
        )
    }
}

/// The car's playing screen tells us when its Up Next button is pressed.
extension CarPlayCoordinator: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ template: CPNowPlayingTemplate) {
        pushUpNext()
    }
}

/// CarPlay draws the keyboard itself — this is a real text field, dictation
/// included, not a voice-only affordance.
extension CarPlayCoordinator: @preconcurrency CPSearchTemplateDelegate {
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchTracks = []
            completionHandler([])
            return
        }
        searchTask = Task { [weak self] in
            guard let self else {
                completionHandler([])
                return
            }
            let results = await search(trimmed)
            guard !Task.isCancelled else { return }
            let (items, pending) = searchRows(for: results)
            searchTracks = results.tracks
            completionHandler(items)
            fillSleeves(pending)
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let hit = item.userInfo as? SearchHit else { return }
        switch hit {
        case .artist(let artist):
            pushArtist(artist, downloadedOnly: app.isOffline)
        case .album(let album):
            pushAlbum(album)
        case .playlist(let playlist):
            pushPlaylist(playlist)
        case .track(let track):
            // By identity within the results just shown, not a stored index: `searchRows` can
            // truncate the list before a track's row ever gets built, and an index into the request
            // would then point at the wrong song.
            guard let index = searchTracks.firstIndex(of: track) else { return }
            whenReady { [weak self] in
                guard let self else { return }
                app.player.play(searchTracks, startingAt: index, from: .songs)
                pushNowPlaying()
            }
        }
    }
}
