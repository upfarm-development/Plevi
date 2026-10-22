import Testing
@testable import PleviAudio

@Suite("Numeric guards")
struct NumericGuardTests {
    @Test("a NaN equaliser gain becomes flat rather than reaching the filters")
    func nanGain() {
        #expect(Equalizer.clamp(.nan) == 0)
        #expect(Equalizer.clamp(40) == Equalizer.maximumGainDB)
        #expect(Equalizer.clamp(-40) == Equalizer.minimumGainDB)
    }
}
