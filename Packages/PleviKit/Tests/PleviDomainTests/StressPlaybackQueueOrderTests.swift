import Foundation
import Testing
@testable import PleviDomain

/// A seeded generator, so a property test is a fact rather than a mood.
private struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Stands in for the app's `QueueItem`: an identity of its own, a track, and
/// the thing the real one carries that a shuffle must not lose.
private struct Entry: Identifiable, Hashable {
    let id: UUID
    var track: Track
    var origin: String?

    init(_ track: Track, origin: String? = nil) {
        self.id = UUID()
        self.track = track
        self.origin = origin
    }
}

private let server = ServerID()

private func song(_ n: Int, rated: Double? = nil) -> Track {
    Track(
        id: MediaID(server: server, rawValue: "t\(n)"),
        title: "Song \(n)",
        albumName: "Album \(n / 12)",
        artistName: "Artist \(n / 40)",
        rating: rated.flatMap(StarRating.init)
    )
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}

// MARK: Shuffle (P-01 / O-01)

@Suite("Shuffling a play queue by position")
struct StressPlaybackShuffleTests {
    @Test("orderedPositions is a permutation of the indices, smart or plain")
    func permutation() {
        let tracks = (0..<500).map { song($0) }
        var generator = Seeded(11)
        for count in [0, 1, 2, 3, 40, 500] {
            let slice = Array(tracks.prefix(count))
            let positions = SmartShuffle.orderedPositions(slice, settings: .init(), using: &generator)
            #expect(positions.sorted() == Array(slice.indices))
        }
    }

    @Test("SmartShuffle.order is the positions applied to the tracks")
    func orderMatchesPositions() {
        let tracks = (0..<200).map { song($0) }
        var first = Seeded(5)
        var second = Seeded(5)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ordered = SmartShuffle.order(tracks, settings: .init(), now: now, using: &first)
        let positions = SmartShuffle.orderedPositions(tracks, settings: .init(), now: now, using: &second)
        #expect(ordered.map(\.id) == positions.map { tracks[$0].id })
    }

    @Test("The same song queued twice keeps two entries, each with its own id and origin")
    func duplicatesKeepTheirOwnEntry() {
        let twice = song(1)
        var items = (2..<60).map { Entry(song($0), origin: $0.isMultiple(of: 3) ? "moody" : nil) }
        let a = Entry(twice, origin: "moody")
        let b = Entry(twice, origin: nil)
        items.insert(a, at: 5)
        items.insert(b, at: 30)

        for smart in [true, false] {
            var generator = Seeded(smart ? 1 : 2)
            let shuffled = QueueOrder.shuffled(
                items, track: \.track, smart: smart, settings: .init(), using: &generator
            )
            #expect(shuffled.count == items.count)
            #expect(Set(shuffled.map(\.id)) == Set(items.map(\.id)))
            // Origin travelled with its own entry, not with the track.
            #expect(shuffled.first { $0.id == a.id }?.origin == "moody")
            #expect(shuffled.first { $0.id == b.id }?.origin == nil)
            #expect(shuffled.filter { $0.track.id == twice.id }.count == 2)
        }
    }

    @Test("A pinned entry comes first and everything else is still there once")
    func pinnedFirst() {
        let items = (0..<300).map { Entry(song($0)) }
        for smart in [true, false] {
            var generator = Seeded(9)
            let shuffled = QueueOrder.shuffled(
                items, track: \.track, smart: smart, settings: .init(), pinned: 123, using: &generator
            )
            #expect(shuffled.first?.id == items[123].id)
            #expect(Set(shuffled.map(\.id)) == Set(items.map(\.id)))
            #expect(shuffled.count == items.count)
        }
    }

    @Test("A pin outside the queue is ignored rather than trapping")
    func pinOutOfRange() {
        let items = (0..<10).map { Entry(song($0)) }
        var generator = Seeded(3)
        let shuffled = QueueOrder.shuffled(
            items, track: \.track, smart: false, settings: .init(), pinned: 99, using: &generator
        )
        #expect(Set(shuffled.map(\.id)) == Set(items.map(\.id)))
    }

