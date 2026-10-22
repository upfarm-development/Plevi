import Testing
@testable import PleviAudio

@Suite("Render clock arithmetic")
struct RenderClockTests {
    @Test("a 48 kHz file on a 44.1 kHz output takes 8% fewer node frames")
    func differentRates() {
        // The numbers from a playback log: 11,971,901 frames of a 48 kHz file,
        // all of which the node, at 44.1 kHz, had played by sample time
        // 11,005,956 — not 11,971,901.
        let frames = RenderClock.nodeFrames(fileFrames: 11_971_901, fileRate: 48_000, nodeRate: 44_100)
        #expect(abs(frames - 10_999_184) < 2)
    }

    @Test("the same rate leaves the count as it is")
    func sameRate() {
        #expect(RenderClock.nodeFrames(fileFrames: 1_000_000, fileRate: 44_100, nodeRate: 44_100) == 1_000_000)
    }

    @Test("a rate that is not known leaves the count as it is, and nothing negative")
    func unknownRate() {
        #expect(RenderClock.nodeFrames(fileFrames: 500, fileRate: 0, nodeRate: 44_100) == 500)
        #expect(RenderClock.nodeFrames(fileFrames: -10, fileRate: 48_000, nodeRate: 44_100) == 0)
    }
}
