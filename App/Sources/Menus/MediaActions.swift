import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// Shared actions behind the context menus. Resolving tracks is async
/// (albums and artists need their tracks fetched), so every menu action
/// funnels through here rather than duplicating the lookup in each view.
@MainActor
struct MediaActions {
    let app: AppModel
    /// Set only by a caller that must not follow whatever device the user has chosen mid-action —
    /// CarPlay, which always means `.here`.
    private let destinationOverride: PlaybackDestination?

    init(app: AppModel, destination: PlaybackDestination? = nil) {
        self.app = app
        destinationOverride = destination
    }

    // MARK: Resolving tracks

    /// Album tracks in disc/track order — index first, server as fallback.
    func tracks(inAlbum id: MediaID) async -> [Track] {
        // The album's own library: a record found through a search across
        // libraries is not in the open one's index.
        if let index = app.index(for: id.server),
           let detail = try? index.albumDetail(id: id), !detail.tracks.isEmpty {
            return detail.tracks
        }
        guard let provider = app.provider else { return [] }
        return (try? await provider.album(id: id).tracks) ?? []
    }

    /// A playlist's songs, in its own order.
    func tracks(inPlaylist playlist: Playlist) async -> [Track] {
        guard let provider = app.provider else { return [] }
        guard let detail = try? await provider.playlist(id: playlist.id) else {
            app.showTransientError("Couldn't read \u{201C}\(playlist.name)\u{201D}.")
            return []
        }
        return detail.entries.map(\.track)
    }

    /// Every track by an artist, album by album.
    func tracks(byArtist id: MediaID) async -> [Track] {
        var albums: [Album] = []
        if let index = app.index(for: id.server), let indexed = try? index.albums(forArtist: id) {
            albums = indexed
        }
        if albums.isEmpty, let provider = app.provider {
            albums = (try? await provider.artist(id: id).albums) ?? []
        }
        var all: [Track] = []
        for album in albums {
            all.append(contentsOf: await tracks(inAlbum: album.id))
        }
        return all
    }

    // MARK: Keeping

    /// Whether everything in a group is already on the phone.
    func isDownloaded(_ tracks: [MediaID]) -> Bool {
        guard let downloads = app.downloads, !tracks.isEmpty else { return false }
        return tracks.allSatisfy { downloads.isDownloaded($0) }
    }

    func download(album: Album) {
        Task {
            let tracks = await tracks(inAlbum: album.id)
            await app.downloads?.download(tracks, reason: .album(album.id))
            await keepOffline(for: tracks)
        }
    }

    func download(artist: Artist) {
        Task {
            let tracks = await tracks(byArtist: artist.id)
            await app.downloads?.download(tracks, reason: .artist(artist.id))
            await keepOffline(for: tracks)
        }
    }

    func download(track: Track) {
        Task {
            await app.downloads?.download([track], reason: .track(track.id))
            await keepOffline(for: [track])
        }
    }

    func download(playlist: Playlist, tracks: [Track]) {
        Task {
            await app.downloads?.download(playlist: playlist, tracks: tracks)
            await keepOffline(for: tracks)
        }
    }

    /// Fetches everything a kept song needs that is not its audio, at the moment there is certainly
    /// a connection.
    private func keepOffline(for tracks: [Track]) async {
        async let sleeves: Void = keepArtwork(for: tracks)
        async let shapes: Void = keepWaveforms(for: tracks)
        _ = await (sleeves, shapes)
    }

    /// Asks the server for the shape of each song being kept.
    private func keepWaveforms(for tracks: [Track]) async {
        guard let provider = app.provider, let index = app.libraryIndex else { return }
        var seen: Set<String> = []
        for track in tracks {
            if Task.isCancelled { return }
            guard seen.insert(track.id.rawValue).inserted else { continue }
            guard ((try? index.waveform(forTrack: track.id)) ?? nil) == nil else { continue }
            let fetched = try? await provider.loudnessEnvelope(
                for: track.id,
                bars: WaveformSampler.barCount
            )
            guard let bars = fetched ?? nil, !bars.isEmpty else { continue }
            try? index.storeWaveform(bars, forTrack: track.id)
        }
    }

    /// Fetches the sleeves for songs being kept, so they are here when the server is not.
    private func keepArtwork(for tracks: [Track]) async {
        guard let loader = app.artwork else { return }
        var seen: Set<String> = []
        let wanted = tracks.compactMap { track -> ArtworkID? in
            guard let art = track.artwork, seen.insert(art.rawValue).inserted else { return nil }
            return art
        }
        for art in wanted {
            for bucket in Self.keptArtworkBuckets {
                _ = await loader.image(for: art, bucket: bucket)
            }
        }
    }

    /// What the playing screen and the system ask for. See
    /// `ArtworkLoader.buckets` for the sizes these come from.
    private static let keptArtworkBuckets = [640, 1200]

    func removeDownload(album: Album) {
        app.downloads?.removeAlbum(album.id)
        app.removeForeignDownloads(foreignTrackIDs(inAlbum: album.id))
    }

    func removeDownload(artist: Artist) {
        app.downloads?.removeArtist(artist.id)
        app.removeForeignDownloads(foreignTrackIDs(byArtist: artist.id))
    }

    func removeDownload(track: Track) {
        app.downloads?.remove(track: track.id)
        app.removeForeignDownloads([track.id], outright: true)
    }

    /// The songs of an album or an artist of another library, from that
    /// library's own index. Empty for the open library's, whose manager
    /// already knows its own.
    func foreignTrackIDs(inAlbum id: MediaID) -> [MediaID] {
        guard id.server != app.libraryIndex?.server, let index = app.index(for: id.server) else { return [] }
        return ((try? index.tracks(inAlbum: id)) ?? []).map(\.id)
    }