    @Test("Shuffling a whole library queue (61,287) stays linear and loses nothing")
    func libraryScale() {
        let items = (0..<61_287).map { Entry(song($0)) }
        var generator = Seeded(21)
        let clock = ContinuousClock()
        var shuffled: [Entry] = []
        // A pinned entry goes through the same path as Shuffle all with a seed.
        let elapsed = clock.measure {
            shuffled = QueueOrder.shuffled(
                items, track: \.track, smart: true, settings: .init(), pinned: 40_000, using: &generator
            )
        }
        print("StressPlayback QueueOrder.shuffled(61,287, smart): \(elapsed)")
        #expect(shuffled.count == items.count)
        #expect(Set(shuffled.map(\.id)).count == items.count)
        #expect(shuffled.first?.id == items[40_000].id)
        // The quadratic version took tens of seconds in a release build. A
        // debug build of the linear one takes a few, so the bound is loose
        // and the scaling test below is the sharper tripwire.
        #expect(elapsed < .seconds(60), "took \(elapsed)")

        var plainGenerator = Seeded(22)
        let plain = clock.measure {
            shuffled = QueueOrder.shuffled(
                items, track: \.track, smart: false, settings: .init(), using: &plainGenerator
            )
        }
        #expect(shuffled.count == items.count)
        #expect(plain < .seconds(10), "plain shuffle took \(plain)")
    }

    @Test("Quadrupling the queue does not cost more than about a dozen times as much")
    func scalesLinearly() {
        func cost(_ count: Int) -> Double {
            let items = (0..<count).map { Entry(song($0)) }
            var best = Double.infinity
            for round in 0..<3 {
                var generator = Seeded(UInt64(round + 1))
                best = min(best, ContinuousClock().measure {
                    _ = QueueOrder.shuffled(
                        items, track: \.track, smart: true, settings: .init(), using: &generator
                    )
                }.seconds)
            }
            return best
        }
        _ = cost(1_000)
        let small = cost(5_000)
        let large = cost(20_000)
        let ratio = large / max(small, 1e-9)
        print("StressPlayback QueueOrder.shuffled 5k -> 20k: \(small)s -> \(large)s, ratio \(ratio)")
        #expect(ratio < 12, "20k took \(ratio)x the time of 5k")
    }
}

// MARK: Un-shuffle (P-06)

@Suite("Putting a shuffled queue back")
struct StressPlaybackUnshuffleTests {
    private static func shuffledQueue(_ count: Int, seed: UInt64 = 1) -> (original: [Entry], shuffled: [Entry]) {
        let original = (0..<count).map { Entry(song($0)) }
        var generator = Seeded(seed)
        let shuffled = QueueOrder.shuffled(
            original, track: \.track, smart: false, settings: .init(), using: &generator
        )
        return (original, shuffled)
    }

    @Test("An untouched shuffled queue goes back exactly")
    func roundTrip() {
        for count in [0, 1, 2, 17, 500] {
            let (original, shuffled) = Self.shuffledQueue(count)
            let restored = QueueOrder.restored(shuffled, originalOrder: original.map(\.id))
            #expect(restored.map(\.id) == original.map(\.id))
        }
    }

    @Test("A song added while shuffled survives un-shuffling")
    func addWhileShuffled() {
        var (original, shuffled) = Self.shuffledQueue(30)
        let order = original.map(\.id)
        let added = Entry(song(999))
        shuffled.append(added)
        let restored = QueueOrder.restored(shuffled, originalOrder: order)
        #expect(restored.count == 31)
        #expect(restored.contains { $0.id == added.id })
        // Everything that was there keeps its original relative order.
        #expect(restored.filter { $0.id != added.id }.map(\.id) == order)
    }

    @Test("A Play Next song stays directly behind the entry it was queued behind")
    func playNextWhileShuffled() {
        var (original, shuffled) = Self.shuffledQueue(30)
        let order = original.map(\.id)
        let playing = 4
        let next = Entry(song(998))
        shuffled.insert(next, at: playing + 1)
        let restored = QueueOrder.restored(shuffled, originalOrder: order)
        let at = restored.firstIndex { $0.id == shuffled[playing].id }!
        #expect(restored[at + 1].id == next.id)
        #expect(restored.count == 31)
    }

    @Test("Rating the playing song while shuffled does not lose it")
    func rateWhileShuffled() {
        var (original, shuffled) = Self.shuffledQueue(30)
        let order = original.map(\.id)
        let playing = shuffled[7]
        shuffled[7].track.rating = StarRating(5)
        // The old lookup compared whole entries, and a rated copy is not
        // equal to the one that was captured before the rating.
        #expect(shuffled[7] != playing)
        let restored = QueueOrder.restored(shuffled, originalOrder: order)
        let index = restored.firstIndex { $0.id == playing.id }
        #expect(index == order.firstIndex(of: playing.id))
        #expect(restored[index!].track.rating == StarRating(5))
    }

