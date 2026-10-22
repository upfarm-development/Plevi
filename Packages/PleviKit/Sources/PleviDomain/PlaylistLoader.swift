import Foundation
import Observation

/// A playlist's songs, fetched a page at a time.
@MainActor
@Observable
public final class PlaylistLoader {
    public private(set) var entries: [PlaylistEntry] = []
    /// Bumped whenever `entries` changes, so a screen that derives something expensive from them (a
    /// sorted copy) can tell whether its copy is still good without comparing thousands of rows.
    public private(set) var revision = 0
    /// The playlist as the server describes it now, which is not always how
    /// it was described in the list this screen was opened from.
    public private(set) var header: Playlist?
    /// The playlist's full length. Known before all of it has arrived, so the
    /// screen can say how much is still coming.
    public private(set) var total: Int?
    public private(set) var isLoadingPage = false
    public private(set) var loadedEverything = false
    public private(set) var error: String?
    /// How long everything loaded so far runs for, added up as pages land so
    /// that reading it costs nothing however long the playlist is.
    public private(set) var durationOfLoaded: TimeInterval = 0
    /// False as soon as one song arrives without a length, which makes the
    /// running total an undercount rather than an answer.
    public private(set) var everyDurationKnown = true

    /// Big enough that a page lasts several screens of scrolling, small
    /// enough that the first one lands quickly.
    public static let pageSize = 200
    /// How far from the end of what is loaded the next page is asked for.
    private static let prefetchDistance = 25

    /// True while the songs on screen are the ones kept from the last visit,
    /// shown until the server's own first page arrives and replaces them.
    public private(set) var isShowingKeptPage = false

    private let playlist: Playlist
    private let source: (any PlaylistPageSource)?
    /// Where the first page is kept between visits; nil for a source that is
    /// already on the phone.
    private let store: (any PlaylistPageStoring)?
    /// Counted in rows asked for, not entries kept: see `returnedRows`.
    private var nextOffset = 0
    /// Bumped by `reload`, so a page still in flight from the list that was
    /// thrown away can tell that it is no longer wanted.
    private var generation = 0
    /// The row whose appearance asks for the next page.
    private var prefetchTrigger: PlaylistEntryID?
    /// The page fetch in flight.
    private var pageTask: Task<Void, Never>?

    public init(
        playlist: Playlist,
        source: (any PlaylistPageSource)?,
        store: (any PlaylistPageStoring)? = nil
    ) {
        self.playlist = playlist
        self.source = source
        self.store = store
    }

    /// How many songs the screen should say the playlist has: the real total
    /// where the server gave one, otherwise what has arrived.
    public var songCount: Int { total ?? entries.count }

    public var hasEverything: Bool { loadedEverything }

    public var isEmpty: Bool { entries.isEmpty && loadedEverything }

    /// First page, unless one has already been fetched.
    public func start() async {
        guard entries.isEmpty || isShowingKeptPage, !loadedEverything, error == nil else { return }
        if entries.isEmpty, source != nil, let kept = await store?.page(for: playlist.id),
           entries.isEmpty, !kept.entries.isEmpty {
            // The last visit's songs stand in for the server's until its first
            // page lands. Nothing about paging is touched: the real first page
            // still gets fetched from offset zero and replaces these.
            header = kept.playlist
            total = kept.total
            entries = kept.entries
            durationOfLoaded = kept.entries.reduce(0) { $0 + ($1.track.duration ?? 0) }
            everyDurationKnown = !kept.entries.contains { $0.track.duration == nil }
            isShowingKeptPage = true
            revision &+= 1
        }
        await loadNextPage()
    }

    /// Starts again from the top — after an edit, or a pull to refresh.
    public func reload() async {
        generation += 1
        entries = []
        revision &+= 1
        nextOffset = 0
        loadedEverything = false
        error = nil
        prefetchTrigger = nil
        durationOfLoaded = 0
        everyDurationKnown = true
        // Whatever was in flight belongs to the previous generation and will
        // discard itself; this load owns the flag from here.
        isLoadingPage = false
        pageTask = nil
        isShowingKeptPage = false
        await loadNextPage()
    }

