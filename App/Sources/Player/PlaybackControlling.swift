import Foundation
import Observation
import PleviDomain

/// A guard against sending a queue edit into a queue that has since moved on.
struct QueueMark: Equatable, Sendable { let id: UUID? }

/// What every Now Playing surface actually needs from whatever is playing — `PlayerModel` for local
/// playback, `RemotePlayer` for another device's.
@MainActor
protocol PlaybackControlling: AnyObject, Observable {
    var queue: [QueueItem] { get }
    var currentIndex: Int? { get }
    var currentItem: QueueItem? { get }
    var currentTrack: Track? { get }
    var history: [QueueItem] { get }
    var queueOrigin: QueueOrigin { get }
    func upNext(limit: Int) -> [QueueItem]
    var upNextCount: Int { get }
    var hasUpNext: Bool { get }
    var hasNext: Bool { get }
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var positionJumps: Int { get }
    var lastError: String? { get }
    var repeatMode: RepeatMode { get }
    var isShuffled: Bool { get }
    var smartContinueForThisQueue: Bool { get set }
    var playingFormat: PlayingAudioFormat? { get }
    /// Whether streaming follows the mobile-data policy rather than the
    /// Wi-Fi one: on cellular, or on Wi-Fi away from home when that is asked.
    var streamsWithMobilePolicy: Bool { get }
    var isSleepTimerActive: Bool { get }
    var sleepsAtEndOfTrack: Bool { get }
    var sleepMinutesRemaining: Int? { get }
    /// `nil`: no slider — a phone's own volume is the system's. Set when
    /// the destination is another device that offers one.
    var offeredVolume: Float? { get }
    /// `false`: Up Next is read-only — no tap, swipe, drag or Clear.
    var canEditQueue: Bool { get }
    /// Whether the tracks this player shows are songs of *this* device's own library, so rating
    /// one, favouriting it, filing it in a playlist or starting a radio from it acts on the song it
    /// names.
    var canActOnLibrary: Bool { get }
    /// Whether Play Next and Add to Queue can be offered: `true` here, and for a
    /// controlled device only when it takes `enqueue` (an older build does not).
    var canEnqueue: Bool { get }

    func resume()
    func pause()
    func togglePlayPause()
    func next(automatic: Bool)
    func previous()
    func seek(to seconds: TimeInterval)
    func stop()
    func play(_ item: QueueItem)
    func playAgain(_ item: QueueItem)
    func removeQueueItem(_ item: QueueItem)
    func moveQueueItems(fromOffsets: IndexSet, toOffset: Int)
    func clearUpNext()
    func clearHistory()
    func cycleRepeatMode()
    func toggleShuffle()
    func startSleepTimer(minutes: Int)
    func sleepAtEndOfTrack()
    func cancelSleepTimer()
    func setOfferedVolume(_ volume: Float)

    func play(_ tracks: [Track], startingAt index: Int, from origin: QueueOrigin)
    func shuffle(_ tracks: [Track], startingWith seed: Track?, from origin: QueueOrigin, smart: Bool?)
    func playNext(_ tracks: [Track])
    func addToQueue(_ tracks: [Track])
    /// `PlaylistsView`'s existing queue-token guard, asked of whichever
    /// destination is about to receive the rest of a large playlist.
    func queueMark() -> QueueMark
    func append(_ tracks: [Track], ifStill mark: QueueMark)
    /// The sleeve to draw for a song this player shows, in the queue or as
    /// the one playing. The song's own artwork, except where this device has
    /// the file and the picture inside it is not the album's cover.
    func artwork(for track: Track) -> ArtworkID?
}

extension PlaybackControlling {
    func artwork(for track: Track) -> ArtworkID? { track.artwork }
}

extension PlayerModel: PlaybackControlling {
    /// A phone's own volume is the system's — there is nothing here to
    /// offer a slider for.
    var offeredVolume: Float? { nil }
    func setOfferedVolume(_ volume: Float) {}

    func queueMark() -> QueueMark { QueueMark(id: queue.first?.id) }

    func append(_ tracks: [Track], ifStill mark: QueueMark) {
        guard queue.first?.id == mark.id else { return }
        addToQueue(tracks)
    }

    var canEditQueue: Bool { true }
    var canActOnLibrary: Bool { true }
    var canEnqueue: Bool { true }
}

/// The kinds of playback failure Remote Control reports (§4.5.5).
enum PlaybackFailureKind: Sendable, Equatable {
    /// The song could not be played: a stream that failed, a server that
    /// refused, an engine that gave up.
    case failed
    /// Offline, and none of what was asked for is downloaded.
    case nothingPlayable
    /// Started from a remote command while the app is in the background,
    /// which the system does not allow (§4.6.3).
    case cannotStartInBackground
}