    @Test("A removed song stays removed")
    func removeWhileShuffled() {
        var (original, shuffled) = Self.shuffledQueue(30)
        let order = original.map(\.id)
        let gone = shuffled.remove(at: 12)
        let restored = QueueOrder.restored(shuffled, originalOrder: order)
        #expect(!restored.contains { $0.id == gone.id })
        #expect(restored.count == 29)
        #expect(restored.map(\.id) == order.filter { $0 != gone.id })
    }

    @Test("Songs appended past the end, as Smart Continue does, are kept together")
    func appendedAfterTheEnd() {
        var (original, shuffled) = Self.shuffledQueue(10)
        let order = original.map(\.id)
        let extra = (0..<6).map { Entry(song(500 + $0)) }
        shuffled.append(contentsOf: extra)
        let restored = QueueOrder.restored(shuffled, originalOrder: order)
        #expect(Set(restored.map(\.id)) == Set(shuffled.map(\.id)))
        let positions = extra.map { e in restored.firstIndex { $0.id == e.id }! }
        #expect(positions == Array(positions[0]..<(positions[0] + extra.count)))
    }

    @Test("An entry ahead of every ranked one stays at the front")
    func unrankedFirst() {
        let a = Entry(song(1)), b = Entry(song(2)), c = Entry(song(3)), x = Entry(song(4))
        let restored = QueueOrder.restored([x, c, a, b], originalOrder: [a.id, b.id, c.id])
        #expect(restored.map(\.id) == [x.id, a.id, b.id, c.id])
    }

    @Test("An id listed twice in the original order counts once")
    func duplicateIDsInTheOrder() {
        let a = Entry(song(1)), b = Entry(song(2))
        let restored = QueueOrder.restored([b, a], originalOrder: [a.id, b.id, a.id])
        #expect(restored.map(\.id) == [a.id, b.id])
    }

    @Test("Random edits while shuffled never lose or duplicate an entry")
    func propertyRandomEdits() {
        var generator = Seeded(77)
        for round in 0..<200 {
            let count = Int.random(in: 1...40, using: &generator)
            let (original, start) = Self.shuffledQueue(count, seed: UInt64(round + 1))
            let order = original.map(\.id)
            var live = start
            var expected = Set(start.map(\.id))
            for _ in 0..<Int.random(in: 0...12, using: &generator) {
                switch Int.random(in: 0..<4, using: &generator) {
                case 0:
                    let e = Entry(song(10_000 + live.count))
                    live.insert(e, at: Int.random(in: 0...live.count, using: &generator))
                    expected.insert(e.id)
                case 1 where !live.isEmpty:
                    let gone = live.remove(at: Int.random(in: 0..<live.count, using: &generator))
                    expected.remove(gone.id)
                case 2 where !live.isEmpty:
                    live[Int.random(in: 0..<live.count, using: &generator)].track.rating = StarRating(4)
                default:
                    break
                }
            }
            let restored = QueueOrder.restored(live, originalOrder: order)
            #expect(restored.count == live.count)
            #expect(Set(restored.map(\.id)) == expected)
        }
    }

    @Test("Restoring a 61,287 queue is linear")
    func libraryScale() {
        let (original, shuffled) = Self.shuffledQueue(61_287)
        let order = original.map(\.id)
        var restored: [Entry] = []
        let elapsed = ContinuousClock().measure {
            restored = QueueOrder.restored(shuffled, originalOrder: order)
        }
        #expect(restored.map(\.id) == order)
        #expect(elapsed < .seconds(10), "took \(elapsed)")
    }
}

// MARK: Armed next track (P-02)

@Suite("Reconciling the armed next track with the queue")
struct StressPlaybackQueueJoinTests {
    private static func queue(_ n: Int) -> [Entry] { (0..<n).map { Entry(song($0)) } }

    @Test("The next entry is in place")
    func inPlace() {
        let q = Self.queue(5)
        #expect(QueueJoin.status(of: q, currentIndex: 1, armed: q[2].id) == .inPlace)
    }

    @Test("Play Next after arming displaces the armed entry")
    func displaced() {
        var q = Self.queue(5)
        let armed = q[2].id
        q.insert(Entry(song(100)), at: 2)
        #expect(QueueJoin.status(of: q, currentIndex: 1, armed: armed) == .displaced)
    }

