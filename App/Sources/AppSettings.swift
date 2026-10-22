import Foundation
import SwiftUI
import PleviAudio
import Observation
import PleviDomain
import PleviTransport
import PleviRemote

/// User preferences that shape the app itself rather than a server
/// connection. Persisted in UserDefaults — nothing here is secret.
@MainActor
@Observable
final class AppSettings {
    /// Which optional tabs appear in the tab bar. Home, Library, and the
    /// detached Search button are always present.
    var showsPlaylistsTab: Bool {
        didSet { defaults.set(showsPlaylistsTab, forKey: Keys.playlistsTab) }
    }

    var showsDownloadsTab: Bool {
        didSet { defaults.set(showsDownloadsTab, forKey: Keys.downloadsTab) }
    }

    /// How ratings are presented. Some people rate 1–5; others only mark the
    /// keepers, for whom a single star reads better and takes less room.
    var ratingStyle: RatingStyle {
        didSet { defaults.set(ratingStyle.rawValue, forKey: Keys.ratingStyle) }
    }

    /// Standard header, or the immersive artwork-led treatment.
    var pageStyle: PageStyle {
        didSet { defaults.set(pageStyle.rawValue, forKey: Keys.pageStyle) }
    }

    /// Light, dark, or whatever the phone is set to. Album and artist pages
    /// take their colours from the artwork whatever this says; this is
    /// everything else.
    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// The home screen icon last asked for, by its alternate name — "default" for the one the app
    /// ships wearing, chosen on purpose, and nil for nothing chosen yet.
    var selectedAppIconName: String? {
        didSet { defaults.set(selectedAppIconName, forKey: Keys.appIconName) }
    }

    /// Name of the chosen equaliser preset; see `EqualizerPreset.builtIn`.
    /// Empty once the bands have been moved by hand, which is no longer any
    /// preset in particular.
    var equalizerPresetName: String {
        didSet { defaults.set(equalizerPresetName, forKey: Keys.equalizerPreset) }
    }

    /// The curve actually in force, band by band.
    var equalizerGainsDB: [Double] {
        didSet {
            defaults.set(equalizerGainsDB, forKey: Keys.equalizerGains)
        }
    }

    /// Curves the user has saved, newest last. Kept apart from the built-in
    /// list so they can be removed and the originals cannot.
    var customEqualizerPresets: [EqualizerPreset] {
        didSet {
            guard let data = try? JSONEncoder().encode(customEqualizerPresets) else { return }
            defaults.set(data, forKey: Keys.customEqualizerPresets)
        }
    }

    /// Everything on offer: the built-in curves first, then anything saved.
    var allEqualizerPresets: [EqualizerPreset] {
        EqualizerPreset.builtIn + customEqualizerPresets
    }

    var equalizerPreset: EqualizerPreset {
        EqualizerPreset(
            name: equalizerPresetName.isEmpty ? "Custom" : equalizerPresetName,
            gainsDB: equalizerGainsDB
        )
    }

    /// Loads a preset's curve and remembers which one it was.
    func applyEqualizerPreset(_ preset: EqualizerPreset) {
        equalizerPresetName = preset.name
        equalizerGainsDB = preset.gainsDB
    }

    /// Moves one band. The curve stops being the preset it was, which is what
    /// the name being cleared says.
    func setEqualizerBand(_ index: Int, toGainDB gain: Double) {
        guard equalizerGainsDB.indices.contains(index) else { return }
        var gains = equalizerGainsDB
        gains[index] = Equalizer.clamp(gain)
        equalizerGainsDB = gains
        if !matchesStoredPreset(gains) { equalizerPresetName = "" }
    }

    private func matchesStoredPreset(_ gains: [Double]) -> Bool {
        allEqualizerPresets.contains { $0.name == equalizerPresetName && $0.gainsDB == gains }
    }

    /// Saves the current curve under a name of the user's choosing, replacing
    /// any earlier save with the same name.
    func saveCurrentEqualizerCurve(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = EqualizerPreset(name: trimmed, gainsDB: equalizerGainsDB)
        customEqualizerPresets.removeAll { $0.name == trimmed }
        customEqualizerPresets.append(preset)
        equalizerPresetName = trimmed
    }

    func removeCustomEqualizerPreset(_ preset: EqualizerPreset) {
        customEqualizerPresets.removeAll { $0.name == preset.name }
        // The curve stays as it is; only its name goes. Deleting a preset
        // should not change what you are hearing.
        if equalizerPresetName == preset.name { equalizerPresetName = "" }
    }

    /// Streaming over wi-fi, and streaming over mobile data.
    var streamingTranscodeWiFi: TranscodePolicy {
        didSet { store(streamingTranscodeWiFi, forKey: Keys.streamTranscode) }
    }

    var streamingTranscodeCellular: TranscodePolicy {
        didSet { store(streamingTranscodeCellular, forKey: Keys.streamTranscodeCellular) }
    }

    /// Whichever applies to the connection in use.
    func streamingTranscode(expensiveNetwork: Bool) -> TranscodePolicy {
        expensiveNetwork ? streamingTranscodeCellular : streamingTranscodeWiFi
    }

    /// Wi-Fi that is not the server's own network gets the mobile policy.
    var awayWiFiUsesMobilePolicy: Bool {
        didSet { defaults.set(awayWiFiUsesMobilePolicy, forKey: Keys.streamAwayWiFiAsMobile) }
    }

    var downloadTranscode: TranscodePolicy {
        didSet { store(downloadTranscode, forKey: Keys.downloadTranscode) }
    }