    func foreignTrackIDs(byArtist id: MediaID) -> [MediaID] {
        guard id.server != app.libraryIndex?.server, let index = app.index(for: id.server) else { return [] }
        return ((try? index.tracks(byArtist: id)) ?? []).map(\.id)
    }

    func removeDownload(playlist: Playlist) {
        app.downloads?.remove(reason: .playlist(playlist.id))
    }

    /// Offline, a queue is what can actually play.
    func playable(_ tracks: [Track], destination: PlaybackDestination) -> [Track] {
        guard destination == .here else { return tracks }
        guard app.isOffline, let downloads = app.downloads else { return tracks }
        return tracks.filter { downloads.isDownloaded($0.id) }
    }

    /// `playable`, saying so when offline leaves nothing to add: a menu item
    /// that quietly does nothing reads as a broken one.
    func playableOrSay(_ tracks: [Track], destination: PlaybackDestination) -> [Track] {
        let songs = playable(tracks, destination: destination)
        if songs.isEmpty, !tracks.isEmpty, destination == .here, app.isOffline {
            app.showTransientError("None of these are downloaded.")
        }
        return songs
    }

    // MARK: What the destination can be asked

    /// Whether the destination a starter would send to can take Play Next and Add to Queue.
    var canAddToQueue: Bool {
        app.player(for: destinationOverride ?? app.playbackDestination)?.canEnqueue ?? false
    }

    /// Whether a rating, favourite or radio may go through `id`.
    private func mayWrite(to id: MediaID) -> Bool {
        guard app.isForeignTrack(id) else { return true }
        app.showNote(AppModel.foreignTrackNote)
        return false
    }

    // MARK: Sending to a destination

    /// Hands `body` the player a queue starter meant, resolved *now*.
    private func send(to destination: PlaybackDestination, _ body: (any PlaybackControlling) -> Void) {
        guard let player = app.player(for: destination) else {
            let name = app.remote.lastControlledDeviceName ?? "the other device"
            app.showTransientError("Lost touch with \(name), nothing was sent.")
            return
        }
        body(player)
    }

    // MARK: Playback

    func play(_ tracks: [Track], startingAt index: Int = 0, from origin: QueueOrigin = .songs) {
        let destination = destinationOverride ?? app.playbackDestination
        // Offline, the index refers to the list the caller had; it is
        // recomputed against what is left rather than pointing at a gap.
        let queue = playable(tracks, destination: destination)
        guard !queue.isEmpty else {
            // Offline with none of it on the phone: a play button that does
            // nothing at all reads as a broken button.
            if app.isOffline, !tracks.isEmpty {
                app.showTransientError("None of these are downloaded.")
            }
            return
        }
        let start = index < tracks.count
            ? (queue.firstIndex(where: { $0.id == tracks[index].id }) ?? 0)
            : 0
        send(to: destination) { $0.play(queue, startingAt: start, from: origin) }
    }

    /// Plays one song, then shuffles everything else it came with — the long press on a song's own
    /// menu that used to be a tap to play it, open Now Playing, and tap Shuffle there, none of
    /// which asked the player to keep this particular song first.
    func shuffle(_ tracks: [Track], startingWith seed: Track, from origin: QueueOrigin = .songs) {
        let destination = destinationOverride ?? app.playbackDestination
        let queue = playable(tracks, destination: destination)
        guard !queue.isEmpty else {
            if app.isOffline, !tracks.isEmpty {
                app.showTransientError("None of these are downloaded.")
            }
            return
        }
        // Offline filtering can take the seed itself out — a song the listener does not have cannot
        // lead a queue of the ones they do.
        let pin = queue.contains(where: { $0.id == seed.id }) ? seed : nil
        send(to: destination) { $0.shuffle(queue, startingWith: pin, from: origin, smart: nil) }
    }

