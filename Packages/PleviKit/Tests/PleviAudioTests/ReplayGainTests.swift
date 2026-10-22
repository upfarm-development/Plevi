import Foundation
import Testing
import PleviAudio

@Suite struct ReplayGainTests {
    private let quiet = ReplayGainTags(trackGainDB: 6, trackPeak: 0.5, albumGainDB: 4, albumPeak: 0.6)
    private let loud = ReplayGainTags(trackGainDB: -8, trackPeak: 1.0, albumGainDB: -7, albumPeak: 1.0)

    @Test func offAppliesNothingAtAll() {
        #expect(ReplayGain.gainDB(for: quiet, mode: .off) == 0)
        #expect(ReplayGain.gainDB(for: loud, mode: .off) == 0)
    }

    @Test func trackModeUsesTheTrackGain() {
        #expect(ReplayGain.gainDB(for: quiet, mode: .track) == 6)
    }

    @Test func albumModeUsesTheAlbumGain() {
        #expect(ReplayGain.gainDB(for: quiet, mode: .album) == 4)
    }

    /// Plenty of files carry one tag and not the other; levelling by the one
    /// that is there beats levelling by nothing.
    @Test func albumModeFallsBackToTheTrackGain() {
        let trackOnly = ReplayGainTags(trackGainDB: -3, trackPeak: 0.9)
        #expect(ReplayGain.gainDB(for: trackOnly, mode: .album) == -3)
    }

    @Test func trackModeFallsBackToTheAlbumGain() {
        let albumOnly = ReplayGainTags(albumGainDB: -3, albumPeak: 0.9)
        #expect(ReplayGain.gainDB(for: albumOnly, mode: .track) == -3)
    }

    @Test func anUntaggedFilePlaysUntouched() {
        #expect(ReplayGain.gainDB(for: ReplayGainTags(), mode: .track) == 0)
        #expect(ReplayGain.gainDB(for: ReplayGainTags(), mode: .album) == 0)
    }

    // MARK: Clipping

    /// The whole reason peaks are in the tags: a boost on a track that
    /// already touches full scale would distort it.
    @Test func aBoostIsHeldBackByTheTrackPeak() {
        let hot = ReplayGainTags(trackGainDB: 9, trackPeak: 1.0)
        #expect(ReplayGain.gainDB(for: hot, mode: .track) == 0)
    }

    @Test func aBoostIsAllowedUpToTheAvailableHeadroom() {
        // A peak of 0.5 is 6.02 dB below full scale, so +9 comes back to that.
        let hot = ReplayGainTags(trackGainDB: 9, trackPeak: 0.5)
        let gain = ReplayGain.gainDB(for: hot, mode: .track)
        #expect(abs(gain - 6.0206) < 0.01)
    }

    @Test func aGainInsideTheHeadroomIsLeftAlone() {
        let fine = ReplayGainTags(trackGainDB: 3, trackPeak: 0.5)
        #expect(ReplayGain.gainDB(for: fine, mode: .track) == 3)
    }

    /// Cuts never clip, so the peak must not interfere with them.
    @Test func aCutIsNeverRaisedByTheHeadroom() {
        #expect(ReplayGain.gainDB(for: loud, mode: .track) == -8)
    }

    @Test func clippingProtectionCanBeTurnedOff() {
        let hot = ReplayGainTags(trackGainDB: 9, trackPeak: 1.0)
        #expect(ReplayGain.gainDB(for: hot, mode: .track, preventClipping: false) == 9)
    }

    // MARK: Preamp and bounds

    @Test func preampMovesTaggedFilesOnly() {
        let headroom = ReplayGainTags(trackGainDB: -6, trackPeak: 0.5)
        #expect(ReplayGain.gainDB(for: headroom, mode: .track, preampDB: 3) == -3)
        #expect(ReplayGain.gainDB(for: ReplayGainTags(), mode: .track, preampDB: 3) == 0)
    }

    @Test func absurdTagsAreClampedRatherThanObeyed() {
        let broken = ReplayGainTags(trackGainDB: -400, trackPeak: 0.1)
        #expect(ReplayGain.gainDB(for: broken, mode: .track) == ReplayGain.minimumGainDB)
    }

    // MARK: Linear conversion

    @Test func zeroDecibelsIsUnityGain() {
        let gain = ReplayGain.linearGain(for: ReplayGainTags(), mode: .track)
        #expect(abs(gain - 1) < 0.0001)
    }

    @Test func minusSixDecibelsIsAboutHalfAmplitude() {
        let tags = ReplayGainTags(trackGainDB: -6.0206, trackPeak: 1.0)
        let gain = ReplayGain.linearGain(for: tags, mode: .track)
        #expect(abs(gain - 0.5) < 0.001)
    }

    // MARK: Parsing what servers send

    @Test func parsesGainsWrittenWithTheirUnit() {
        #expect(ReplayGain.parseGain("-7.30 dB") == -7.3)
        #expect(ReplayGain.parseGain("-7.30dB") == -7.3)
        #expect(ReplayGain.parseGain("  4.5 DB ") == 4.5)
        #expect(ReplayGain.parseGain("-7.30") == -7.3)
    }

    @Test func parsesNothingFromNonsense() {
        #expect(ReplayGain.parseGain(nil) == nil)
        #expect(ReplayGain.parseGain("") == nil)
        #expect(ReplayGain.parseGain("loud") == nil)
    }

    /// A zero or negative peak is meaningless and would zero the gain.
    @Test func rejectsAPeakThatCannotBeReal() {
        #expect(ReplayGain.parsePeak("0") == nil)
        #expect(ReplayGain.parsePeak("-1") == nil)
        #expect(ReplayGain.parsePeak("0.98") == 0.98)
    }
}