    private func store(_ policy: TranscodePolicy, forKey key: String) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: key)
    }

    private static func policy(from defaults: UserDefaults, key: String, fallback: TranscodePolicy) -> TranscodePolicy {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(TranscodePolicy.self, from: data)
        else { return fallback }
        return decoded
    }

    /// Brings a choice made before this build forward to one that can still be honoured.
    private static func migrated(_ policy: TranscodePolicy) -> TranscodePolicy {
        var policy = policy
        if policy.codec == TranscodeCodec.aac.rawValue {
            policy.codec = TranscodeCodec.opus.rawValue
        }
        if !TranscodePolicy.offeredBitRates.contains(policy.targetBitRateKbps) {
            policy.targetBitRateKbps = TranscodePolicy.offeredRate(
                nearest: policy.targetBitRateKbps
            )
        }
        return policy
    }

    /// A plain line, or a waveform read from the audio.
    var progressStyle: ProgressStyle {
        didSet { defaults.set(progressStyle.rawValue, forKey: Keys.progressStyle) }
    }

    /// Whether the played part of the bar takes the record's own colour, the
    /// one the stars are already drawn in.
    ///
    /// On the screen where the cover runs to the edges the bar is white by
    /// default, and deliberately: over a picture the accent is one more
    /// colour competing with it, while white reads as the page's own mark.
    /// That is a taste, though, not a fact, and the stars a few points above
    /// it are wearing the accent regardless — so on that screen the two
    /// marks a listener reads together are two different colours for a
    /// reason nobody outside the code can see.
    var tintsProgressLikeStars: Bool {
        didSet { defaults.set(tintsProgressLikeStars, forKey: Keys.tintsProgressLikeStars) }
    }

    /// How the playing screen is arranged.
    var nowPlayingLayout: NowPlayingLayout {
        didSet { defaults.set(nowPlayingLayout.rawValue, forKey: Keys.nowPlayingLayout) }
    }

    /// Whether the iPad queue rail starts open, landscape and portrait held separately — a window
    /// turned on its side has room to spare that a tall one does not, so the two are free to
    /// disagree.
    var queueRailExpandedLandscape: Bool {
        didSet { defaults.set(queueRailExpandedLandscape, forKey: Keys.queueRailExpandedLandscape) }
    }
    var queueRailExpandedPortrait: Bool {
        didSet { defaults.set(queueRailExpandedPortrait, forKey: Keys.queueRailExpandedPortrait) }
    }

    /// Whether the words are fetched for the playing song.
    var showsLyrics: Bool {
        didSet { defaults.set(showsLyrics, forKey: Keys.lyrics) }
    }

    /// The codec badge under the progress bar on Now Playing, which names
    /// the conversion when one is in use.
    var showsCodecInfo: Bool {
        didSet { defaults.set(showsCodecInfo, forKey: Keys.codecInfo) }
    }

    /// The codec badge under an album's tracklist.
    var showsCodecBadge: Bool {
        didSet { defaults.set(showsCodecBadge, forKey: Keys.formatBadge) }
    }

    /// Adds the bit rate to lossy formats — "MP3 320" rather than "MP3".
    var badgeShowsLossyBitRate: Bool {
        didSet { defaults.set(badgeShowsLossyBitRate, forKey: Keys.badgeLossyBitRate) }
    }

    /// Adds sample rate and bit depth to lossless formats — "FLAC 44.1/16".
    var badgeShowsLosslessDetail: Bool {
        didSet { defaults.set(badgeShowsLosslessDetail, forKey: Keys.badgeLosslessDetail) }
    }

    /// Whether a song with no rating shows five empty stars or nothing at
    /// all. Off means every row carries a set; on keeps a tracklist quiet,
    /// with stars only where there is something to read.
    var showsStarsOnlyWhenRated: Bool {
        didSet { defaults.set(showsStarsOnlyWhenRated, forKey: Keys.starsWhenRated) }
    }

    /// Whether a song with this rating should show stars at all.
    func showsStars(for rating: StarRating?) -> Bool {
        !(showsStarsOnlyWhenRated && rating == nil)
    }

    /// How a song reads in a tracklist. See `TrackRowStyle`.
    var trackRowStyle: TrackRowStyle {
        didSet { defaults.set(trackRowStyle.rawValue, forKey: Keys.trackRowStyle) }
    }

    /// How many songs are fetched at once, or 0 to leave it to iOS.

    /// How many songs a weaving DJ (Moody, Fresh, Gold, Deep Cuts) inserts into each gap it opens,
    /// right after the currently playing track.
    var djInsertionCount: Int {
        didSet { defaults.set(djInsertionCount, forKey: Keys.djInsertionCount) }
    }

    /// How the last batch went — songs, and how long they took.
    ///
    /// Kept so the setting above can be judged rather than guessed at.
    var lastBatchSummary: String? {
        didSet { defaults.set(lastBatchSummary, forKey: Keys.lastBatch) }
    }

    /// How each Downloads shelf orders what it holds.
    private(set) var downloadSorts: [String: String] {
        didSet { defaults.set(downloadSorts, forKey: Keys.downloadSort) }
    }

    func downloadOrder(for shelf: String) -> DownloadOrder {
        guard let stored = downloadSorts[shelf] else { return .default(for: shelf) }
        let parts = stored.split(separator: "|").map(String.init)
        guard let field = parts.first.flatMap(DownloadSort.init(rawValue:)) else {
            return .default(for: shelf)
        }
        return DownloadOrder(field: field, ascending: parts.count > 1 && parts[1] == "asc")
    }

    func setDownloadOrder(_ order: DownloadOrder, for shelf: String) {
        downloadSorts[shelf] = "\(order.field.rawValue)|\(order.ascending ? "asc" : "desc")"
    }

    /// Albums across a grid: three to see more at once, two for sleeves big enough to recognise
    /// from across the room.
    var seeAllLayout: AlbumCollection.Layout {
        didSet {
            defaults.set(seeAllLayout == .grid ? "grid" : "list", forKey: Keys.seeAllLayout)
        }
    }

    /// Albums across on an iPhone: two or three.
    var albumsPerRow: Int {
        didSet { defaults.set(albumsPerRow, forKey: Keys.albumsPerRow) }
    }

    /// Albums across on an iPad, which depends on how it is held: low is three in portrait and four
    /// in landscape, high is four and five.
    var highGridDensity: Bool {
        didSet { defaults.set(highGridDensity ? "high" : "low", forKey: Keys.gridDensity) }
    }

    /// Whether the window is wider than it is tall. Set by `RootView`, and
    /// not saved: it is a fact about the screen, not a choice.
    var windowIsLandscape = false

    /// How many albums go across a grid right now. An iPhone has its own
    /// setting and does not turn its grid when it is turned.
    var albumColumns: Int {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return albumsPerRow }
        let low = windowIsLandscape ? 4 : 3
        return highGridDensity ? low + 1 : low
    }

    /// Whether each collections screen draws a grid of sleeves or a list of rows.
    var collectionGridKinds: Set<String> {
        didSet { defaults.set(Array(collectionGridKinds), forKey: Keys.collectionGrids) }
    }

    func collectionsUseGrid(_ kind: MediaCollection.Kind) -> Bool {
        collectionGridKinds.contains(kind.rawValue)
    }

    func setCollectionsUseGrid(_ on: Bool, for kind: MediaCollection.Kind) {
        if on {
            collectionGridKinds.insert(kind.rawValue)
        } else {
            collectionGridKinds.remove(kind.rawValue)
        }
    }

    /// Whether a long song title rolls sideways on Now Playing rather than
    /// ending in an ellipsis. Kept per line: a rolling title is useful, three
    /// lines rolling at once can be a lot of movement.
    var rollsTitle: Bool {
        didSet { defaults.set(rollsTitle, forKey: Keys.rollsTitle) }
    }

    var rollsArtist: Bool {
        didSet { defaults.set(rollsArtist, forKey: Keys.rollsArtist) }
    }

    var rollsAlbum: Bool {
        didSet { defaults.set(rollsAlbum, forKey: Keys.rollsAlbum) }
    }

    /// Temporary: which Now Playing layout to draw.
    /// How much played audio to keep on the phone, in gigabytes. A track
    /// played again comes off the disk rather than the network.
    var mediaCacheGigabytes: Int {
        didSet { defaults.set(mediaCacheGigabytes, forKey: Keys.mediaCacheGB) }
    }

    /// The decades and genres last picked for a radio, so the picker opens
    /// where it was left rather than empty every time.
    var radioDecades: [Int] {
        didSet { defaults.set(radioDecades, forKey: Keys.radioDecades) }
    }

    var radioGenres: [String] {
        didSet { defaults.set(radioGenres, forKey: Keys.radioGenres) }
    }

    /// How each Home shelf is drawn, for the shelves that can be drawn more than one way — see
    /// `HomeSection.supportsLayoutChoice`.
    var homeSectionLayouts: [String: AlbumDisplayStyle] {
        didSet {
            write(homeSectionLayouts.mapValues(\.rawValue), forKey: Keys.homeLayouts)
        }
    }

    /// How a shelf is drawn. Carousel unless told otherwise: it is what Home
    /// has always looked like, and it keeps a shelf to one row.
    func homeLayout(_ section: HomeSection) -> AlbumDisplayStyle {
        guard section.supportsLayoutChoice else { return .carousel }
        return homeSectionLayouts[section.rawValue] ?? Self.defaultHomeLayout(section)
    }

    /// Carousel unless the shelf was designed as something else.
    private static func defaultHomeLayout(_ section: HomeSection) -> AlbumDisplayStyle {
        section == .radio ? .grid : .carousel
    }

    func setHomeLayout(_ layout: AlbumDisplayStyle, for section: HomeSection) {
        guard section.supportsLayoutChoice else { return }
        homeSectionLayouts[section.rawValue] = layout
    }

    /// The shelf as the four-way selector sees it: off, or the shape it
    /// takes when it is on. The same control the artist page's sections use,
    /// so one glyph row means the same thing on both screens.
    func homeSelectorLayout(_ section: HomeSection) -> SectionLayout {
        guard isEnabled(section) else { return .off }
        switch homeLayout(section) {
        case .grid: return .grid
        case .carousel: return .carousel
        case .list: return .list
        }
    }

    /// Setting it off switches the shelf off and leaves its shape alone, so
    /// turning it back on returns it to the shape it had rather than to a
    /// default.
    func setHomeSelectorLayout(_ layout: SectionLayout, for section: HomeSection) {
        guard layout.isOn else {
            setEnabled(false, for: section)
            return
        }
        setEnabled(true, for: section)
        setHomeLayout(layout.displayStyle, for: section)
    }

    /// The order Home's shelves appear in, and which of them appear at all.
    var searchResultOrder: [SearchResultKind] {
        didSet {
            defaults.set(searchResultOrder.map(\.rawValue), forKey: Keys.searchResultOrder)
        }
    }

    /// Whether Search also looks through the other libraries ticked under Quick Switch, not only
    /// the one that is open.
    var mergesDownloads: Bool {
        didSet { defaults.set(mergesDownloads, forKey: Keys.mergeDownloads) }
    }

    var searchesAllQuickLibraries: Bool {
        didSet { defaults.set(searchesAllQuickLibraries, forKey: Keys.searchAllQuickLibraries) }
    }

    var homeSectionOrder: [HomeSection] {
        didSet {
            write(homeSectionOrder.map(\.rawValue), forKey: Keys.homeOrder)
        }
    }

    var homeSectionsOff: Set<HomeSection> {
        didSet {
            write(homeSectionsOff.map(\.rawValue), forKey: Keys.homeOff)
        }
    }

    /// Which library's Home is being read and written.
    private(set) var homeLibrary: ServerID?

    /// Points Home at a library. Called whenever one is connected.
    func useForHome(library: ServerID?) {
        guard library != homeLibrary else { return }
        homeLibrary = library
        guard library != nil else { return }
        adoptAnySharedHome()
        let storedOrder = (read(Keys.homeOrder) as? [String] ?? [])
            .compactMap(HomeSection.init(rawValue:))
        homeSectionOrder = storedOrder + HomeSection.builtIns.filter { !storedOrder.contains($0) }
        homeSectionLayouts = (read(Keys.homeLayouts) as? [String: String] ?? [:])
            .compactMapValues(AlbumDisplayStyle.init(rawValue:))
        homeSectionsOff = Set((read(Keys.homeOff) as? [String] ?? [])
            .compactMap(HomeSection.init(rawValue:)))
        // Read the new setting, falling back to the switch it replaced so a
        // shelf already set to the small kind stays small.

    }

    /// Reads the open library's Home arrangement again, from the keys a
    /// restore by hand has just written. `useForHome` does nothing for the
    /// library that is already open.
    func reloadHome() {
        guard let library = homeLibrary else { return }
        homeLibrary = nil
        useForHome(library: library)
    }

    /// A Home arranged before it was kept per library belongs to the library
    /// it was arranged in — whichever connects first. Moved across once, then
    /// the shared copy goes, so it cannot follow you into every other library.
    private func adoptAnySharedHome() {
        guard let library = homeLibrary else { return }
        // Layouts among them: they are as much the arrangement as the order
        // is, and a Home restored with its shelves in the right order but all
        // the wrong sizes is a Home that looks like the restore half worked.
        for base in [Keys.homeOrder, Keys.homeOff, Keys.homeLayouts] {
            let scoped = "\(base).\(library.rawValue.uuidString)"
            guard defaults.object(forKey: scoped) == nil,
                  let shared = defaults.object(forKey: base) else { continue }
            defaults.set(shared, forKey: scoped)
            defaults.removeObject(forKey: base)
        }
    }

    private func read(_ base: String) -> Any? {
        guard let library = homeLibrary else { return nil }
        return defaults.object(forKey: "\(base).\(library.rawValue.uuidString)")
    }

    private func write(_ value: Any, forKey base: String) {
        // Before a library is known there is nowhere to put it. The values in
        // memory are the defaults, and they are written the moment one is.
        guard let library = homeLibrary else { return }
        defaults.set(value, forKey: "\(base).\(library.rawValue.uuidString)")
    }

    func isEnabled(_ section: HomeSection) -> Bool { !homeSectionsOff.contains(section) }

    func setEnabled(_ enabled: Bool, for section: HomeSection) {
        if enabled { homeSectionsOff.remove(section) } else { homeSectionsOff.insert(section) }
    }

    /// How the playlists list is ordered.
    var playlistSorting: PlaylistSorting {
        didSet { defaults.set(playlistSorting.rawValue, forKey: Keys.playlistSorting) }
    }

    /// How a playlist's own songs are sorted on its page.
    private var playlistTrackSortRaw: String {
        didSet { defaults.set(playlistTrackSortRaw, forKey: Keys.playlistTrackSort) }
    }

    var playlistTrackOrder: PlaylistTrackOrder {
        let parts = playlistTrackSortRaw.split(separator: "|").map(String.init)
        guard let field = parts.first.flatMap(PlaylistSongSort.init(rawValue:)) else {
            return .default
        }
        return PlaylistTrackOrder(field: field, ascending: parts.count > 1 && parts[1] == "asc")
    }

    func setPlaylistTrackOrder(_ order: PlaylistTrackOrder) {
        playlistTrackSortRaw = "\(order.field.rawValue)|\(order.ascending ? "asc" : "desc")"
    }

    /// Browse and play only what is on the phone, whatever the network is
    /// doing. Kept apart from "the server is unreachable": one is a choice
    /// and the other is a circumstance, and the app says which.
    var offlineMode: Bool {
        didSet { defaults.set(offlineMode, forKey: Keys.offlineMode) }
    }

    /// Whether downloads may use mobile data.
    var refreshPlaylistsAtLaunch: Bool {
        didSet { defaults.set(refreshPlaylistsAtLaunch, forKey: Keys.refreshPlaylistsAtLaunch) }
    }

    /// Whether what is kept with downloaded music is brought up to date at launch, and again after
    /// each sync.
    var refreshDownloadedDetailsAtLaunch: Bool {
        didSet { defaults.set(refreshDownloadedDetailsAtLaunch, forKey: Keys.refreshDownloadedDetailsAtLaunch) }
    }

    var downloadsOverCellular: Bool {
        didSet { defaults.set(downloadsOverCellular, forKey: Keys.downloadsOverCellular) }
    }

    /// How much artwork to keep on disk, in megabytes. Sleeves are cheap to
    /// fetch again, so this is smaller than the play cache by default.
    var artworkCacheMegabytes: Int {
        didSet { defaults.set(artworkCacheMegabytes, forKey: Keys.artworkCacheMB) }
    }

    /// Whether converted copies are kept alongside originals.
    var keepsConvertedFiles: Bool {
        didSet { defaults.set(keepsConvertedFiles, forKey: Keys.keepConverted) }
    }

    /// Where star ratings are shown.
    var ratingVisibility: RatingVisibility {
        didSet { defaults.set(ratingVisibility.rawValue, forKey: Keys.ratingVisibility) }
    }

    /// Whether the Up Next list carries a rating on each row.
    var showsRatingsInQueue: Bool {
        didSet { defaults.set(showsRatingsInQueue, forKey: Keys.ratingsInQueue) }
    }

    /// Which version of the provider-to-index mapping the stored library was built with.
    var indexMappingVersion: Int {
        didSet { defaults.set(indexMappingVersion, forKey: Keys.mappingVersion) }
    }

    /// The mapping version one library's index was last completely walked with, or `nil` if it
    /// never has been.
    func indexMapping(for library: ServerID) -> Int? {
        let key = "\(Keys.mappingVersion).\(library.rawValue.uuidString)"
        if let stored = defaults.object(forKey: key) as? Int { return stored }
        let adopted = "\(Keys.mappingVersion).adopted"
        guard !defaults.bool(forKey: adopted),
              let legacy = defaults.object(forKey: Keys.mappingVersion) as? Int else { return nil }
        defaults.set(true, forKey: adopted)
        defaults.set(legacy, forKey: key)
        return legacy
    }

    func markIndexMapped(_ version: Int, for library: ServerID) {
        defaults.set(version, forKey: "\(Keys.mappingVersion).\(library.rawValue.uuidString)")
    }

    /// Whether the right-hand time on Now Playing counts down rather than
    /// showing the track's length. Set by tapping it; kept because it is a
    /// preference, not a mode you want to re-pick every time.
    var showsRemainingTime: Bool {
        didSet { defaults.set(showsRemainingTime, forKey: Keys.remainingTime) }
    }

    /// Whether stopping and clearing the queue asks first. Off by default:
    /// the action is deliberate wherever it is offered — a long press, or a
    /// menu item — and Plexamp does not ask either.
    var confirmsStopAndClear: Bool {
        didSet { defaults.set(confirmsStopAndClear, forKey: Keys.confirmStop) }
    }

    /// How many songs ahead to fetch while playing, on a network that does
    /// not charge by the megabyte.
    var prefetchOnWiFi: Int {
        didSet { defaults.set(prefetchOnWiFi, forKey: Keys.prefetchWiFi) }
    }

    /// The same on cellular, where reading ahead spends someone's data on
    /// songs they may skip.
    var prefetchOnCellular: Int {
        didSet { defaults.set(prefetchOnCellular, forKey: Keys.prefetchCellular) }
    }

    /// How many songs to pre-cache right now. Never fewer than one: the next
    /// track has to be in hand for a gapless join.
    func prefetchCount(expensiveNetwork: Bool) -> Int {
        max(1, expensiveNetwork ? prefetchOnCellular : prefetchOnWiFi)
    }

    /// Seconds of overlap between tracks; zero leaves them gapless.
    /// Loudness-aware transitions. On by default: the whole point of it is
    /// that it does nothing to the records that should be left alone.
    var smartFades: Bool {
        didSet { defaults.set(smartFades, forKey: Keys.smartFades) }
    }

    /// The longest two tracks may run together, before the other limits.
    var maxOverlapSeconds: Double {
        didSet { defaults.set(maxOverlapSeconds, forKey: Keys.maxOverlap) }
    }

    /// What happens to the two signals during an overlap.
    var fadeEnvelope: TransitionEnvelope {
        didSet { defaults.set(fadeEnvelope.rawValue, forKey: Keys.fadeEnvelope) }
    }

    /// Whether consecutive tracks of one album are left joined plainly.
    var keepAlbumsGapless: Bool {
        didSet { defaults.set(keepAlbumsGapless, forKey: Keys.keepAlbumsGapless) }
    }

    /// The loudness at which two tracks are judged to be out of each other's
    /// way. Advanced: it is the one number that changes the character of every
    /// transition, and −17 is where MixRamp put it.
    var fadeThresholdDb: Double {
        didSet { defaults.set(fadeThresholdDb, forKey: Keys.fadeThreshold) }
    }

    /// Taken off every computed overlap. Advanced, and zero unless somebody is
    /// tuning by ear.
    var overlapTrimSeconds: Double {
        didSet { defaults.set(overlapTrimSeconds, forKey: Keys.overlapTrim) }
    }

    /// Whether a track at a different sample rate may join the one playing.
    var matchSampleRates: Bool {
        didSet { defaults.set(matchSampleRates, forKey: Keys.matchSampleRates) }
    }

    /// Whether the queue carries on with similar music when it runs out.
    var smartContinuePlaying: Bool {
        didSet { defaults.set(smartContinuePlaying, forKey: Keys.smartContinue) }
    }

    /// Whether to carry on, answered per kind of queue.
    private var smartContinueByOrigin: [String: Bool] {
        didSet {
            guard let data = try? JSONEncoder().encode(smartContinueByOrigin) else { return }
            defaults.set(data, forKey: Keys.smartContinueByOrigin)
        }
    }

    func smartContinue(for origin: QueueOrigin.Kind) -> Bool {
        smartContinueByOrigin[origin.rawValue] ?? smartContinuePlaying
    }

    func setSmartContinue(_ on: Bool, for origin: QueueOrigin.Kind) {
        smartContinueByOrigin[origin.rawValue] = on
    }

    /// Whether the shuffle button does the smart shuffle by default.
    var smartShuffleByDefault: Bool {
        didSet { defaults.set(smartShuffleByDefault, forKey: Keys.smartShuffleByDefault) }
    }

    /// What the smart shuffle weighs, in what order, and how far apart it
    /// keeps songs by the same artist.
    var smartShuffle: SmartShuffleSettings {
        didSet {
            guard let data = try? JSONEncoder().encode(smartShuffle) else { return }
            defaults.set(data, forKey: Keys.smartShuffle)
        }
    }

    /// The end-of-chain safety limiter.
    var limiterEnabled: Bool {
        didSet { defaults.set(limiterEnabled, forKey: Keys.limiterEnabled) }
    }

    var replayGainMode: ReplayGainMode {
        didSet { defaults.set(replayGainMode.rawValue, forKey: Keys.replayGainMode) }
    }

    /// Applied on top of the file's own tags, in decibels.
    var replayGainPreampDB: Double {
        didSet { defaults.set(replayGainPreampDB, forKey: Keys.replayGainPreamp) }
    }

    /// Plex and Apple Music both shelve short releases together, and with a
    /// handful of each two near-empty headings read worse than one.
    var combinesSinglesAndEPs: Bool {
        didSet { defaults.set(combinesSinglesAndEPs, forKey: Keys.combineSinglesEPs) }
    }

    /// Whether the album review appears at all, and where.
    var showsAlbumReview: Bool {
        didSet { defaults.set(showsAlbumReview, forKey: Keys.albumReview) }
    }

    /// The sonically-similar shelf at the foot of an album page. Needs a
    /// server that can answer the question — Plex's sonic analysis.
    var showsSimilarAlbums: Bool {
        didSet { defaults.set(showsSimilarAlbums, forKey: Keys.similarAlbums) }
    }

    /// Whether the Released on This Day shelf is the small kind.

    /// The libraries offered by the switcher on the Home screen.
    var quickSwitchLibraries: [LibrarySelection] {
        didSet {
            let data = try? JSONEncoder().encode(quickSwitchLibraries)
            defaults.set(data, forKey: Keys.quickSwitchLibraries)
        }
    }

    /// The background on a playlist page, kept separate from album and artist pages.
    var playlistPageStyle: PageStyle {
        didSet { defaults.set(playlistPageStyle.rawValue, forKey: Keys.playlistStyle) }
    }

    var albumReviewPosition: SectionPosition {
        didSet { defaults.set(albumReviewPosition.rawValue, forKey: Keys.albumReviewPosition) }
    }

    /// Artist page sections in display order.
    var artistSectionOrder: [ArtistSection] {
        didSet {
            defaults.set(artistSectionOrder.map(\.rawValue), forKey: Keys.artistOrder)
        }
    }

    /// How each of those sections is shown, `.off` included. Sections with
    /// nothing to show are skipped regardless.
    var artistSectionLayouts: [ArtistSection: SectionLayout] {
        didSet {
            defaults.set(
                Dictionary(uniqueKeysWithValues: artistSectionLayouts.map { ($0.key.rawValue, $0.value.rawValue) }),
                forKey: Keys.artistLayouts
            )
        }
    }

    func layout(_ section: ArtistSection) -> SectionLayout {
        artistSectionLayouts[section] ?? .grid
    }

    func setLayout(_ layout: SectionLayout, for section: ArtistSection) {
        artistSectionLayouts[section] = Self.layout(layout, allowedFor: section)
    }

    func setAllLayouts(_ layout: SectionLayout) {
        artistSectionLayouts = Dictionary(
            uniqueKeysWithValues: ArtistSection.allCases.map {
                ($0, Self.layout(layout, allowedFor: $0))
            }
        )
    }

    /// Sections without a layout choice still have to store something: off stays off, and anything
    /// else means "shown".
    static func defaultLayout(for section: ArtistSection) -> SectionLayout {
        guard section.allowsLayoutChoice else { return .list }
        switch section {
        case .albums: return .grid
        case .appearsOn, .similarArtists: return .list
        default: return .carousel
        }
    }

    private static func layout(_ layout: SectionLayout, allowedFor section: ArtistSection) -> SectionLayout {
        guard !section.allowsLayoutChoice else { return layout }
        return layout == .off ? .off : .list
    }

    func isEnabled(_ section: ArtistSection) -> Bool {
        layout(section).isOn
    }

    // MARK: Remote Control

    /// Off until the person turns it on — a Debug-only row for now (step 4).
    var remoteAllowControl: Bool {
        didSet { defaults.set(remoteAllowControl, forKey: Keys.remoteAllowControl) }
    }

    /// Empty means "not set yet" — callers fall back to the device's own
    /// name (`UIDevice.current.name`), which this never reads itself so the
    /// setting stays a plain value type.
    var remoteDeviceName: String {
        didSet { defaults.set(remoteDeviceName, forKey: Keys.remoteDeviceName) }
    }

    var remoteKeepScreenOnWhileCharging: Bool {
        didSet { defaults.set(remoteKeepScreenOnWhileCharging, forKey: Keys.remoteKeepScreenOnWhileCharging) }
    }

    var remoteInUse: Bool {
        didSet { defaults.set(remoteInUse, forKey: Keys.remoteInUse) }
    }

    var remoteLocalNetworkAsked: Bool {
        didSet { defaults.set(remoteLocalNetworkAsked, forKey: Keys.remoteLocalNetworkAsked) }
    }

    /// A copy of the Keychain identity's own install marker (`KeychainIdentityStore
    /// .installMarker()`), so a restore from another device's backup can tell it has arrived
    /// somewhere new: the defaults plist travels in iCloud and Finder backups, but…
    var remoteInstallMarker: Data? {
        didSet { defaults.set(remoteInstallMarker, forKey: Keys.remoteInstallMarker) }
    }

    /// Checked once at launch, against the Keychain identity's own marker
    /// (§4.3.1, §4.6.5). A restored backup carries this defaults plist but
    /// not the `ThisDeviceOnly` identity, so a mismatch — including "no
    /// marker stored yet", a fresh install — means every other `remote.*`
    /// key here goes back to its default before anything reads them.
    ///
    /// A `nil` marker is a Keychain that could not be read, and changes
    /// nothing: see `InstallMarkerCheck`. Not retried later in the same run
    /// on purpose. The settings in memory were read at the same moment the
    /// Keychain was unavailable and may be the defaults of a file that could
    /// not be read either, so checking them against a marker that has since
    /// become readable would reset the real settings on disk. The next launch
    /// checks, with both readable.
    func resetIfRestoredElsewhere(currentMarker: Data?) {
        guard InstallMarkerCheck.evaluate(stored: remoteInstallMarker, current: currentMarker) == .restoredElsewhere,
              let currentMarker else { return }
        remoteAllowControl = false
        remoteDeviceName = ""
        remoteKeepScreenOnWhileCharging = false
        remoteInUse = false
        remoteLocalNetworkAsked = false
        remoteInstallMarker = currentMarker
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let playlistsTab = "tabs.playlists"
        static let downloadsTab = "tabs.downloads"
        static let ratingStyle = "ratings.style"
        static let pageStyle = "pages.style"
        static let nowPlayingLayout = "player.layout"
        static let queueRailExpandedLandscape = "player.queueRailExpandedLandscape"
        static let queueRailExpandedPortrait = "player.queueRailExpandedPortrait"
        static let lyrics = "player.lyrics"
        static let playlistStyle = "pages.playlistStyle"
        static let quickSwitchLibraries = "library.quickSwitch"
        static let theme = "app.theme"
        static let appIconName = "app.iconName"
        static let albumDisplay = "pages.albumDisplay"
        static let artistLayouts = "artist.sectionLayouts"
        static let artistOrder = "artist.sectionOrder"
        static let artistEnabled = "artist.sectionsEnabled"
        static let albumReview = "album.showsReview"
        static let albumReviewPosition = "album.reviewPosition"
        static let similarAlbums = "album.similarAlbums"
        static let combineSinglesEPs = "artist.combineSinglesEPs"
        static let equalizerPreset = "audio.equalizerPreset"
        static let equalizerGains = "audio.equalizerGains"
        static let customEqualizerPresets = "audio.customEqualizerPresets"
        static let smartContinue = "player.smartContinuePlaying"
        static let smartContinueByOrigin = "player.smartContinueByOrigin"
        static let limiterEnabled = "audio.limiterEnabled"
        static let smartShuffleByDefault = "player.smartShuffleByDefault"
        static let smartShuffle = "player.smartShuffle"
        static let replayGainMode = "audio.replayGainMode"
        static let replayGainPreamp = "audio.replayGainPreamp"
        static let smartFades = "audio.smartFades"
        static let maxOverlap = "audio.maxOverlapSeconds"
        static let fadeEnvelope = "audio.fadeEnvelope"
        static let keepAlbumsGapless = "audio.keepAlbumsGapless"
        static let fadeThreshold = "audio.fadeThresholdDb"
        static let overlapTrim = "audio.overlapTrimSeconds"
        static let matchSampleRates = "audio.matchSampleRates"
        static let progressStyle = "player.progressStyle"
        static let tintsProgressLikeStars = "player.progressLikeStars"
        static let codecInfo = "player.showsCodecInfo"
        static let confirmStop = "player.confirmsStopAndClear"
        static let remainingTime = "player.showsRemainingTime"
        static let mappingVersion = "library.mappingVersion"
        static let ratingVisibility = "ratings.visibility"
        static let starsWhenRated = "ratings.onlyWhenRated"
        static let ratingsInQueue = "ratings.inQueue"
        static let prefetchWiFi = "audio.prefetchWiFi"
        static let prefetchCellular = "audio.prefetchCellular"
        static let formatBadge = "album.showsFormatBadge"
        static let downloadSort = "downloads.sort"
        static let lastBatch = "downloads.lastBatch"
        static let badgeLossyBitRate = "album.badgeLossyBitRate"
        static let badgeLosslessDetail = "album.badgeLosslessDetail"
        static let trackRowStyle = "tracks.rowStyle"
        static let mediaCacheGB = "audio.cacheGigabytes"
        static let albumsPerRow = "pages.albumsPerRow"
        static let gridDensity = "pages.gridDensity"
        static let collectionGrids = "library.collectionGrids"
        static let seeAllLayout = "library.seeAllLayout"
        static let rollsTitle = "player.rollsTitle"
        static let rollsArtist = "player.rollsArtist"
        static let rollsAlbum = "player.rollsAlbum"
        static let keepConverted = "audio.keepConvertedFiles"
        static let artworkCacheMB = "artwork.cacheMegabytes"
        static let downloadsOverCellular = "downloads.overCellular"
        static let refreshPlaylistsAtLaunch = "downloads.refreshPlaylistsAtLaunch"
        static let refreshDownloadedDetailsAtLaunch = "downloads.refreshDownloadedDetailsAtLaunch"
        static let offlineMode = "downloads.offlineMode"
        static let playlistSorting = "playlists.sorting"
        static let playlistTrackSort = "playlists.trackSort"
        static let radioDecades = "radio.decades"
        static let radioGenres = "radio.genres"
        static let homeOrder = "home.sectionOrder"
        static let homeLayouts = "home.sectionLayouts"
        static let searchResultOrder = "search.resultOrder"
        static let searchAllQuickLibraries = "search.allQuickLibraries"
        static let mergeDownloads = "downloads.mergeLibraries"
        static let homeOff = "home.sectionsOff"
        static let streamTranscode = "audio.streamTranscode"
        static let downloadTranscode = "audio.downloadTranscode"
        static let streamTranscodeCellular = "audio.streamTranscodeCellular"
        static let streamAwayWiFiAsMobile = "audio.streamAwayWiFiAsMobile"
        static let djInsertionCount = "dj.insertionCount"
        // None of these are in `SettingsBackup.carried`
        // on purpose — see `remoteInstallMarker`'s own comment.
        static let remoteAllowControl = "remote.allowControl"
        static let remoteDeviceName = "remote.deviceName"
        static let remoteKeepScreenOnWhileCharging = "remote.keepScreenOnWhileCharging"
        static let remoteInUse = "remote.inUse"
        static let remoteLocalNetworkAsked = "remote.localNetworkAsked"
        static let remoteInstallMarker = "remote.installMarker"
    }

    /// Every setting, read from what was stored or falling back to what a fresh install starts
    /// with.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Before the first read below, and that is the whole reason it is here rather than anywhere
        // tidier.
        SettingsBackupStore.restoreIfUntouched(into: defaults)
        // On unless turned off.
        self.showsPlaylistsTab = defaults.object(forKey: Keys.playlistsTab) as? Bool ?? true
        self.showsDownloadsTab = defaults.object(forKey: Keys.downloadsTab) as? Bool ?? true
        self.ratingStyle = defaults.string(forKey: Keys.ratingStyle)
            .flatMap(RatingStyle.init(rawValue:)) ?? .fiveStarsHalf
        self.showsLyrics = defaults.object(forKey: Keys.lyrics) as? Bool ?? true
        // Off unless turned on — see the property.
        self.nowPlayingLayout = defaults.string(forKey: Keys.nowPlayingLayout)
            .flatMap(NowPlayingLayout.init(rawValue:)) ?? .bleed
        self.queueRailExpandedLandscape = defaults.object(forKey: Keys.queueRailExpandedLandscape) as? Bool ?? true
        self.queueRailExpandedPortrait = defaults.object(forKey: Keys.queueRailExpandedPortrait) as? Bool ?? true
        // Immersive is the default look for album and artist pages.
        self.pageStyle = PageStyle.stored(defaults.string(forKey: Keys.pageStyle))
        // Colour by default here, unlike the pages above: see the property.
        self.playlistPageStyle = defaults.string(forKey: Keys.playlistStyle)
            .flatMap(PageStyle.init(rawValue:)) ?? .immersive
        self.quickSwitchLibraries = defaults.data(forKey: Keys.quickSwitchLibraries)
            .flatMap { try? JSONDecoder().decode([LibrarySelection].self, from: $0) } ?? []
        self.theme = defaults.string(forKey: Keys.theme)
            .flatMap(AppTheme.init(rawValue:)) ?? .system
        self.selectedAppIconName = defaults.string(forKey: Keys.appIconName)
        self.equalizerPresetName = defaults.string(forKey: Keys.equalizerPreset) ?? EqualizerPreset.flat.name
        let savedPresets = defaults.data(forKey: Keys.customEqualizerPresets)
            .flatMap { try? JSONDecoder().decode([EqualizerPreset].self, from: $0) } ?? []
        self.customEqualizerPresets = savedPresets
        // The stored curve, or the curve of whichever preset was chosen the
        // last time there was only a name to go on.
        let chosenName = defaults.string(forKey: Keys.equalizerPreset) ?? EqualizerPreset.flat.name
        let named = (EqualizerPreset.builtIn + savedPresets).first { $0.name == chosenName }
        self.equalizerGainsDB = defaults.array(forKey: Keys.equalizerGains) as? [Double]
            ?? named?.gainsDB
            ?? EqualizerPreset.flat.gainsDB
        self.limiterEnabled = defaults.object(forKey: Keys.limiterEnabled) as? Bool ?? true
        self.smartShuffleByDefault = defaults.object(forKey: Keys.smartShuffleByDefault) as? Bool ?? true
        self.smartShuffle = (defaults.data(forKey: Keys.smartShuffle))
            .flatMap { try? JSONDecoder().decode(SmartShuffleSettings.self, from: $0) }
            ?? SmartShuffleSettings()
        self.smartContinuePlaying = defaults.object(forKey: Keys.smartContinue) as? Bool ?? true
        self.smartContinueByOrigin = (defaults.data(forKey: Keys.smartContinueByOrigin))
            .flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
        self.replayGainMode = defaults.string(forKey: Keys.replayGainMode)
            .flatMap(ReplayGainMode.init(rawValue:)) ?? .track
        self.replayGainPreampDB = defaults.object(forKey: Keys.replayGainPreamp) as? Double ?? 0
        self.smartFades = defaults.object(forKey: Keys.smartFades) as? Bool ?? true
        self.maxOverlapSeconds = defaults.object(forKey: Keys.maxOverlap) as? Double ?? 10
        // An unrecognised stored value falls back to the default, which is
        // also what the one earlier spelling of this mode resolves to — the
        // same mode under a name this app should not have borrowed.
        self.fadeEnvelope = TransitionEnvelope(
            rawValue: defaults.string(forKey: Keys.fadeEnvelope) ?? ""
        ) ?? .overlapOnly
        self.keepAlbumsGapless = defaults.object(forKey: Keys.keepAlbumsGapless) as? Bool ?? true
        self.fadeThresholdDb = defaults.object(forKey: Keys.fadeThreshold) as? Double ?? -17
        self.overlapTrimSeconds = defaults.object(forKey: Keys.overlapTrim) as? Double ?? 0
        self.matchSampleRates = defaults.object(forKey: Keys.matchSampleRates) as? Bool ?? false
        self.tintsProgressLikeStars = defaults.bool(forKey: Keys.tintsProgressLikeStars)
        self.progressStyle = defaults.string(forKey: Keys.progressStyle)
            .flatMap(ProgressStyle.init(rawValue:)) ?? .waveform
        self.showsCodecInfo = defaults.object(forKey: Keys.codecInfo) as? Bool ?? true
        self.showsCodecBadge = defaults.object(forKey: Keys.formatBadge) as? Bool ?? true
        // Newest first to begin with: the reason to open this screen is
        // usually whatever was just fetched.
        self.downloadSorts = defaults.dictionary(forKey: Keys.downloadSort) as? [String: String] ?? [:]
        // Zero means "as it always was": whatever iOS decides for the
        // transfers, and six songs got ready at a time.
        self.lastBatchSummary = defaults.string(forKey: Keys.lastBatch)
        self.djInsertionCount = defaults.object(forKey: Keys.djInsertionCount) as? Int ?? 3
        self.confirmsStopAndClear = defaults.object(forKey: Keys.confirmStop) as? Bool ?? false
        self.showsRemainingTime = defaults.bool(forKey: Keys.remainingTime)
        self.indexMappingVersion = defaults.integer(forKey: Keys.mappingVersion)
        self.showsStarsOnlyWhenRated = defaults.object(forKey: Keys.starsWhenRated) as? Bool ?? true
        self.trackRowStyle = defaults.string(forKey: Keys.trackRowStyle)
            .flatMap(TrackRowStyle.init(rawValue:)) ?? .stars
        // Four gigabytes: a couple of hundred lossless tracks, and small
        // enough not to be a surprise on a 64 GB phone.
        self.mediaCacheGigabytes = defaults.object(forKey: Keys.mediaCacheGB) as? Int ?? 4
        self.albumsPerRow = defaults.object(forKey: Keys.albumsPerRow) as? Int ?? 2
        // An iPad that had picked three across is carried over as high.
        self.highGridDensity = defaults.string(forKey: Keys.gridDensity)
            .map { $0 == "high" } ?? ((defaults.object(forKey: Keys.albumsPerRow) as? Int ?? 2) >= 3)
        self.collectionGridKinds = Set(defaults.array(forKey: Keys.collectionGrids) as? [String] ?? [])
        self.seeAllLayout = defaults.string(forKey: Keys.seeAllLayout) == "grid" ? .grid : .list
        self.rollsTitle = defaults.object(forKey: Keys.rollsTitle) as? Bool ?? true
        self.rollsArtist = defaults.object(forKey: Keys.rollsArtist) as? Bool ?? true
        self.rollsAlbum = defaults.object(forKey: Keys.rollsAlbum) as? Bool ?? true
        self.keepsConvertedFiles = defaults.object(forKey: Keys.keepConverted) as? Bool ?? true
        self.artworkCacheMegabytes = defaults.object(forKey: Keys.artworkCacheMB) as? Int ?? 500
        self.downloadsOverCellular = defaults.object(forKey: Keys.downloadsOverCellular) as? Bool ?? false
        self.refreshPlaylistsAtLaunch = defaults.object(forKey: Keys.refreshPlaylistsAtLaunch) as? Bool ?? true
        self.refreshDownloadedDetailsAtLaunch = defaults.object(forKey: Keys.refreshDownloadedDetailsAtLaunch) as? Bool ?? true
        self.offlineMode = defaults.bool(forKey: Keys.offlineMode)
        self.radioDecades = defaults.array(forKey: Keys.radioDecades) as? [Int] ?? []
        self.radioGenres = defaults.array(forKey: Keys.radioGenres) as? [String] ?? []
        let storedOrder: [HomeSection] = []
        // Anything new since the order was saved joins at the end, so a
        // shelf added in a later version is not lost to an old preference.
        self.homeSectionOrder = storedOrder + HomeSection.builtIns.filter { !storedOrder.contains($0) }
        // No library is known yet either, so there is nothing to load —
        // `useForHome` fills this in once one connects.
        self.homeSectionLayouts = [:]
        // An order saved by an earlier build sits under a per-library key.
        // Kept, once, rather than dropped: the first one found becomes the
        // app's.
        if defaults.object(forKey: Keys.searchResultOrder) == nil,
           let earlier = LibraryBackup.firstScopedValue(of: Keys.searchResultOrder, in: defaults) {
            defaults.set(earlier, forKey: Keys.searchResultOrder)
        }
        let storedSearchOrder = (defaults.array(forKey: Keys.searchResultOrder) as? [String] ?? [])
            .compactMap(SearchResultKind.init(rawValue:))
        self.searchResultOrder = storedSearchOrder
            + SearchResultKind.defaultOrder.filter { !storedSearchOrder.contains($0) }
        self.searchesAllQuickLibraries = defaults.bool(forKey: Keys.searchAllQuickLibraries)
        self.mergesDownloads = defaults.bool(forKey: Keys.mergeDownloads)
        self.homeSectionsOff = []
        self.playlistSorting = PlaylistSorting(
            rawValue: defaults.string(forKey: Keys.playlistSorting) ?? ""
        ) ?? .together
        self.playlistTrackSortRaw = defaults.string(forKey: Keys.playlistTrackSort) ?? ""
        self.ratingVisibility = defaults.string(forKey: Keys.ratingVisibility)
            .flatMap(RatingVisibility.init(rawValue:)) ?? .everywhere
        self.showsRatingsInQueue = defaults.object(forKey: Keys.ratingsInQueue) as? Bool ?? true
        self.prefetchOnWiFi = defaults.object(forKey: Keys.prefetchWiFi) as? Int ?? 15
        self.prefetchOnCellular = defaults.object(forKey: Keys.prefetchCellular) as? Int ?? 3
        self.badgeShowsLossyBitRate = defaults.object(forKey: Keys.badgeLossyBitRate) as? Bool ?? true
        self.badgeShowsLosslessDetail = defaults.object(forKey: Keys.badgeLosslessDetail) as? Bool ?? true
        let streaming = Self.policy(
            from: defaults, key: Keys.streamTranscode, fallback: .streamingDefault
        )
        self.streamingTranscodeWiFi = Self.migrated(streaming)
        // Whatever streaming was set to before there were two of these, so splitting them changes
        // nothing until you say otherwise.
        let cellularFallback = defaults.object(forKey: Keys.streamTranscode) == nil
            ? TranscodePolicy.cellularDefault
            : streaming
        self.streamingTranscodeCellular = Self.migrated(Self.policy(
            from: defaults, key: Keys.streamTranscodeCellular, fallback: cellularFallback
        ))
        self.awayWiFiUsesMobilePolicy = defaults.object(forKey: Keys.streamAwayWiFiAsMobile) as? Bool ?? false
        self.downloadTranscode = Self.migrated(Self.policy(
            from: defaults, key: Keys.downloadTranscode, fallback: .downloadDefault
        ))
        self.combinesSinglesAndEPs = defaults.object(forKey: Keys.combineSinglesEPs) as? Bool ?? true
        self.showsAlbumReview = defaults.object(forKey: Keys.albumReview) as? Bool ?? true
        self.showsSimilarAlbums = defaults.object(forKey: Keys.similarAlbums) as? Bool ?? true
        self.albumReviewPosition = defaults.string(forKey: Keys.albumReviewPosition)
            .flatMap(SectionPosition.init(rawValue:)) ?? .afterTracks

        // Stored order may be missing sections added in a later build, so
        // start from the default order and apply the saved one on top.
        let savedOrder = (defaults.array(forKey: Keys.artistOrder) as? [String] ?? [])
            .compactMap(ArtistSection.init(rawValue:))
        self.artistSectionOrder = savedOrder + ArtistSection.allCases.filter { !savedOrder.contains($0) }

        // Layouts replaced a switch per section plus one layout for the whole
        // page, so a settings file from before the change is read through
        // that older pair rather than thrown away.
        let legacyLayout = defaults.string(forKey: Keys.albumDisplay)
            .flatMap(SectionLayout.init(rawValue:))
        if let saved = defaults.dictionary(forKey: Keys.artistLayouts) as? [String: String] {
            var layouts: [ArtistSection: SectionLayout] = [:]
            for section in ArtistSection.allCases {
                // A section added since this was saved takes its default
                // rather than whatever the rest happened to be set to.
                layouts[section] = saved[section.rawValue]
                    .flatMap(SectionLayout.init(rawValue:))
                    ?? Self.defaultLayout(for: section)
            }
            self.artistSectionLayouts = layouts
        } else if let legacyLayout {
            // Settings from before layouts existed: one layout for the whole
            // page, plus a list of which sections were on.
            let previouslyEnabled = (defaults.array(forKey: Keys.artistEnabled) as? [String])
                .map { Set($0.compactMap(ArtistSection.init(rawValue:))) }
                ?? Set(ArtistSection.allCases)
            self.artistSectionLayouts = Dictionary(
                uniqueKeysWithValues: ArtistSection.allCases.map {
                    ($0, previouslyEnabled.contains($0) ? legacyLayout : .off)
                }
            )
        } else {
            self.artistSectionLayouts = Dictionary(
                uniqueKeysWithValues: ArtistSection.allCases.map {
                    ($0, Self.defaultLayout(for: $0))
                }
            )
        }

        // Off, empty and unasked until the person turns Remote Control on
        // themselves — `resetIfRestoredElsewhere` is what may already have
        // put them back here today, not this read.
        self.remoteAllowControl = defaults.bool(forKey: Keys.remoteAllowControl)
        self.remoteDeviceName = defaults.string(forKey: Keys.remoteDeviceName) ?? ""
        self.remoteKeepScreenOnWhileCharging = defaults.bool(forKey: Keys.remoteKeepScreenOnWhileCharging)
        self.remoteInUse = defaults.bool(forKey: Keys.remoteInUse)
        self.remoteLocalNetworkAsked = defaults.bool(forKey: Keys.remoteLocalNetworkAsked)
        self.remoteInstallMarker = defaults.data(forKey: Keys.remoteInstallMarker)

        Self.forgetTunedGlass(in: defaults)
    }

    /// Throws away the settings from the glass the app briefly let you tune.
    private static func forgetTunedGlass(in defaults: UserDefaults) {
        for key in [
            "appearance.topGlassKind",
            "appearance.topGlassStart",
            "appearance.topGlassFade",
            "appearance.topGlassStrength",
            "appearance.topGlassTakesColour",
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Where stars appear. Rating from a list is quick, but a library you rate
/// rarely does not want a row of stars under every song.
enum RatingVisibility: String, CaseIterable, Identifiable {
    case hidden
    case nowPlaying
    case albumsAndPlaylists
    case everywhere

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hidden: "Hidden"
        case .nowPlaying: "Now Playing"
        case .albumsAndPlaylists: "Albums & playlists"
        case .everywhere: "Everywhere"
        }
    }

    /// The player's own star row.
    var showsOnNowPlaying: Bool { self != .hidden }

    /// Album pages — the tracklist and the album's own rating button — and
    /// playlists.
    var showsInAlbumsAndPlaylists: Bool {
        self == .albumsAndPlaylists || self == .everywhere
    }

    /// Everywhere else a track can be listed: an artist's Popular and My
    /// Favourites, and whatever comes next.
    var showsInOtherLists: Bool { self == .everywhere }
}

