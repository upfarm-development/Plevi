import Foundation
import Testing
@testable import PleviAudio

/// ReplayGain under hostile tags.
@Suite("ReplayGain with hostile tags")
struct StressPlaybackReplayGainTests {
    @Test("A NaN gain tag must not produce a NaN gain")
    func nanTagIsNotPropagated() {
        // P-24: `gainDB` returns NaN for a NaN tag and `linearGain` returns NaN.
        for mode in [ReplayGainMode.track, .album] {
            let db = ReplayGain.gainDB(
                for: ReplayGainTags(trackGainDB: .nan, albumGainDB: .nan),
                mode: mode
            )
            #expect(db.isFinite, "mode \(mode): gain was \(db)")
            let linear = ReplayGain.linearGain(
                for: ReplayGainTags(trackGainDB: .nan, albumGainDB: .nan),
                mode: mode
            )
            #expect(linear.isFinite && linear > 0, "mode \(mode): linear gain was \(linear)")
        }
    }

    @Test("A NaN preamp must not produce a NaN gain")
    func nanPreampIsNotPropagated() {
        let db = ReplayGain.gainDB(
            for: ReplayGainTags(trackGainDB: -6),
            mode: .track,
            preampDB: .nan
        )
        #expect(db.isFinite)
    }

    @Test("Infinite tags are clamped to the documented floor and ceiling")
    func infiniteTagsAreClamped() {
        // No peak: straight to the clamp.
        #expect(ReplayGain.gainDB(for: ReplayGainTags(trackGainDB: .infinity), mode: .track) == 24)
        #expect(ReplayGain.gainDB(for: ReplayGainTags(trackGainDB: -.infinity), mode: .track) == -24)
        // A peak turns +inf into "whatever headroom there is".
        let peak = 0.25
        let headroom = -20 * log10(peak)
        let withPeak = ReplayGain.gainDB(
            for: ReplayGainTags(trackGainDB: .infinity, trackPeak: peak),
            mode: .track
        )
        #expect(abs(withPeak - headroom) < 1e-9)
    }

    @Test("A NaN or non-positive peak is ignored rather than trusted")
    func hostilePeaksAreIgnored() {
        for peak in [Double.nan, 0, -1, -Double.infinity] {
            let db = ReplayGain.gainDB(
                for: ReplayGainTags(trackGainDB: 6, trackPeak: peak),
                mode: .track
            )
            #expect(db == 6, "peak \(peak) changed the gain to \(db)")
        }
    }

    @Test("An infinite peak floors the gain instead of producing NaN")
    func infinitePeakGivesTheFloor() {
        // headroom = -20*log10(inf) = -inf, so any tagged track is pushed to
        // the -24 dB floor. Characterised, not endorsed: a peak of +inf is a
        // corrupt tag and a floor is the least-bad way to read one.
        let db = ReplayGain.gainDB(
            for: ReplayGainTags(trackGainDB: -3, trackPeak: .infinity),
            mode: .track
        )
        #expect(db == ReplayGain.minimumGainDB)
    }

    @Test("Whatever finite figures arrive, the linear gain is finite, positive and bounded")
    func finiteInputsAlwaysGiveASafeMultiplier() {
        let figures: [Double?] = [nil, 0, -0.0, 1, -1, 12, -12, 40, -40, 1e9, -1e9, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        let peaks: [Double?] = [nil, 0, 1e-12, 0.5, 1, 1.5, 100, .greatestFiniteMagnitude]
        let preamps: [Double] = [0, 6, -6, 1e6, -1e6]
        for mode in ReplayGainMode.allCases {
            for track in figures {
                for album in figures {
                    for peak in peaks {
                        for preamp in preamps {
                            let tags = ReplayGainTags(
                                trackGainDB: track, trackPeak: peak, albumGainDB: album, albumPeak: peak
                            )
                            let linear = ReplayGain.linearGain(for: tags, mode: mode, preampDB: preamp)
                            #expect(linear.isFinite && linear > 0, "mode \(mode) tags \(tags) preamp \(preamp) -> \(linear)")
                            // 24 dB is the ceiling: 15.85x. The engine clamps to 4x on top.
                            #expect(linear <= 15.9, "mode \(mode) tags \(tags) preamp \(preamp) -> \(linear)")
                        }
                    }
                }
            }
        }
    }

    @Test("Text the tag parsers accept must not include non-finite numbers")
    func parserRejectsNonFiniteText() {
        // `Double("nan")`, `Double("inf")` and `Double("-inf")` all succeed, so `parseGain` passes
        // them straight through.
        for text in ["nan", "NaN dB", "inf", "-inf dB", "Infinity"] {
            #expect(ReplayGain.parseGain(text) == nil, "\(text) parsed as \(String(describing: ReplayGain.parseGain(text)))")
        }
    }

    @Test("Ordinary tag text still parses")
    func ordinaryTextParses() {
        #expect(ReplayGain.parseGain("-7.30 dB") == -7.3)
        #expect(ReplayGain.parseGain("+3.2") == 3.2)
        #expect(ReplayGain.parseGain("  -0.5 DB ") == -0.5)
        #expect(ReplayGain.parseGain("") == nil)
        #expect(ReplayGain.parseGain("loud") == nil)
        #expect(ReplayGain.parsePeak("0.98") == 0.98)
        #expect(ReplayGain.parsePeak("0") == nil)
        #expect(ReplayGain.parsePeak("-0.2") == nil)
    }
}