    @Test("Removing the armed entry, or clearing Up Next, reports it gone")
    func removed() {
        var q = Self.queue(5)
        let armed = q[2].id
        q.remove(at: 2)
        #expect(QueueJoin.status(of: q, currentIndex: 1, armed: armed) == .removed)
        var cleared = Self.queue(5)
        let armed2 = cleared[2].id
        cleared.removeSubrange(2...)
        #expect(QueueJoin.status(of: cleared, currentIndex: 1, armed: armed2) == .removed)
        #expect(QueueJoin.status(of: cleared, currentIndex: nil, armed: armed2) == .removed)
    }

    @Test("Two entries for one track are told apart by id")
    func duplicatesByID() {
        let t = song(1)
        let a = Entry(t), b = Entry(t)
        let q = [Entry(song(0)), a, b]
        #expect(QueueJoin.status(of: q, currentIndex: 0, armed: b.id) == .displaced)
        #expect(QueueJoin.status(of: q, currentIndex: 0, armed: a.id) == .inPlace)
    }

    @Test("Adopting when the armed entry was displaced puts it right behind the playing one")
    func adoptDisplaced() {
        var q = Self.queue(5)
        let armed = q[2]
        let playNext = Entry(song(100))
        q.insert(playNext, at: 2)
        let index = QueueJoin.adopt(&q, currentIndex: 1, armed: armed)
        #expect(index == 2)
        #expect(q[2].id == armed.id)
        // The song the listener put next still plays right after it.
        #expect(q[3].id == playNext.id)
        #expect(q.count == 6)
    }

    @Test("Adopting when the armed entry was removed puts it back")
    func adoptRemoved() {
        var q = Self.queue(5)
        let armed = q[2]
        q.remove(at: 2)
        let index = QueueJoin.adopt(&q, currentIndex: 1, armed: armed)
        #expect(index == 2)
        #expect(q.map(\.id).contains(armed.id))
        #expect(q.count == 5)
    }

    @Test("Adopting after Clear Up Next puts the armed entry at the end")
    func adoptAfterClear() {
        var q = Self.queue(5)
        let armed = q[2]
        q.removeSubrange(2...)
        let index = QueueJoin.adopt(&q, currentIndex: 1, armed: armed)
        #expect(index == 2)
        #expect(q.count == 3)
        #expect(q[2].id == armed.id)
    }

    @Test("Adopting when the entry is already next changes nothing")
    func adoptInPlace() {
        var q = Self.queue(5)
        let before = q.map(\.id)
        let index = QueueJoin.adopt(&q, currentIndex: 1, armed: q[2])
        #expect(index == 2)
        #expect(q.map(\.id) == before)
    }

    @Test("The armed entry that moved above the playing one is found again by identity")
    func adoptMovedAbove() {
        var q = Self.queue(5)
        let armed = q[2]
        let playing = q[1]
        q.remove(at: 2)
        q.insert(armed, at: 0)
        // The playing entry is now at index 2.
        let index = QueueJoin.adopt(&q, currentIndex: 2, armed: armed)
        #expect(q[index - 1].id == playing.id)
        #expect(q[index].id == armed.id)
        #expect(q.count == 5)
    }

    @Test("Random edits then an advance always land on the armed entry with nothing lost or doubled")
    func propertyAdvance() {
        var generator = Seeded(123)
        for _ in 0..<300 {
            var q = Self.queue(Int.random(in: 2...20, using: &generator))
            let current = Int.random(in: 0..<(q.count - 1), using: &generator)
            let playing = q[current]
            let armed = q[current + 1]
            var expected = Set(q.map(\.id))
            for _ in 0..<Int.random(in: 0...6, using: &generator) {
                switch Int.random(in: 0..<3, using: &generator) {
                case 0:
                    // Play Next, Add to Queue, a DJ insert: anywhere at or
                    // after the playing entry.
                    let e = Entry(song(1_000 + q.count))
                    let at = Int.random(in: (q.firstIndex { $0.id == playing.id }! + 1)...q.count, using: &generator)
                    q.insert(e, at: at)
                    expected.insert(e.id)
                case 1:
                    // Remove or Clear Up Next takes out the armed entry.
                    q.removeAll { $0.id == armed.id }
                    expected.remove(armed.id)
                default:
                    // A removal of something that is neither playing nor armed.
                    if let victim = q.firstIndex(where: { $0.id != playing.id && $0.id != armed.id }) {
                        expected.remove(q.remove(at: victim).id)
                    }
                }
            }
            let playingIndex = q.firstIndex { $0.id == playing.id }!
            let index = QueueJoin.adopt(&q, currentIndex: playingIndex, armed: armed)
            expected.insert(armed.id)
            #expect(q[index].id == armed.id)
            #expect(q[index - 1].id == playing.id)
            #expect(q.count == expected.count)
            #expect(Set(q.map(\.id)) == expected)
        }
    }
}