    func playAlbum(_ album: Album, shuffled: Bool = false) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let tracks = playable(await tracks(inAlbum: album.id), destination: destination)
            send(to: destination) {
                shuffled
                    ? $0.shuffle(tracks, startingWith: nil, from: .album(album), smart: nil)
                    : $0.play(tracks, startingAt: 0, from: .album(album))
            }
        }
    }

    func playArtist(_ artist: Artist, shuffled: Bool = false, smart: Bool? = nil) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let tracks = playable(await tracks(byArtist: artist.id), destination: destination)
            send(to: destination) {
                shuffled
                    ? $0.shuffle(tracks, startingWith: nil, from: .artist, smart: smart)
                    : $0.play(tracks, startingAt: 0, from: .artist)
            }
        }
    }

    /// Shuffles everything by an artist that nobody has rated yet.
    func playUnrated(artist: Artist) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let all = await tracks(byArtist: artist.id)
            let known = (try? app.libraryIndex?.ratings(forTrackIDs: all.map(\.id))) ?? [:]
            let unrated = all.filter { Self.isUnrated($0, known: known) }
            guard !unrated.isEmpty else {
                app.showTransientError("Nothing by \(artist.name) is waiting to be rated.")
                return
            }
            // Two different nothings, and saying the wrong one sends
            // somebody looking for songs they have already rated.
            let here = playable(unrated, destination: destination)
            guard !here.isEmpty else {
                app.showTransientError("Nothing unrated by \(artist.name) is downloaded.")
                return
            }
            send(to: destination) { $0.shuffle(here, startingWith: nil, from: .artist, smart: nil) }
        }
    }

    /// Whether nobody has said anything about this song yet.
    private static func isUnrated(_ track: Track, known: [String: Double]) -> Bool {
        if let mine = known[track.id.rawValue] { return mine <= 0 }
        return (track.rating?.value ?? 0) <= 0
    }

    /// Everything in a collection, fetched first.
    func playCollection(_ collection: MediaCollection, shuffled: Bool) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            guard let provider = app.provider else { return }
            switch collection.kind {
            case .albums:
                let albums = (try? await provider.albums(inCollection: collection.id)) ?? []
                playCollection(albums: albums, shuffled: shuffled, destination: destination)
            case .artists:
                let artists = (try? await provider.artists(inCollection: collection.id)) ?? []
                playCollection(artists: artists, shuffled: shuffled, destination: destination)
            }
        }
    }

    /// Everything in a collection, in the order it is on screen.
    func playCollection(albums: [Album], shuffled: Bool) {
        playCollection(albums: albums, shuffled: shuffled, destination: destinationOverride ?? app.playbackDestination)
    }

    private func playCollection(albums: [Album], shuffled: Bool, destination: PlaybackDestination) {
        Task {
            var songs: [Track] = []
            for album in albums {
                songs += await tracks(inAlbum: album.id)
            }
            play(collected: playable(songs, destination: destination), shuffled: shuffled, destination: destination)
        }
    }

    func playCollection(artists: [Artist], shuffled: Bool) {
        playCollection(artists: artists, shuffled: shuffled, destination: destinationOverride ?? app.playbackDestination)
    }

    private func playCollection(artists: [Artist], shuffled: Bool, destination: PlaybackDestination) {
        Task {
            var songs: [Track] = []
            for artist in artists {
                songs += await tracks(byArtist: artist.id)
            }
            play(collected: playable(songs, destination: destination), shuffled: shuffled, destination: destination)
        }
    }

    private func play(collected songs: [Track], shuffled: Bool, destination: PlaybackDestination) {
        guard !songs.isEmpty else {
            app.showTransientError("There is nothing here to play.")
            return
        }
        // Played in the order shown, record by record and track by track:
        // "play all" means this collection from the top, not a mix of it.
        // Shuffle is the other button, and is where mixing belongs.
        send(to: destination) {
            if shuffled {
                $0.shuffle(songs, startingWith: nil, from: .radio, smart: nil)
            } else {
                $0.play(songs, startingAt: 0, from: .radio)
            }
        }
    }

    func playNext(album: Album) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let songs = playableOrSay(await tracks(inAlbum: album.id), destination: destination)
            send(to: destination) { $0.playNext(songs) }
        }
    }

    func addToQueue(album: Album) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let songs = playableOrSay(await tracks(inAlbum: album.id), destination: destination)
            send(to: destination) { $0.addToQueue(songs) }
        }
    }

    func playNext(artist: Artist) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let songs = playableOrSay(await tracks(byArtist: artist.id), destination: destination)
            send(to: destination) { $0.playNext(songs) }
        }
    }

    func addToQueue(artist: Artist) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let songs = playableOrSay(await tracks(byArtist: artist.id), destination: destination)
            send(to: destination) { $0.addToQueue(songs) }
        }
    }

    /// Inserts directly after the playing track — the single-track case a
    /// song's own context menu offers.
    func playNext(_ track: Track) {
        let destination = destinationOverride ?? app.playbackDestination
        let songs = playable([track], destination: destination)
        guard !songs.isEmpty else {
            app.showTransientError("None of these are downloaded.")
            return
        }
        send(to: destination) { $0.playNext(songs) }
    }

    /// Appends to the end of the queue — the single-track case a song's own
    /// context menu offers.
    func addToQueue(_ track: Track) {
        let destination = destinationOverride ?? app.playbackDestination
        let songs = playable([track], destination: destination)
        guard !songs.isEmpty else {
            app.showTransientError("None of these are downloaded.")
            return
        }
        send(to: destination) { $0.addToQueue(songs) }
    }

    /// Holds the same artist, and the same record, apart in a station's running order.
    func spacedForRadio(_ tracks: [Track]) -> [Track] {
        SmartShuffle.space(tracks, settings: app.settings.smartShuffle)
    }

    /// Starts a station from a song: the song itself, then everything the
    /// server considers similar.
    func startRadio(from track: Track) {
        guard let provider = app.provider,
              provider.capabilities.contains(.similarItems)
        else { return }
        guard mayWrite(to: track.id) else { return }
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            // Both questions at once, because the second one is new and a station should not have
            // got slower to start for it.
            async let similarly = provider.similarTracks(to: track.id, limit: 50)
            async let catalogue = ownCatalogue(forSeed: track)

            let similar = (try? await similarly) ?? []
            guard !similar.isEmpty else {
                // Said before the wait rather than after it.
                app.showTransientError("No similar songs found for \(track.title).")
                _ = await catalogue
                return
            }
            let company = Self.keepingKin(
                fitToFollow(similar, seeds: [track]),
                seededByArtistNamed: track.artistName.map(DJRepeatWindow.leadArtist(of:)),
                index: app.libraryIndex,
                minimumKept: Self.fewestSongsForAStation
            )
            guard !company.isEmpty else {
                app.showTransientError("No similar songs found for \(track.title).")
                _ = await catalogue
                return
            }
            // And the rest of what this artist has, which "similar to this" almost never answers
            // with — ask a server what sounds like a song and it names other people.
            let kin = Self.ownCompany(
                await catalogue, forSeed: track, alreadyHere: company
            )
            // Sized against the company that is *not* already this artist.
            let songs = Self.interleaved(
                own: ownForStation(
                    kin, againstCompany: Self.strangers(in: company, to: track)
                ),
                rest: company
            )
            // The seed stays where it is; what follows it is spaced, since
            // a server's nearest neighbours are very often several songs off
            // the same record.
            send(to: destination) { $0.play([track] + spacedForRadio(songs), startingAt: 0, from: .radio) }
        }
    }

    /// The rest of a seed song's artist, for a station started from that song.
    private func ownCatalogue(forSeed track: Track) async -> [Track] {
        guard let artistID = track.artistID, let credit = track.artistName else { return [] }
        // "Various Artists" is not an artist.
        guard !CompilationHeuristics.isVariousArtists(credit) else { return [] }
        // And the credit is the wrong thing to ask, which is worth spelling out because asking it
        // looks right.
        guard let index = app.libraryIndex,
              let filed = try? index.artist(id: artistID),
              !CompilationHeuristics.isVariousArtists(filed.name),
              DJRepeatWindow.leadArtist(of: filed.name)
                  == DJRepeatWindow.leadArtist(of: credit)
        else { return [] }
        return await tracks(byArtist: artistID)
    }

    /// What of that catalogue a station started from this song may use.
    private static func ownCompany(
        _ catalogue: [Track], forSeed track: Track, alreadyHere company: [Track]
    ) -> [Track] {
        guard let credit = track.artistName else { return [] }
        let lead = DJRepeatWindow.leadArtist(of: credit)
        var seen = Set(([track] + company).compactMap(DJRepeatWindow.songKey(for:)))
        return catalogue.filter { candidate in
            // By id as well as by song key: a track with no credit at all
            // has no key, and the seed would otherwise come back and play
            // twice — once where it was put, and again a few songs in.
            guard candidate.id != track.id else { return false }
            // The catalogue is looked up by the record's artist, so even off a compilation that is
            // not Various Artists it can answer with somebody else.
            guard let theirs = candidate.artistName,
                  DJRepeatWindow.leadArtist(of: theirs) == lead
            else { return false }
            guard let key = DJRepeatWindow.songKey(for: candidate) else { return false }
            return seen.insert(key).inserted
        }
    }

    /// How much of a station's company is somebody other than its seed.
    private static func strangers(in company: [Track], to track: Track) -> Int {
        guard let credit = track.artistName else { return company.count }
        let lead = DJRepeatWindow.leadArtist(of: credit)
        return company.filter { candidate in
            guard let theirs = candidate.artistName else { return true }
            return DJRepeatWindow.leadArtist(of: theirs) != lead
        }.count
    }

    /// Starts a station from an artist: their own songs, and everything the server considers to
    /// sound like them.
    func startRadio(fromArtist artist: Artist) {
        guard let provider = app.provider,
              provider.capabilities.contains(.similarItems)
        else { return }
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let own = (try? await tracks(byArtist: artist.id)) ?? []
            let seeds = Self.radioSeeds(from: own)
            guard !seeds.isEmpty else {
                app.showTransientError("Nothing by \(artist.name) to start a station from.")
                return
            }
            let neighbours = await withTaskGroup(of: [Track].self) { group in
                for seed in seeds {
                    group.addTask {
                        (try? await provider.similarTracks(
                            to: seed.id, limit: SmartContinue.neighboursPerSeed
                        )) ?? []
                    }
                }
                var all: [[Track]] = []
                for await similar in group where !similar.isEmpty { all.append(similar) }
                return all
            }
            let ownIDs = Set(own.map(\.id))
            let lead = DJRepeatWindow.leadArtist(of: artist.name)
            // The neighbours are what makes this a station rather than the artist on shuffle — but
            // only the neighbours are drawn from here, because the artist's own songs are added
            // back below deliberately rather than left to whatever the server happened…
            let similar = Self.keepingKin(
                fitToFollow(
                    SmartContinue.blend(neighbours, excluding: [], limit: 120)
                        .filter { candidate in
                            guard !ownIDs.contains(candidate.id) else { return false }
                            // By credit as well as by id, because the id only catches the copy this
                            // artist's own records hold.
                            guard let theirs = candidate.artistName else { return true }
                            return DJRepeatWindow.leadArtist(of: theirs) != lead
                        },
                    seeds: seeds
                ),
                seededByArtistNamed: artist.name,
                index: app.libraryIndex,
                minimumKept: Self.fewestSongsForAStation
            )
            guard !similar.isEmpty else {
                app.showTransientError("No similar songs found for \(artist.name).")
                return
            }
            // Their own songs are the subject of this station, and used to be four of them in a
            // hundred and twenty: the seeds, and nothing else of theirs, because everything of
            // theirs was filtered out of the company above and never put back.
            let songs = Self.interleaved(
                own: ownForStation(own, againstCompany: similar.count),
                rest: similar
            )
            send(to: destination) { $0.play(spacedForRadio(songs), startingAt: 0, from: .radio) }
        }
    }

    /// A handful of an artist's own songs to ask the server about.
    private static func radioSeeds(from own: [Track], count: Int = 4) -> [Track] {
        var generator = SystemRandomNumberGenerator()
        // One copy of each recording first.
        var seen: Set<String> = []
        let distinct = own.filter { track in
            guard let key = DJRepeatWindow.songKey(for: track) else { return true }
            return seen.insert(key).inserted
        }
        return drawSpread(distinct, count: count, using: &generator)
    }

    /// How much more likely one of an artist's songs is to be drawn than
    /// another.
    ///
    /// Rating first, because a station of somebody should open on what you
    /// thought was worth keeping. Play count second and gently, on a log,
    /// because play counts are heavily skewed and weighting by the raw
    /// number would hand every station to the one song played four hundred
    /// times.
    ///
    /// Unrated sits low but real, and that matters more here than anywhere
    /// else in the app: most libraries are mostly unrated, and for an artist
    /// nobody has rated at all every weight here is equal — which is exactly
    /// right, because then the draw is an even one over their whole
    /// catalogue and the station is different every time you ask. A song
    /// marked down is not excluded either, only made unlikely; `fitToFollow`
    /// is where a rating floor belongs, and it is applied to the company
    /// rather than to the seeds.
    private static func seedWeight(_ track: Track) -> Double {
        let plays = log(Double(max(track.playCount ?? 0, 0)) + 1)
        guard let rating = track.rating?.value else { return 1 + plays }
        let regard: Double
        if rating >= 4.5 { regard = 12 }
        else if rating >= 4 { regard = 8 }
        else if rating >= 3.5 { regard = 4 }
        else if rating >= 3 { regard = 2 }
        else if rating > 0 { regard = 0.5 }
        else { regard = 1 }
        return regard + plays
    }

    /// How many of the artist's own songs a station can actually carry.
    private func ownAllowance(againstCompany company: Int) -> Int {
        let gap = max(0, app.settings.smartShuffle.artistSpacing)
        // Spacing turned off: nothing to stay inside of, so a plain share.
        guard gap > 0 else { return max(1, Int((Double(company) * 0.3).rounded())) }
        return max(1, company / (gap + 1))
    }

    /// The artist's own songs a station should carry, given how much company it has.
    private func ownForStation(_ own: [Track], againstCompany company: Int) -> [Track] {
        guard !own.isEmpty else { return [] }
        let wanted = ownAllowance(againstCompany: company)
        // One copy of each recording.
        var seenSongs: Set<String> = []
        let distinct = own.filter { track in
            guard let key = DJRepeatWindow.songKey(for: track) else { return true }
            return seenSongs.insert(key).inserted
        }
        let known = (try? app.libraryIndex?.ratings(forTrackIDs: distinct.map(\.id))) ?? [:]
        let liked = distinct.filter { Self.isWorthMixing($0, known: known) }
        // Topped up rather than swapped out.
        let likedIDs = Set(liked.map(\.id))
        var generator = SystemRandomNumberGenerator()
        // Drawn rather than taken off the top, for the reason `radioSeeds` sets out at length.
        let chosen = Self.drawSpread(liked, count: wanted, using: &generator)
        guard chosen.count < wanted else { return chosen }
        let others = distinct.filter { !likedIDs.contains($0.id) }
        return chosen + Self.drawSpread(
            others, count: wanted - chosen.count, using: &generator
        )
    }

    /// A weighted draw that still covers the records.
    private static func drawSpread(
        _ tracks: [Track],
        count: Int,
        using generator: inout some RandomNumberGenerator
    ) -> [Track] {
        guard count > 0, !tracks.isEmpty else { return [] }
        var byRecord: [String: [Track]] = [:]
        for track in tracks {
            byRecord[track.albumName ?? track.id.rawValue, default: []].append(track)
        }
        var representatives: [Track] = []
        var leftovers: [Track] = []
        for songs in byRecord.values {
            let standing = SmartShuffle.drawing(
                songs, count: 1, using: &generator, weight: seedWeight
            )
            representatives.append(contentsOf: standing)
            let taken = Set(standing.map(\.id))
            leftovers.append(contentsOf: songs.filter { !taken.contains($0.id) })
        }
        let first = SmartShuffle.drawing(
            representatives, count: count, using: &generator, weight: seedWeight
        )
        guard first.count < count else { return first }
        return first + SmartShuffle.drawing(
            leftovers, count: count - first.count, using: &generator, weight: seedWeight
        )
    }

    /// Plays one of the Made for You mixes.
    private static func soundsRelated(
        _ track: Track,
        toArtistTokens seed: Set<String>,
        seedEra: Int?,
        tags: [String: Set<String>],
        eras: [String: Int]
    ) -> Bool {
        let artist = track.artistName?.lowercased()
        guard EraAffinity.belongs(candidate: artist.flatMap { eras[$0] }, withSeed: seedEra) else { return false }
        guard !seed.isEmpty else {
            // No genre vocabulary to check, only an era — kept on that alone
            // rather than dropped for a test that has nothing to say about
            // it.
            return true
        }
        var vocabulary = GenreAffinity.tokens(of: track.genre ?? "")
        if let artist, let theirs = tags[artist] {
            vocabulary.formUnion(GenreAffinity.tokens(of: theirs))
        }
        return GenreAffinity.belongs(candidate: vocabulary, withSeed: seed)
    }

    /// Drops the records among `songs` that merely *sound* like the artist named `seedArtist` — see
    /// `soundsRelated`.
    private static func keepingKin(
        _ songs: [Track],
        seededByArtistNamed seedArtist: String?,
        index: LibraryIndex?,
        minimumKept: Int
    ) -> [Track] {
        // The rating gate applies regardless, including where the genre and
        // era test has nothing to say.
        let known = (try? index?.ratings(forTrackIDs: songs.map(\.id))) ?? [:]
        let listenable = songs.filter { Self.isWorthMixing($0, known: known ?? [:]) }
        guard let seedArtist, let index
        else { return listenable.isEmpty ? songs : listenable }

        // Cached per sync: both maps cover the whole library and were read
        // on the main actor on every radio and mix start.
        let tags = (try? index.cachedGenreTagsByArtist()) ?? [:]
        let seed = GenreAffinity.tokens(of: tags[seedArtist.lowercased()] ?? [])
        let eras = (try? index.cachedActiveEraByArtist()) ?? [:]
        let seedEra = eras[seedArtist.lowercased()]
        // Nothing to check either artist against — the genre/era analysis
        // has nothing more to say, same as when there were no tags to begin
        // with. The rating gate still applies: `listenable`, not `songs`.
        guard !seed.isEmpty || seedEra != nil else { return listenable.isEmpty ? songs : listenable }

        var kept: [Track] = []
        for track in songs {
            guard Self.isWorthMixing(track, known: known ?? [:]) else { continue }
            guard Self.soundsRelated(
                track, toArtistTokens: seed, seedEra: seedEra, tags: tags, eras: eras
            ) else { continue }
            kept.append(track)
        }
        // Not all or nothing.
        guard kept.count < minimumKept else { return kept }
        let keptIDs = Set(kept.map(\.id))
        // Topping up never reaches past the rating gate: a song you have
        // told the app you dislike is not a song to fall back on.
        return kept + listenable.filter { !keptIDs.contains($0.id) }
    }

    /// Below this a filtered set is too thin to be a mix on its own.
    private static let fewestForAMix = 12

    /// Spreads a handful of songs evenly through a longer list, rather than clustering them at the
    /// start or tacking them on the end — a mix seeded on an artist should sound like them every so
    /// often through the whole thing, not front-load or…
    private static func interleaved(own: [Track], rest: [Track]) -> [Track] {
        guard !own.isEmpty else { return rest }
        guard !rest.isEmpty else { return own }
        // A share rather than a whole-number step.
        let share = Double(rest.count + 1) / Double(own.count + 1)
        var result: [Track] = []
        var next = 0
        for (offset, track) in rest.enumerated() {
            result.append(track)
            while next < own.count, Double(offset + 1) >= share * Double(next + 1) {
                result.append(own[next])
                next += 1
            }
        }
        // Anything not yet placed — a short `rest` can run out of slots
        // before every own song has one — goes on the end rather than
        // being dropped.
        result.append(contentsOf: own[next...])
        return result
    }

    /// Whether a song is one you would want to meet again.
    private func fitToFollow(_ candidates: [Track], seeds: [Track]) -> [Track] {
        var seen = Set(seeds.compactMap(DJRepeatWindow.songKey(for:)))
        var deduped: [Track] = []
        for track in candidates {
            guard let key = DJRepeatWindow.songKey(for: track) else {
                deduped.append(track)
                continue
            }
            guard seen.insert(key).inserted else { continue }
            deduped.append(track)
        }

        let known = (try? app.libraryIndex?.ratings(forTrackIDs: deduped.map(\.id))) ?? [:]
        let listenable = deduped.filter { Self.isWorthMixing($0, known: known ?? [:]) }
        return listenable.count >= Self.fewestSongsForAStation ? listenable : deduped
    }

    /// Below this the rating floor is dropped rather than left to hand back
    /// four songs and call it a station.
    private static let fewestSongsForAStation = 10

    private static func isWorthMixing(_ track: Track, known: [String: Double]) -> Bool {
        // The app's own mirror first: a star given a moment ago is here
        // before the server has caught up with it.
        if let mine = known[track.id.rawValue] { return mine >= Self.fewestStarsForAMix }
        guard let rating = track.rating else { return true }
        return rating.value >= Self.fewestStarsForAMix
    }

    /// Two and a half. Two is "no"; two and a half is the first mark that is
    /// not.
    private static let fewestStarsForAMix: Double = 2.5

    func playMix(_ mix: MadeForYou.Mix, seeds: [MediaID]) {
        let destination = destinationOverride ?? app.playbackDestination
        Task {
            let songs = await mixSongs(mix, seeds: seeds)
            guard !songs.isEmpty else { return }
            send(to: destination) { $0.play(songs, startingAt: 0, from: .radio(named: mix.title)) }
        }
    }

    /// Keeps today's version of a mix, as a playlist on the server.
    func saveMixAsPlaylist(_ mix: MadeForYou.Mix, seeds: [MediaID]) {
        Task {
            let songs = await mixSongs(mix, seeds: seeds)
            guard !songs.isEmpty else { return }
            app.requestAddToPlaylist(songs, suggesting: Self.playlistName(for: mix.title))
        }
    }

    /// What a mix saved today should be called.
    static func playlistName(for title: String, on date: Date = .now) -> String {
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        return "\(title) Mix — \(day)"
    }

    /// The songs a mix holds today, without playing them.
    private func mixSongs(_ mix: MadeForYou.Mix, seeds: [MediaID]) async -> [Track] {
        // A genre mix is the library answering, not the server: the whole point of asking for one
        // decade of one genre is the constraint, and "what sounds like this song" does not keep to
        // it — seeded from a fifties jazz record it will happily offer…
        if case .tag(_, let decade, let members) = mix.kind {
            return songsFromLibrary(genres: members, decade: decade, named: mix.title)
        }
        guard let provider = app.provider,
              provider.capabilities.contains(.similarItems),
              !seeds.isEmpty
        else { return [] }
        // All at once: three seeds asked one after another is three round trips before a note is
        // heard, and on a home server over a slow link that is the difference between a mix
        // starting and a card that seems not to have worked.
        let neighbours = await withTaskGroup(of: [Track].self) { group in
            for seed in seeds {
                group.addTask {
                    (try? await provider.similarTracks(
                        to: seed,
                        limit: SmartContinue.neighboursPerSeed
                    )) ?? []
                }
            }
            var all: [[Track]] = []
            for await similar in group where !similar.isEmpty { all.append(similar) }
            return all
        }
        // A mix hands off once it's through the real substance of it — to Smart Continue if the
        // listener has it on for radio, to a DJ if one is running, or simply to whatever comes next
        // in the queue.
        let blended = SmartContinue.blend(neighbours, excluding: [], limit: 120)
        let cap = 25
        // A mix seeded on an artist should actually sound like them now and again, not just like
        // their neighbours — the seeds are already their own well-loved songs, so they cost nothing
        // extra to fetch and place a few of them back in.
        let own = seeds.compactMap { try? app.libraryIndex?.track(id: $0) }.prefix(3)
        let ownIDs = Set(own.map(\.id))
        var seedArtistName: String?
        if case .artist(let name, _, _) = mix.kind { seedArtistName = name }
        let similar = Self.keepingKin(
            blended, seededByArtistNamed: seedArtistName, index: app.libraryIndex,
            minimumKept: Self.fewestForAMix
        )
        .filter { !ownIDs.contains($0.id) }
        .prefix(cap - own.count)
        let songs = Self.interleaved(own: Array(own), rest: Array(similar))
        guard !songs.isEmpty else {
            app.showTransientError("No mix could be made from \(mix.title) just now.")
            return []
        }
        return spacedForRadio(songs)
    }

    /// Everything the library has of a genre, or of one decade of it,
    /// shuffled and thinned so no artist crowds the front.
    private func songsFromLibrary(genres: [String], decade: Int?, named name: String) -> [Track] {
        guard let index = app.libraryIndex else { return [] }
        let songs = (try? index.mixTracks(
            .genresInDecade(genres: genres, decade: decade),
            downloadedOnly: app.isOffline
        )) ?? []
        guard !songs.isEmpty else {
            app.showTransientError("Nothing in your library for \(name) just now.")
            return []
        }
        return spacedForRadio(songs)
    }

    // MARK: Favourites

    /// Same write-through as favourites. `nil` clears the rating.
    /// Whether this server keeps half stars, for the rating menu.
    var allowsHalfStars: Bool {
        app.provider?.capabilities.contains(.halfStarRatings) ?? false
    }

    /// Taken locally first, then sent — or kept until it can be.
    func setRating(_ rating: StarRating?, id: MediaID) {
        guard let provider = app.provider,
              provider.capabilities.contains(.ratings)
        else { return }
        guard mayWrite(to: id) else { return }
        let index = app.libraryIndex
        // What is on screen changes at once, and none of it waits for the database: the star is
        // drawn from the queue's own copy and from what this device has rated since, both set here.
        app.player.applyRating(rating, to: id)
        app.noteRated(rating, id: id)
        app.remote.controlledPlayer?.reflectRating(rating, for: id)
        Task {
            let previous = await app.indexWriter.perform { () -> StarRating? in
                let before = (try? index?.mirroredRating(for: id)) ?? nil
                try? index?.mirrorRating(rating, for: id)
                return before
            }
            // The index has it now, so what reads the index can be told.
            app.remote.controlledPlayer?.refreshFromLibrary()
            app.bumpLibraryVersion()
            let refusal: (any Error)?
            if let outbox = app.outbox {
                if case .refused(let error) = await outbox.rate(rating, id: id) {
                    refusal = error
                } else {
                    refusal = nil
                }
            } else {
                do {
                    try await provider.setRating(rating, for: id)
                    refusal = nil
                } catch {
                    refusal = error
                }
            }
            guard let refusal else { return }
            app.reportTransientError(refusal)
            // Only while the index still shows this tap: someone who has
            // chosen again since has not been refused.
            if (try? index?.revertRating(to: previous, for: id, ifShowing: rating)) == true {
                app.player.applyRating(previous, to: id)
                app.remote.controlledPlayer?.refreshFromLibrary()
                app.remote.controlledPlayer?.reflectRating(previous, for: id)
                app.bumpLibraryVersion()
            }
        }
    }

    /// Taken locally first, like the rating: the heart fills at once, and
    /// goes back with a message if the server refuses it for good.
    func setFavorite(_ favorite: Bool, id: MediaID, kind: MediaKind) {
        guard let provider = app.provider,
              provider.capabilities.contains(.favorites)
        else { return }
        guard kind != .track || mayWrite(to: id) else { return }
        let index = app.libraryIndex
        // As for a rating: the screen first, the database after.
        if kind == .track {
            app.player.applyFavorite(favorite, to: id)
            app.remote.controlledPlayer?.reflectFavorite(favorite, for: id)
        }
        Task {
            let previous = await app.indexWriter.perform { () -> Bool in
                let before = (try? index?.mirroredFavorite(for: id, kind: kind)) ?? !favorite
                try? index?.mirrorFavorite(favorite, for: id, kind: kind)
                return before
            }
            if kind == .track { app.remote.controlledPlayer?.refreshFromLibrary() }
            app.bumpLibraryVersion()
            let refusal: (any Error)?
            if let outbox = app.outbox {
                if case .refused(let error) = await outbox.favorite(favorite, id: id, kind: kind) {
                    refusal = error
                } else {
                    refusal = nil
                }
            } else {
                do {
                    try await provider.setFavorite(favorite, for: id, kind: kind)
                    refusal = nil
                } catch {
                    refusal = error
                }
            }
            guard let refusal else { return }
            app.reportTransientError(refusal)
            if (try? index?.revertFavorite(to: previous, for: id, kind: kind, ifShowing: favorite)) == true {
                if kind == .track {
                    app.player.applyFavorite(previous, to: id)
                    app.remote.controlledPlayer?.refreshFromLibrary()
                    app.remote.controlledPlayer?.reflectFavorite(previous, for: id)
                }
                app.bumpLibraryVersion()
            }
        }
    }
}