enum RatingStyle: String, CaseIterable, Identifiable {
    /// A single star, pinned at the trailing edge beside the duration.
    case singleStar
    /// Five stars, shown beneath the song title where there is room.
    case fiveStars
    /// Five stars set in halves. Offered only where the server stores them:
    /// Subsonic's scale is 1–5 whole stars, so half a star there would be
    /// rounded away on the server and read back as something else.
    case fiveStarsHalf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singleStar: "Single star"
        case .fiveStars: "5 stars"
        case .fiveStarsHalf: "5 stars, half steps"
        }
    }

    var usesHalfStars: Bool { self == .fiveStarsHalf }

    /// The styles this server can actually store.
    static func available(halfStars: Bool) -> [RatingStyle] {
        halfStars ? allCases : allCases.filter { !$0.usesHalfStars }
    }

    /// Whole stars where the server cannot store halves. The stored choice is
    /// left alone, so half steps come back when a server that keeps them is
    /// selected again.
    func resolved(halfStars: Bool) -> RatingStyle {
        usesHalfStars && !halfStars ? .fiveStars : self
    }
}

/// How album and artist pages present themselves: a header layout crossed with a page background.
enum PageStyle: String, CaseIterable, Identifiable {
    /// Full-bleed artwork fading into a colour sampled from it.
    case immersive
    /// Full-bleed artwork dissolving into the same artwork, blurred.
    case blurred

