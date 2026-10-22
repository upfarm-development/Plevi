import Foundation
import Testing
@testable import PleviDomain

/// What the DJ's repeat window costs when the queue it watches is a whole library.
@Suite("The DJ repeat window on a library-sized queue")
struct StressPlaybackDJScaleTests {
    private static let server = ServerID()

    private static func library(_ count: Int) -> [Track] {
        (0..<count).map { n in
            Track(
                id: MediaID(server: server, rawValue: "\(100_000 + n)"),
                title: "Song number \(n) (Remastered 2011)",
                albumName: "Album \(n / 12)",
                artistName: n.isMultiple(of: 7) ? "Artist \(n / 50) feat. Guest \(n % 13)" : "Artist \(n / 50)"
            )
        }
    }

    @Test("Keeping 61,287 queued songs in the window is linear work, and here is what it costs")
    func setQueuedAtLibrarySize() {
        let tracks = Self.library(61_287)
        var window = DJRepeatWindow()
        let clock = ContinuousClock()
        let elapsed = clock.measure { window.setQueued(tracks) }
        print("StressPlayback DJRepeatWindow.setQueued(\(tracks.count)): \(elapsed)")
        #expect(elapsed < .seconds(60), "took \(elapsed)")
        #expect(window.excludedIDs.count == tracks.count)
        // Everything queued is excluded, whether asked for by id or by recording.
        #expect(window.excludes(tracks[0].id) && window.excludes(tracks[61_286].id))
        #expect(window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: tracks[12_345])))
    }

    @Test("Quadrupling the queue does not cost more than about a dozen times as much")
    func scalesLinearly() {
        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        }
        /// Best of three, so one busy moment on a shared machine is not read as a trend.
        func cost(_ count: Int) -> Double {
            let tracks = Self.library(count)
            var best = Double.infinity
            for _ in 0..<3 {
                var window = DJRepeatWindow()
                best = min(best, seconds(ContinuousClock().measure { window.setQueued(tracks) }))
            }
            return best
        }
        _ = cost(1_000) // warm-up: first use of the string tables
        let small = cost(5_000)
        let large = cost(20_000)
        let ratio = large / max(small, 1e-9)
        print("StressPlayback DJRepeatWindow.setQueued 5k -> 20k: \(small)s -> \(large)s, ratio \(ratio)")
        // 4x the songs. Linear work is 4x; quadratic would be 16x. The bound
        // sits between them, high enough for allocator and cache noise.
        #expect(ratio < 12, "20k took \(ratio)x the time of 5k")
    }

    @Test("Replacing the queued half wholesale forgets songs that left the queue")
    func setQueuedReplaces() {
        let tracks = Self.library(100)
        var window = DJRepeatWindow()
        window.setQueued(tracks)
        window.setQueued(Array(tracks[50...]))
        #expect(!window.excludes(tracks[0].id))
        #expect(window.excludes(tracks[99].id))
        window.setQueued([Track]())
        #expect(window.excludedIDs.isEmpty)
    }

    @Test("The played half ages out: the fifty-first song back is no longer forbidden")
    func historyAges() {
        let tracks = Self.library(60)
        var window = DJRepeatWindow()
        for track in tracks { window.recordPlayed(track) }
        #expect(!window.excludes(tracks[0].id))
        #expect(window.excludes(tracks[59].id))
        #expect(window.excludedIDs.count == window.historyCapacity)
    }
}