/// One entry in the rating menu.
struct RatingMenuStep {
    let value: Double
    let label: String

    static func all(halfSteps: Bool) -> [RatingMenuStep] {
        let values: [Double] = halfSteps
            ? [5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5]
            : [5, 4, 3, 2, 1]
        return values.map {
            RatingMenuStep(
                value: $0,
                label: $0 == $0.rounded()
                    ? String(repeating: "★", count: Int($0))
                    : String(repeating: "★", count: Int($0)) + "½"
            )
        }
    }
}

// MARK: - Menus

extension View {
    /// A song's menu, wherever it is long-pressed — and in the same order as
    /// an album's: play it, queue it, keep it, file it, say what you think of
    /// it, then go to where it came from.
    func trackContextMenu(
        _ track: Track,
        actions: MediaActions,
        onShuffleRest: (() -> Void)? = nil,
        onGoToAlbum: (() -> Void)? = nil,
        onGoToArtist: (() -> Void)? = nil
    ) -> some View {
        contextMenu {
            // Glyphs on one row rather than words on two — the same
            // arrangement as an album's and an artist's menu, so a long
            // press reaches for the same place whatever it landed on.
            ControlGroup {
                Button("Play", systemImage: "play.fill") {
                    actions.play([track])
                }
                // Nil wherever a shuffle needs more than this one song to mean anything — a single
                // search result, an Up Next row — rather than every call site deciding for itself
                // whether it has enough around the track to offer this at all.
                if let onShuffleRest {
                    Button("Shuffle", systemImage: "shuffle", action: onShuffleRest)
                }
                if actions.app.provider?.capabilities.contains(.similarItems) == true {
                    Button("Song Radio", systemImage: "dot.radiowaves.left.and.right") {
                        actions.startRadio(from: track)
                    }
                }
            }
            .controlGroupStyle(.compactMenu)

            if actions.canAddToQueue {
                ControlGroup {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        actions.playNext(track)
                    }
                    Button("Add to Queue", systemImage: "text.append") {
                        actions.addToQueue(track)
                    }
                }
                .controlGroupStyle(.compactMenu)
            }

            if actions.app.downloads != nil {
                Divider()
                if actions.app.downloads?.isDownloaded(track.id) == true {
                    Button("Remove Download", systemImage: "trash", role: .destructive) {
                        actions.removeDownload(track: track)
                    }
                } else {
                    Button("Download", systemImage: "arrow.down.circle") {
                        actions.download(track: track)
                    }
                }
            }

            if actions.app.provider?.capabilities.contains(.playlists) == true {
                Divider()
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    actions.app.requestAddToPlaylist([track])
                }
            }