    var id: String { rawValue }

    var label: String {
        switch self {
        case .immersive: "Colour"
        case .blurred: "Blurred"
        }
    }

    /// The page background is the artwork itself, enlarged and blurred —
    /// which sidesteps picking one colour for a cover that has several.
    var usesBlurredBackground: Bool { self == .blurred }

    /// Reads a stored value, including the two styles that no longer exist.
    static func stored(_ raw: String?) -> PageStyle {
        switch raw {
        case "blurred", "standardBlurred": .blurred
        case nil: .blurred
        default: .immersive
        }
    }
}

/// Which appearance the app itself uses, outside the artwork-led pages.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case line
    /// Raw value kept from when this was the only waveform style, so a
    /// setting saved before the curve existed still resolves.
    case waveform
    case curve

    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: "Line"
        case .waveform: "Bars"
        case .curve: "Curve"
        }
    }

    /// Both waveform styles need the track's shape; the plain line does not.
    var needsWaveform: Bool { self != .line }
}

/// How the playing screen is arranged.
enum NowPlayingLayout: String, CaseIterable, Identifiable, Sendable {
    /// The sleeve as a framed square on a dark ground struck from its own
    /// colour, with the words left-aligned beneath it.
    case contained
    /// The same screen with the sleeve full width and dissolving into the
    /// page instead of sitting in a frame.
    case bleed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contained: "Framed"
        case .bleed: "Bleed"
        }
    }

    var caption: String {
        switch self {
        case .contained: "The sleeve framed on a dark ground taken from its own colour, names left-aligned below."
        case .bleed: "The sleeve full width, dissolving into the page rather than ending at an edge."
        }
    }
}