    /// After a page failed: forgets the failure and asks again.
    public func retry() async {
        error = nil
        await loadNextPage()
    }

    /// Called as rows appear.
    public func loadMoreIfNeeded(at entry: PlaylistEntry) async {
        guard entry.entryID == prefetchTrigger else { return }
        await loadNextPage()
    }

    /// Everything, for the things that cannot work with a part of it: shuffling, keeping it
    /// offline, editing its order.
    @discardableResult
    public func loadEverything(onProgress: (Int, Int?) -> Void = { _, _ in }) async -> Bool {
        guard source != nil else { return false }
        while !loadedEverything {
            if Task.isCancelled { return false }
            let generationBefore = generation
            let offsetBefore = nextOffset
            await loadNextPage()
            guard generationBefore == generation else { return false }
            if error != nil { return false }
            // No progress and no end in sight: stop rather than ask the same
            // page for ever.
            guard nextOffset > offsetBefore || loadedEverything else { return false }
            onProgress(entries.count, total)
        }
        return true
    }

    private func loadNextPage() async {
        guard source != nil, !loadedEverything else { return }
        if let running = pageTask {
            await running.value
            return
        }
        let generationAtStart = generation
        isLoadingPage = true
        let task = Task { await fetchPages(generationAtStart: generationAtStart) }
        pageTask = task
        await task.value
    }

    private func fetchPages(generationAtStart: Int) async {
        guard let source else { return }
        do {
            // A page can come back full of rows this app makes nothing of — a video in an audio
            // playlist — and stopping there would leave the list looking shorter than the playlist
            // is.
            while !loadedEverything {
                let offsetBefore = nextOffset
                let page = try await source.playlistPage(
                    id: playlist.id,
                    offset: nextOffset,
                    limit: Self.pageSize
                )
                guard generationAtStart == generation else { return }
                header = page.playlist
                if let total = page.total { self.total = total }
                if isShowingKeptPage {
                    // The first page from the server replaces the kept one
                    // outright, rather than being added to it.
                    entries = page.entries
                    durationOfLoaded = 0
                    everyDurationKnown = true
                    isShowingKeptPage = false
                } else {
                    entries.append(contentsOf: page.entries)
                }
                if offsetBefore == 0, let store {
                    let id = playlist.id
                    Task.detached(priority: .utility) { await store.save(page, for: id) }
                }
                revision &+= 1
                for entry in page.entries {
                    if let seconds = entry.track.duration {
                        durationOfLoaded += seconds
                    } else {
                        everyDurationKnown = false
                    }
                }
                nextOffset += page.returnedRows
                if page.returnedRows < Self.pageSize {
                    loadedEverything = true
                } else if let total = page.total, nextOffset >= total {
                    loadedEverything = true
                }
                if !page.entries.isEmpty { break }
                // A page that moved nothing forward would be asked for again
                // and again, and this runs on the main actor: that is not a
                // slow list, it is a frozen app. Stop instead.
                guard nextOffset > offsetBefore else {
                    loadedEverything = true
                    break
                }
            }
            prefetchTrigger = loadedEverything
                ? nil
                : entries[max(entries.count - Self.prefetchDistance, 0)...].first?.entryID
            error = nil
        } catch {
            guard generationAtStart == generation else { return }
            // A fetch that was called off is not one that failed. Recording
            // it left the list saying "couldn't load" over rows that were
            // simply scrolled away from, with the spinner still turning.
            if !Self.isCancellation(error) {
                self.error = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            }
        }
        // A stale generation leaves the flags alone: the newer load owns them.
        if generationAtStart == generation {
            isLoadingPage = false
            pageTask = nil
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if case .network(let underlying)? = error as? ProviderError, underlying.code == .cancelled {
            return true
        }
        return false
    }
}