            Divider()
            if actions.app.provider?.capabilities.contains(.favorites) == true {
                Button(
                    track.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                    systemImage: track.isFavorite ? "heart.slash" : "heart"
                ) {
                    actions.setFavorite(!track.isFavorite, id: track.id, kind: .track)
                }
            }
            if actions.app.provider?.capabilities.contains(.ratings) == true {
                // The only way to rate a song whose stars are hidden, and a
                // faster one than aiming at a star even when they are not.
                RatingMenu(
                    title: "Rate",
                    current: track.rating,
                    allowsHalfStars: actions.allowsHalfStars
                ) { newRating in
                    actions.setRating(newRating, id: track.id)
                }
            }

            if onGoToAlbum != nil || onGoToArtist != nil {
                Divider()
                if let onGoToAlbum {
                    Button("Go to Album", systemImage: "square.stack", action: onGoToAlbum)
                }
                if onGoToArtist != nil {
                    GoToArtistMenuItems(track: track, actions: actions, fallback: onGoToArtist)
                }
            }
        }
    }

    /// The menu, attached to whatever it is put on.
    func albumContextMenu(_ album: Album, actions: MediaActions) -> some View {
        contextMenu { AlbumMenuContent(album: album, actions: actions) }
    }

    func artistContextMenu(_ artist: Artist, actions: MediaActions) -> some View {
        contextMenu { ArtistMenuContent(artist: artist, actions: actions) }
    }
}