enum SectionPosition: String, CaseIterable, Identifiable {
    case beforeTracks
    case afterTracks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beforeTracks: "Before songs"
        case .afterTracks: "After songs"
        }
    }
}

/// How one artist-page section is shown, `.off` included.
enum SectionLayout: String, CaseIterable, Identifiable {
    case off
    case grid
    case carousel
    case list

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .grid: "Grid"
        case .carousel: "Carousel"
        case .list: "List"
        }
    }

    /// Drawn rather than named on the settings row: four words beside a
    /// section title do not fit a phone, four glyphs do.
    var symbolName: String {
        switch self {
        case .off: "slash.circle"
        case .grid: "square.grid.2x2"
        case .carousel: "rectangle.stack"
        case .list: "list.bullet"
        }
    }

    var isOn: Bool { self != .off }

    /// The album layout this asks for; `.off` sections are never drawn.
    var displayStyle: AlbumDisplayStyle {
        switch self {
        case .carousel: .carousel
        case .list: .list
        case .grid, .off: .grid
        }
    }
}

enum AlbumDisplayStyle: String, CaseIterable, Identifiable {
    /// Wrapping grid: every record visible without scrolling sideways.
    case grid
    /// One row that scrolls horizontally, so a section stays short.
    case carousel
    case list

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid: "Grid"
        case .carousel: "Carousel"
        case .list: "List"
        }
    }
}

