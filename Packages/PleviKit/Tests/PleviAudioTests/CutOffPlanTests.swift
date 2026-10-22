import Foundation
import Testing
@testable import PleviAudio

@Suite("A fetch that dies once the song has started")
struct CutOffPlanTests {
    @Test("At the very start, with a retry to spare, the song is fetched again")
    func fetchesAgainAtTheStart() {
        // Half a second in, 38 seconds of a 163-second song had arrived.
        #expect(CutOffPlan.action(heard: 0.4, arrived: 38.5, expected: 163, canRetry: true) == .fetchAgain)
        #expect(CutOffPlan.action(heard: 0, arrived: nil, expected: 163, canRetry: true) == .fetchAgain)
        #expect(CutOffPlan.action(heard: 4.9, arrived: 20, expected: nil, canRetry: true) == .fetchAgain)
    }

    @Test("Once the song is under way what arrived is played out")
    func playsOutOnceUnderWay() {
        #expect(CutOffPlan.action(heard: CutOffPlan.earlySeconds, arrived: 38.5, expected: 163, canRetry: true) == .playOutWhatArrived)
        #expect(CutOffPlan.action(heard: 60, arrived: 90, expected: 163, canRetry: true) == .playOutWhatArrived)
    }

    @Test("With no go left, or a failure a second go cannot cure, what arrived is played out")
    func playsOutWhenThereIsNoRetry() {
        #expect(CutOffPlan.action(heard: 0.4, arrived: 38.5, expected: 163, canRetry: false) == .playOutWhatArrived)
    }

    @Test("A song that has all but arrived is played, not fetched again")
    func playsAnAlmostCompleteSong() {
        #expect(CutOffPlan.action(heard: 0.4, arrived: 162, expected: 163, canRetry: true) == .playOutWhatArrived)
        #expect(CutOffPlan.action(heard: 0.4, arrived: 163, expected: 163, canRetry: true) == .playOutWhatArrived)
        // A short one: the allowance is a second at least.
        #expect(CutOffPlan.action(heard: 0.4, arrived: 29.2, expected: 30, canRetry: true) == .playOutWhatArrived)
        #expect(CutOffPlan.action(heard: 0.4, arrived: 20, expected: 30, canRetry: true) == .fetchAgain)
    }
}