extension MediaActions {
    /// The artists a track's credit names that the library actually holds — "Berliner
    /// Philharmoniker & Herbert von Karajan & Edvard Grieg" is a question with up to three right
    /// answers, and one artist is only the whole of it when the credit does…
    func creditedArtists(for track: Track) -> [Artist] {
        guard let credit = track.artistName, let index = app.libraryIndex else { return [] }
        return CreditedArtists.named(in: credit) { try? index.artist(named: $0) }
    }
}

/// "Go to Artist", or a choice of them where the credit names several.
private struct GoToArtistMenuItems: View {
    let track: Track
    let actions: MediaActions
    let fallback: (() -> Void)?

    var body: some View {
        let credited = actions.creditedArtists(for: track)
        if credited.count > 1 {
            Menu("Go to Artist", systemImage: "music.mic") {
                ForEach(credited) { artist in
                    Button(artist.name) {
                        actions.app.requestNavigation(.artist(artist.id, name: artist.name))
                    }
                }
            }
        } else if let only = credited.first {
            Button("Go to Artist", systemImage: "music.mic") {
                actions.app.requestNavigation(.artist(only.id, name: only.name))
            }
        } else if let fallback {
            Button("Go to Artist", systemImage: "music.mic", action: fallback)
        }
    }
}