/// A section on the artist page. Release-type sections map onto
/// `ReleaseType`, so a server that reports singles or live albums gets them
/// filed separately without any extra plumbing.
enum ArtistSection: String, CaseIterable, Identifiable, Codable {
    case about
    case topTracks
    case favouriteTracks
    case albums
    case singles
    case eps
    case compilations
    case live
    case soundtracks
    case remixes
    case demos
    case appearsOn
    case similarArtists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .about: "About"
        case .topTracks: "Popular"
        case .favouriteTracks: "My Favourites"
        case .albums: "Albums"
        case .singles: "Singles"
        case .eps: "EPs"
        case .compilations: "Compilations"
        case .live: "Live"
        case .soundtracks: "Soundtracks"
        case .remixes: "Remixes"
        case .demos: "Demos"
        case .appearsOn: "Appears On"
        case .similarArtists: "Similar Artists"
        }
    }

    /// Whether a layout is a meaningful question for this section. Prose has
    /// no shape, and the two song shelves are always the same compact list —
    /// for those, the only choice is whether they appear.
    public var allowsLayoutChoice: Bool {
        switch self {
        case .about, .topTracks, .favouriteTracks: false
        default: true
        }
    }

    /// The release category this section displays, if any.
    var releaseType: ReleaseType? {
        switch self {
        case .albums: .album
        case .singles: .single
        case .eps: .ep
        case .compilations: .compilation
        case .live: .live
        case .soundtracks: .soundtrack
        case .remixes: .remix
        case .demos: .demo
        default: nil
        }
    }
}


