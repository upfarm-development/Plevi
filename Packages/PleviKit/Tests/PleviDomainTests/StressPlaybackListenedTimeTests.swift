import Foundation
import Testing
@testable import PleviDomain

@Suite("Counting listening rather than position")
struct StressPlaybackListenedTimeTests {
    /// Plays for `seconds` of real time, reporting every half second.
    private static func play(_ listened: inout ListenedTime, from start: TimeInterval, for seconds: TimeInterval) -> TimeInterval {
        var position = start
        listened.tick(position: position)
        var remaining = seconds
        while remaining > 0 {
            position += 0.5
            remaining -= 0.5
            listened.tick(position: position)
        }
        return position
    }

    @Test("Listening through half of a song counts")
    func throughHalf() {
        var listened = ListenedTime()
        _ = Self.play(&listened, from: 0, for: 100)
        #expect(listened.seconds == 100)
        #expect(listened.countsAsPlayed(duration: 200))
        #expect(!listened.countsAsPlayed(duration: 201))
    }

    @Test("Seeking past the middle and hearing a moment of it does not")
    func seekPastHalf() {
        var listened = ListenedTime()
        var position = Self.play(&listened, from: 0, for: 5)
        listened.tick(position: 150)      // scrubbed to 2:30 of a 4:00 song
        position = 150
        listened.tick(position: position + 0.5)
        #expect(listened.seconds < 6)
        #expect(!listened.countsAsPlayed(duration: 240))
    }

    @Test("A song scrubbed to its end is not a play")
    func scrubbedToTheEnd() {
        var listened = ListenedTime()
        _ = Self.play(&listened, from: 0, for: 3)
        listened.tick(position: 238)
        listened.tick(position: 239.5)
        #expect(!listened.countsAsPlayed(duration: 240))
    }

    @Test("Rewinding and listening again adds only the new listening")
    func rewind() {
        var listened = ListenedTime()
        var position = Self.play(&listened, from: 0, for: 60)
        listened.tick(position: 10)       // back to 0:10
        position = Self.play(&listened, from: 10, for: 20)
        _ = position
        #expect(listened.seconds == 80)
    }

    @Test("A stall of a few ticks still counts, a jump does not")
    func gaps() {
        var listened = ListenedTime()
        listened.tick(position: 0)
        listened.tick(position: 1.5)      // a busy main thread missed three ticks
        #expect(listened.seconds == 1.5)
        listened.tick(position: 60)
        #expect(listened.seconds == 1.5)
    }

    @Test("noteJump makes the next tick a fresh start")
    func noteJump() {
        var listened = ListenedTime()
        listened.tick(position: 0)
        listened.tick(position: 1)
        listened.noteJump()
        listened.tick(position: 1.5)      // would have been 0.5 more, but the position is unknown
        #expect(listened.seconds == 1)
        listened.tick(position: 2)
        #expect(listened.seconds == 1.5)
    }

    @Test("The bar is capped at four minutes however long the song")
    func capped() {
        var listened = ListenedTime()
        _ = Self.play(&listened, from: 0, for: 240)
        #expect(listened.countsAsPlayed(duration: 7_200))
        var short = ListenedTime()
        _ = Self.play(&short, from: 0, for: 239)
        #expect(!short.countsAsPlayed(duration: 7_200))
    }

    @Test("A song of unknown length cannot be judged, so it counts")
    func unknownLength() {
        let listened = ListenedTime()
        #expect(listened.countsAsPlayed(duration: nil))
        #expect(listened.countsAsPlayed(duration: 0))
        #expect(listened.countsAsPlayed(duration: .nan))
    }

    @Test("Reset forgets everything")
    func reset() {
        var listened = ListenedTime()
        _ = Self.play(&listened, from: 0, for: 30)
        listened.reset()
        #expect(listened.seconds == 0)
        listened.tick(position: 100)
        #expect(listened.seconds == 0)
    }

    @Test("Hostile positions add nothing")
    func hostile() {
        var listened = ListenedTime()
        listened.tick(position: 0)
        for position in [Double.nan, .infinity, -.infinity, -5] {
            listened.tick(position: position)
        }
        #expect(listened.seconds == 0)
    }
}