// MARK: DJ repeat window (O-03)

@Suite("The DJ repeat window's queued half, kept incrementally")
struct StressPlaybackRepeatWindowIncrementalTests {
    private static func tracks(_ range: Range<Int>) -> [Track] {
        range.map { n in
            Track(
                id: MediaID(server: server, rawValue: "w\(n)"),
                title: "Tune \(n)",
                artistName: "Band \(n / 3)"
            )
        }
    }

    private struct Snapshot: Equatable {
        var ids: Set<MediaID>
        var songs: Set<String>
        init(_ w: DJRepeatWindow) { ids = w.excludedIDs; songs = w.excludedSongKeys }
    }

    @Test("setQueued(A) then setQueued(B) is exactly a fresh setQueued(B)")
    func replacesWholesale() {
        let a = Self.tracks(0..<50)
        let b = Self.tracks(30..<90)
        var incremental = DJRepeatWindow()
        incremental.setQueued(a)
        incremental.setQueued(b)
        var fresh = DJRepeatWindow()
        fresh.setQueued(b)
        #expect(Snapshot(incremental) == Snapshot(fresh))
        #expect(!incremental.excludes(a[0].id))
        #expect(!incremental.excludesSong(anyOf: DJRepeatWindow.songKeys(for: a[0])))
    }

    @Test("Two ids sharing a song key keep it excluded until both have left")
    func sharedSongKey() {
        let one = Track(id: MediaID(server: server, rawValue: "x1"), title: "Same Song", artistName: "Same Band")
        let two = Track(id: MediaID(server: server, rawValue: "x2"), title: "Same Song", artistName: "Same Band")
        var w = DJRepeatWindow()
        w.setQueued([one, two])
        w.setQueued([two])
        #expect(w.excludesSong(anyOf: DJRepeatWindow.songKeys(for: one)))
        w.setQueued([Track]())
        #expect(!w.excludesSong(anyOf: DJRepeatWindow.songKeys(for: one)))
        #expect(w.excludedSongKeys.isEmpty)
    }

    @Test("Random queue changes always match a fresh window")
    func propertyMatchesFresh() {
        var generator = Seeded(5)
        let pool = Self.tracks(0..<120)
        var incremental = DJRepeatWindow()
        for _ in 0..<300 {
            let picked = pool.filter { _ in Bool.random(using: &generator) }
            incremental.setQueued(picked)
            var fresh = DJRepeatWindow()
            fresh.setQueued(picked)
            #expect(Snapshot(incremental) == Snapshot(fresh))
        }
    }

    @Test("The same track twice in a queue is one exclusion, and leaves with its last copy")
    func duplicateTracks() {
        let t = Self.tracks(0..<1)[0]
        var w = DJRepeatWindow()
        w.setQueued([t, t])
        #expect(w.excludes(t.id))
        w.setQueued([t])
        #expect(w.excludes(t.id))
        w.setQueued([Track]())
        #expect(!w.excludes(t.id))
        #expect(w.excludedSongKeys.isEmpty)
    }

    @Test("History and queued halves stay independent")
    func historyUntouched() {
        let played = Self.tracks(0..<3)
        var w = DJRepeatWindow()
        for t in played { w.recordPlayed(t) }
        w.setQueued(Self.tracks(10..<12))
        w.setQueued([Track]())
        #expect(w.excludes(played[0].id))
        #expect(!w.excludes(Self.tracks(10..<11)[0].id))
    }

    @Test("A second call over a barely changed 61,287 queue costs far less than the first")
    func secondCallIsCheap() {
        let queue = (0..<61_287).map { n in
            Track(
                id: MediaID(server: server, rawValue: "L\(100_000 + n)"),
                title: "Song number \(n) (Remastered 2011)",
                albumName: "Album \(n / 12)",
                artistName: "Artist \(n / 50)"
            )
        }
        var w = DJRepeatWindow()
        let first = ContinuousClock().measure { w.setQueued(queue) }
        // Drop the first ten, as a run of track advances would.
        let edited = Array(queue.dropFirst(10))
        let second = ContinuousClock().measure { w.setQueued(edited) }
        print("StressPlayback DJRepeatWindow.setQueued 61,287 first \(first), edited \(second)")
        #expect(second.seconds < max(first.seconds / 4, 0.5), "first \(first), edited \(second)")
        #expect(w.excludedIDs.count == 61_277)
        #expect(!w.excludes(queue[0].id))
        #expect(w.excludes(queue[10].id))
    }
}