/// How a song reads in a tracklist: on album pages, in playlists, and in the long Popular and My
/// Favourites lists.
enum TrackRowStyle: String, CaseIterable, Identifiable {
    /// Title, then artist and the five stars sharing the second line.
    case stars
    /// Larger type, and the rating as a number with one star beside the
    /// duration — `2.5 ★` — which opens the full control when tapped.
    case numbered
    /// As `numbered`, with the rating drawn as ten bars that fill up — the
    /// scale Plex actually stores — and the duration moved in beside the
    /// artist to make room for them.
    case bars

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stars: "Stars"
        case .numbered: "Number"
        case .bars: "Bars"
        }
    }

    var verticalPadding: CGFloat {
        self == .stars ? 6 : 9
    }

    var titleFont: Font {
        self == .stars ? .callout.weight(.semibold) : .body.weight(.semibold)
    }

    /// The number down the left.
    var numberFont: Font {
        self == .stars ? .footnote : .body
    }

    /// The duration.
    var durationFont: Font {
        self == .stars ? .caption : .subheadline
    }

    /// The rating shows on the row's own line rather than as five stars
    /// under the title — as a number and a star, or as ten bars.
    var ratingAsNumber: Bool { self != .stars }

    /// Ten bars rather than a number: the same 0–10 the server stores, and
    /// quicker to read down a list than a decimal.
    var ratingAsBars: Bool { self == .bars }

    /// The duration moves in beside the artist, leaving the trailing edge to
    /// the bars.
    var durationBesideArtist: Bool { self == .bars }
}


