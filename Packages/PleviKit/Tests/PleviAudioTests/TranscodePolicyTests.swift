import Foundation
import Testing
import PleviAudio

@Suite struct TranscodePolicyTests {
    /// Whatever the setting says, a file the device cannot decode has to be
    /// converted — "never convert" cannot mean "play silence".
    @Test func alwaysConvertsWhatTheDeviceCannotDecode() {
        let policy = TranscodePolicy(threshold: .never, codec: "aac")
        // Opus used to be the example here and no longer qualifies: iOS 26
        // decodes it, measured on a device. The rule is unchanged; only the
        // list of things it applies to is shorter.
        #expect(policy.target(forCodec: "wma", bitRateKbps: 128) == "aac")
        #expect(policy.target(forCodec: "ogg", bitRateKbps: nil) == "aac")
        #expect(policy.target(forCodec: "opus", bitRateKbps: 128) == nil)
    }

    @Test func leavesPlayableFilesAloneOnTheDefault() {
        let policy = TranscodePolicy(threshold: .never)
        #expect(policy.target(forCodec: "flac", bitRateKbps: 1000) == nil)
        #expect(policy.target(forCodec: "mp3", bitRateKbps: 320) == nil)
    }

    // MARK: Lossless only

    @Test func losslessOnlyConvertsLosslessAndLeavesLossyAlone() {
        let policy = TranscodePolicy(threshold: .lossless, codec: "opus")
        #expect(policy.target(forCodec: "flac", bitRateKbps: 1000) == "opus")
        #expect(policy.target(forCodec: "alac", bitRateKbps: 900) == "opus")
        #expect(policy.target(forCodec: "wav", bitRateKbps: 1411) == "opus")
        #expect(policy.target(forCodec: "mp3", bitRateKbps: 320) == nil)
        #expect(policy.target(forCodec: "aac", bitRateKbps: 256) == nil)
    }

    @Test func knowsWhichFormatsAreLossless() {
        #expect(TranscodePolicy.isLossless("flac"))
        #expect(TranscodePolicy.isLossless("audio/x-flac"))
        #expect(!TranscodePolicy.isLossless("mp3"))
        #expect(!TranscodePolicy.isLossless(nil))
    }

    // MARK: Bit rate threshold

    @Test func convertsOnlyWhatExceedsTheLimit() {
        let policy = TranscodePolicy(threshold: .aboveBitRate, bitRateLimitKbps: 320, codec: "aac")
        #expect(policy.target(forCodec: "flac", bitRateKbps: 1000) == "aac")
        #expect(policy.target(forCodec: "mp3", bitRateKbps: 320) == nil)
        #expect(policy.target(forCodec: "mp3", bitRateKbps: 192) == nil)
    }

    /// An unknown bit rate is not evidence of a large file, and converting on
    /// a guess is the wrong way to be wrong.
    @Test func leavesAFileAloneWhenItsBitRateIsUnknown() {
        let policy = TranscodePolicy(threshold: .aboveBitRate, bitRateLimitKbps: 320)
        #expect(policy.target(forCodec: "flac", bitRateKbps: nil) == nil)
    }

    // MARK: Everything

    @Test func alwaysConvertsWhenAskedTo() {
        let policy = TranscodePolicy(threshold: .always, codec: "opus")
        #expect(policy.target(forCodec: "mp3", bitRateKbps: 128) == "opus")
        #expect(policy.target(forCodec: "flac", bitRateKbps: 1000) == "opus")
    }

    // MARK: Defaults and storage

    /// A self-hosted library is usually already the files you want, and a
    /// download is the copy you keep — neither should shrink by default.
    @Test func bothDefaultsLeaveAudioUntouched() {
        #expect(TranscodePolicy.streamingDefault.threshold == .never)
        #expect(TranscodePolicy.downloadDefault.threshold == .never)
    }

    @Test func roundTripsThroughCodable() throws {
        let policy = TranscodePolicy(threshold: .aboveBitRate, bitRateLimitKbps: 500, codec: "opus", targetBitRateKbps: 192)
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(TranscodePolicy.self, from: data) == policy)
    }

    // MARK: Which copy to play

    /// The bug this exists for.
    @Test func aConvertedDownloadLosesToABetterStreamAtHome() {
        #expect(!TranscodePolicy.prefersDownloadedCopy(
            isOffline: false,
            downloadIsConverted: true,
            streamWouldConvert: false
        ))
    }

    /// The same download, the same song, in the car on cellular: the phone's
    /// own policy would shrink it too, so there is nothing to gain by
    /// reaching past the copy already on the disk.
    @Test func aConvertedDownloadWinsWhenStreamingWouldNotDoBetter() {
        #expect(TranscodePolicy.prefersDownloadedCopy(
            isOffline: false,
            downloadIsConverted: true,
            streamWouldConvert: true
        ))
    }

    /// A download kept at its original quality is never worse than a
    /// stream — asking the network again would be a request for nothing.
    @Test func anUnconvertedDownloadAlwaysWins() {
        #expect(TranscodePolicy.prefersDownloadedCopy(
            isOffline: false,
            downloadIsConverted: false,
            streamWouldConvert: false
        ))
        #expect(TranscodePolicy.prefersDownloadedCopy(
            isOffline: false,
            downloadIsConverted: false,
            streamWouldConvert: true
        ))
    }

    /// Offline there is nothing else to ask, converted or not — the download
    /// is the only copy there is.
    @Test func offlineTheDownloadAlwaysWinsWhateverItsQuality() {
        #expect(TranscodePolicy.prefersDownloadedCopy(
            isOffline: true,
            downloadIsConverted: true,
            streamWouldConvert: false
        ))
        #expect(TranscodePolicy.prefersDownloadedCopy(
            isOffline: true,
            downloadIsConverted: false,
            streamWouldConvert: false
        ))
    }
}

/// The rates on offer, and what happens to a choice that is no longer one.
@Suite struct OfferedBitRateTests {
    @Test func offersNinetySixAgain() {
        // Taken off in build 367 while playback waited for a fixed megabyte
        // and a half; the wait is now seconds of the stream's own rate.
        #expect(TranscodePolicy.offeredBitRates.first == 96)
        #expect(GrowingFile.startBytes(kbps: 96) < 200_000)
    }

    @Test func bringsAnUnofferedRateToTheNearestOneOffered() {
        #expect(TranscodePolicy.offeredRate(nearest: 96) == 96)
        #expect(TranscodePolicy.offeredRate(nearest: 64) == 96)
        #expect(TranscodePolicy.offeredRate(nearest: 224) == 256)
    }

    @Test func leavesARateThatIsStillOfferedAlone() {
        for rate in TranscodePolicy.offeredBitRates {
            #expect(TranscodePolicy.offeredRate(nearest: rate) == rate)
        }
    }

    @Test func convertsToOpusAtTheRatesTheTwoNetworksDeserve() {
        #expect(TranscodePolicy.streamingDefault.codec == "opus")
        #expect(TranscodePolicy.streamingDefault.targetBitRateKbps == 192)
        #expect(TranscodePolicy.cellularDefault.codec == "opus")
        #expect(TranscodePolicy.cellularDefault.targetBitRateKbps == 128)
    }

    @Test func stillConvertsNothingUntilAsked() {
        // The codec and rate say what to use *if* converting is turned on.
        #expect(TranscodePolicy.streamingDefault.threshold == .never)
        #expect(TranscodePolicy.cellularDefault.threshold == .never)
        #expect(TranscodePolicy.downloadDefault.threshold == .never)
    }
}
