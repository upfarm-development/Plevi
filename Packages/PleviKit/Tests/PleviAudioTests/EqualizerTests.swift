import Foundation
import Testing
import PleviAudio

@Suite struct EqualizerTests {
    @Test func hasTenBandsOnTheISOOctaveSeries() {
        #expect(Equalizer.bandCount == 10)
        #expect(Equalizer.bandFrequencies.first == 32)
        #expect(Equalizer.bandFrequencies.last == 16_000)
    }

    @Test func bandsAscendByRoughlyAnOctave() {
        for (low, high) in zip(Equalizer.bandFrequencies, Equalizer.bandFrequencies.dropFirst()) {
            #expect(abs(high / low - 2) < 0.05, "\(low) → \(high)")
        }
    }

    @Test func labelsReadTheWayAnEqualiserIsLabelled() {
        #expect(Equalizer.label(forFrequency: 32) == "32")
        #expect(Equalizer.label(forFrequency: 500) == "500")
        #expect(Equalizer.label(forFrequency: 1_000) == "1k")
        #expect(Equalizer.label(forFrequency: 16_000) == "16k")
        #expect(Equalizer.label(forFrequency: 1_500) == "1.5k")
    }

    @Test func gainsAreClampedToTheUsableRange() {
        #expect(Equalizer.clamp(40) == Equalizer.maximumGainDB)
        #expect(Equalizer.clamp(-40) == Equalizer.minimumGainDB)
        #expect(Equalizer.clamp(3) == 3)
    }

    // MARK: Presets

    @Test func everyPresetCoversEveryBand() {
        for preset in EqualizerPreset.builtIn {
            #expect(preset.gainsDB.count == Equalizer.bandCount, "\(preset.name)")
        }
    }

    @Test func everyPresetStaysInsideTheUsableRange() {
        for preset in EqualizerPreset.builtIn {
            for gain in preset.gainsDB {
                #expect(gain >= Equalizer.minimumGainDB && gain <= Equalizer.maximumGainDB, "\(preset.name)")
            }
        }
    }

    @Test func flatIsFlatAndIsTheFirstChoice() {
        #expect(EqualizerPreset.flat.isFlat)
        #expect(EqualizerPreset.builtIn.first == .flat)
        #expect(EqualizerPreset.builtIn.dropFirst().allSatisfy { !$0.isFlat })
    }

    @Test func presetNamesAreUnique() {
        let names = EqualizerPreset.builtIn.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// A curve from anywhere — a file, a future import — must not be able to
    /// produce a graph that misbehaves.
    @Test func aTooShortCurveIsPaddedFlat() {
        let preset = EqualizerPreset(name: "Short", gainsDB: [3, 3])
        #expect(preset.gainsDB.count == Equalizer.bandCount)
        #expect(preset.gainsDB.dropFirst(2).allSatisfy { $0 == 0 })
    }

    @Test func aTooLongCurveIsTrimmed() {
        let preset = EqualizerPreset(name: "Long", gainsDB: Array(repeating: 2, count: 20))
        #expect(preset.gainsDB.count == Equalizer.bandCount)
    }

    @Test func anExtremeCurveIsClampedOnTheWayIn() {
        let preset = EqualizerPreset(name: "Wild", gainsDB: Array(repeating: 99, count: 10))
        #expect(preset.gainsDB.allSatisfy { $0 == Equalizer.maximumGainDB })
    }

    @Test func roundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(EqualizerPreset.builtIn)
        let decoded = try JSONDecoder().decode([EqualizerPreset].self, from: data)
        #expect(decoded == EqualizerPreset.builtIn)
    }
}