/// A shelf on the Home screen.
enum SearchResultKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case artists
    case playlists
    case albums
    case songs

    /// Artists, then playlists, then albums, then songs.
    static let defaultOrder: [SearchResultKind] = [.artists, .playlists, .albums, .songs]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .songs: "Songs"
        }
    }
}

enum HomeSection: Hashable, Identifiable, Codable, Sendable {
    case pinned
    case onThisDay
    case recentlyAdded
    case recentlyReleased
    case recentlyPlayed
    case favourites
    case rediscover
    case radio
    case madeForYou
    case editorsChoice
    case spotlight
    case mostListened
    case custom(UUID)

    /// The shelves that come with the app, in the order a new install gets
    /// them.
    static let builtIns: [HomeSection] = [
        .pinned, .onThisDay, .editorsChoice, .spotlight, .madeForYou, .recentlyAdded,
        .recentlyReleased, .recentlyPlayed, .mostListened, .favourites, .rediscover, .radio,
    ]

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .pinned: "pinned"
        case .onThisDay: "onThisDay"
        case .recentlyAdded: "recentlyAdded"
        case .recentlyReleased: "recentlyReleased"
        case .recentlyPlayed: "recentlyPlayed"
        case .favourites: "favourites"
        case .rediscover: "random"
        case .radio: "radio"
        case .madeForYou: "madeForYou"
        case .editorsChoice: "editorsChoice"
        case .spotlight: "spotlight"
        case .mostListened: "mostListened"
        case .custom(let id): "\(Self.customPrefix)\(id.uuidString)"
        }
    }

    private static let customPrefix = "custom:"

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.customPrefix) {
            let raw = String(rawValue.dropFirst(Self.customPrefix.count))
            guard let id = UUID(uuidString: raw) else { return nil }
            self = .custom(id)
            return
        }
        switch rawValue {
        case "pinned": self = .pinned
        case "onThisDay": self = .onThisDay
        case "recentlyAdded": self = .recentlyAdded
        case "recentlyReleased": self = .recentlyReleased
        case "recentlyPlayed": self = .recentlyPlayed
        case "favourites": self = .favourites
        case "random": self = .rediscover
        case "radio": self = .radio
        case "madeForYou": self = .madeForYou
        case "editorsChoice": self = .editorsChoice
        case "spotlight": self = .spotlight
        case "mostListened": self = .mostListened
        default: return nil
        }
    }

    /// The name of a built-in shelf. A custom one is named by the person who
    /// made it, so its title comes from the section itself.
    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .onThisDay: "Released on This Day"
        case .recentlyAdded: "Just Added"
        case .recentlyReleased: "New Releases"
        case .recentlyPlayed: "Recently Played"
        case .favourites: "Favourites"
        case .rediscover: "Rediscover"
        case .radio: "Radio"
        case .madeForYou: "Made for You"
        case .editorsChoice: "Editors' Choice"
        case .spotlight: "Spotlight"
        // The live shelf names the actual month — "Most Listened to in April" — worked out at
        // render time, since the enum itself has no date to draw one from.
        case .mostListened: "Most Listened"
        case .custom: ""
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// Whether this shelf can be drawn as a list, a carousel or a grid.
    var supportsLayoutChoice: Bool {
        switch self {
        case .editorsChoice, .spotlight, .madeForYou, .onThisDay: false
        // Two more that are a design rather than a row of records, for the same reason.
        case .pinned, .mostListened, .recentlyPlayed: false
        case .recentlyAdded, .recentlyReleased,
             .favourites, .rediscover, .radio, .custom:
            true
        }
    }

    var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }

    /// The album query behind the shelf, or nil for the ones that are not
    /// made of albums that way.
    var albumFilter: AlbumFilter? {
        switch self {
        case .recentlyAdded: .recentlyAdded
        case .recentlyReleased: .recentlyReleased
        case .recentlyPlayed: .recentlyPlayed
        case .favourites: .favorites
        case .rediscover: .rediscover
        case .pinned, .onThisDay, .radio, .madeForYou, .editorsChoice, .spotlight, .mostListened,
             .custom:
            nil
        }
    }

    // Stored in preferences as its raw string, so an order saved by an older
    // version still reads.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let section = HomeSection(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown home section \(raw)")
            )
        }
        self = section
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}




/// How the Downloads screen orders what is on the phone.
enum DownloadSort: String, CaseIterable, Identifiable {
    /// When it was fetched, newest first.
    case recentlyDownloaded
    /// By name — the song's, the record's, the artist's.
    case title
    /// By who made it, then by name within each.
    case artist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyDownloaded: "Recently Downloaded"
        case .title: "Title"
        case .artist: "Artist"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyDownloaded: "clock"
        case .title: "textformat"
        case .artist: "music.mic"
        }
    }

    /// What the two directions are called for this field. "A–Z" means
    /// nothing about a date, and "Newest first" means nothing about a name.
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .recentlyDownloaded: ascending ? "Oldest First" : "Newest First"
        case .title, .artist: ascending ? "A – Z" : "Z – A"
        }
    }
}

/// A field and a direction.
struct DownloadOrder: Equatable {
    var field: DownloadSort
    var ascending: Bool

    /// What a shelf starts as, before anybody has said otherwise.
    static func `default`(for shelf: String) -> DownloadOrder {
        switch shelf {
        case "songs": DownloadOrder(field: .recentlyDownloaded, ascending: false)
        default: DownloadOrder(field: .title, ascending: true)
        }
    }
}

/// How a playlist's own songs are ordered on its page.
enum PlaylistSongSort: String, CaseIterable, Identifiable {
    case added
    case artist
    case title
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .added: "Playlist Order"
        case .artist: "Artist"
        case .title: "Song Title"
        case .year: "Year"
        }
    }

    var symbol: String {
        switch self {
        case .added: "list.number"
        case .artist: "music.mic"
        case .title: "textformat"
        case .year: "calendar"
        }
    }

    /// What the two directions are called for this field.
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .added: ascending ? "As Added" : "Reversed"
        case .artist, .title: ascending ? "A – Z" : "Z – A"
        case .year: ascending ? "Oldest First" : "Newest First"
        }
    }
}

/// A field and a direction, for a playlist's own songs.
struct PlaylistTrackOrder: Equatable {
    var field: PlaylistSongSort
    var ascending: Bool

    /// The playlist's own order, top to bottom — what every playlist opens
    /// on until somebody asks for something else.
    static let `default` = PlaylistTrackOrder(field: .added, ascending: true)
}
