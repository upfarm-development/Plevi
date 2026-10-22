import Foundation
import Testing
@testable import PleviAudio

/// The transcode decision across every combination a listener can reach by toggling settings
/// mid-track, changing network, or being served a track whose metadata is missing or oddly spelled.
@Suite("The transcode decision, exhaustively")
struct StressPlaybackTranscodeMatrixTests {
    private static let thresholds = TranscodePolicy.Threshold.allCases

    /// Spellings of the same codec a server or a file name can produce.
    private static let flacSpellings = [
        "flac", "FLAC", "Flac", " flac ", "audio/flac", "audio/x-flac", ".flac",
        "track.FLAC", "x-flac",
    ]
    private static let undecodableSpellings = [
        "wma", "WMA", "track.wma", "ape", "audio/x-ape",
        "ogg", "OGG", "audio/ogg", "vorbis", "dsf", "audio/dsd", "wv", "mpc",
    ]
    private static let lossySpellings = ["mp3", "MP3", "audio/mpeg", "aac", "m4a", "audio/mp4", "audio/aac"]

    private static let bitRates: [Int?] = [nil, -1, 0, 1, 127, 128, 319, 320, 321, 1411, Int.max]

    @Test("What the device cannot decode is converted by every policy, whatever else is true")
    func undecodableIsAlwaysConverted() {
        for threshold in Self.thresholds {
            for limit in [0, 320, Int.max] {
                let policy = TranscodePolicy(threshold: threshold, bitRateLimitKbps: limit, codec: "opus")
                for spelling in Self.undecodableSpellings {
                    for rate in Self.bitRates {
                        #expect(
                            policy.target(forCodec: spelling, bitRateKbps: rate) == "opus",
                            "\(threshold) limit \(limit) codec \(spelling) rate \(String(describing: rate))"
                        )
                    }
                }
            }
        }
    }

    @Test("Never converts nothing decodable; Always converts everything")
    func theTwoExtremes() {
        let never = TranscodePolicy(threshold: .never)
        let always = TranscodePolicy(threshold: .always)
        for spelling in Self.flacSpellings + Self.lossySpellings {
            for rate in Self.bitRates {
                #expect(never.target(forCodec: spelling, bitRateKbps: rate) == nil, "never: \(spelling) \(String(describing: rate))")
                #expect(always.target(forCodec: spelling, bitRateKbps: rate) == "opus", "always: \(spelling) \(String(describing: rate))")
            }
        }
    }

    @Test("Lossless-only converts every spelling of a lossless codec and no lossy one")
    func losslessOnlyIsSpellingProof() {
        let policy = TranscodePolicy(threshold: .lossless, codec: "opus")
        for spelling in Self.flacSpellings {
            #expect(policy.target(forCodec: spelling, bitRateKbps: nil) == "opus", "\(spelling)")
        }
        for spelling in Self.lossySpellings {
            #expect(policy.target(forCodec: spelling, bitRateKbps: 9999) == nil, "\(spelling)")
        }
    }

    @Test("Above-a-bit-rate is monotonic: converting at N kbps means converting at N+1")
    func aboveBitRateIsMonotonic() {
        for limit in [0, 1, 128, 320, 1000] {
            let policy = TranscodePolicy(threshold: .aboveBitRate, bitRateLimitKbps: limit, codec: "opus")
            var converted = false
            for rate in stride(from: -5, through: 2000, by: 1) {
                let now = policy.target(forCodec: "mp3", bitRateKbps: rate) != nil
                #expect(!(converted && !now), "limit \(limit): converted below \(rate) but not at it")
                converted = converted || now
                // The boundary is exclusive: exactly the limit passes through.
                if rate == limit { #expect(!now, "limit \(limit): converted at the limit itself") }
            }
        }
    }

    @Test("A missing or empty codec is assumed playable and never crashes the decision")
    func unknownCodecIsAssumedPlayable() {
        let odd: [String?] = [nil, "", " ", "\t", ".", "/", "audio/", "audio/x-", "x-", "audio/x-.", "...."]
        for threshold in [TranscodePolicy.Threshold.never, .lossless, .aboveBitRate] {
            let policy = TranscodePolicy(threshold: threshold, bitRateLimitKbps: 320, codec: "opus")
            for codec in odd {
                #expect(policy.target(forCodec: codec, bitRateKbps: 128) == nil, "\(threshold) \(String(describing: codec))")
            }
        }
        // "Everything" converts even what it cannot name.
        #expect(TranscodePolicy(threshold: .always).target(forCodec: nil, bitRateKbps: nil) == "opus")
    }

    @Test("MIME parameters no longer hide the codec")
    func mimeParametersDoNotHideTheCodec() {
        // P-23: `normalise` used to keep everything after the last "/", so "audio/ogg;
        // codecs=vorbis" became "ogg; codecs=vorbis" — in neither list, and an unknown codec is
        // assumed playable — while the same codec written "audio/ogg" was (correctly)…
        #expect(NativeAudioSupport.canDecode("audio/ogg") == false)
        #expect(NativeAudioSupport.canDecode("audio/ogg; codecs=vorbis") == false)
        #expect(NativeAudioSupport.canDecode("audio/x-ms-wma; codecs=wmav2") == false)
        #expect(NativeAudioSupport.canDecode("audio/mpeg; charset=binary") == true)
        #expect(NativeAudioSupport.normalise("audio/x-ms-wma; codecs=wmav2") == "wma")
    }

    @Test("Prefix families cannot swallow a decodable neighbour")
    func prefixesDoNotCatchDecodableNames() {
        for name in ["wav", "wave", "audio/x-wav", "audio/wav", "flac", "audio/x-flac", "mp3", "audio/mpeg", "alac", "aac", "m4a", "aiff", "caf"] {
            #expect(NativeAudioSupport.canDecode(name) == true, "\(name)")
        }
        #expect(NativeAudioSupport.canDecode("wavpack") == false)
        #expect(NativeAudioSupport.canDecode("audio/x-wavpack") == false)
        // Unknown still means playable.
        #expect(NativeAudioSupport.canDecode("some-future-codec") == true)
        #expect(NativeAudioSupport.canDecode("x-") == true)
    }

    @Test("The standard WMA MIME type is recognised as undecodable")
    func wmaMimeType() {
        // P-23: `normalise` strips a leading "x-" once, so "audio/x-ms-wma" becomes "ms-wma" —
        // which is on neither list, and unknown means playable.
        #expect(NativeAudioSupport.canDecode("audio/x-ms-wma") == false)
        #expect(TranscodePolicy(threshold: .never).target(forCodec: "audio/x-ms-wma", bitRateKbps: nil) != nil)
    }

    @Test("Codec names as ffmpeg spells them are recognised as undecodable")
    func ffmpegSpelledCodecs() {
        // P-23 (PLAUSIBLE — needs a Plex server to say what `audioCodec` is for these files): Plex
        // takes `audioCodec` from ffmpeg's codec names, which are not the friendly names the list
        // holds.
        let ffmpegNames = ["dsd_lsbf_planar", "dsd_msbf", "musepack7", "musepack8", "wmalossless", "wmapro", "wmav1"]
        for name in ffmpegNames {
            #expect(NativeAudioSupport.canDecode(name) == false, "\(name)")
        }
    }

    @Test("Preferring a downloaded copy: the whole truth table")
    func downloadedCopyTruthTable() {
        // isOffline, downloadIsConverted, streamWouldConvert -> plays the download
        let table: [(Bool, Bool, Bool, Bool)] = [
            (true, false, false, true),
            (true, false, true, true),
            (true, true, false, true),
            (true, true, true, true),
            (false, false, false, true),
            (false, false, true, true),
            // The one case where the download loses: it was shrunk on purpose
            // and the current network would give the untouched file.
            (false, true, false, false),
            (false, true, true, true),
        ]
        for (offline, converted, streamConverts, expected) in table {
            #expect(
                TranscodePolicy.prefersDownloadedCopy(
                    isOffline: offline, downloadIsConverted: converted, streamWouldConvert: streamConverts
                ) == expected,
                "offline \(offline) converted \(converted) streamConverts \(streamConverts)"
            )
        }
    }

    @Test("Wi-Fi to cellular handoff: the two policies disagree exactly where the setting says")
    func networkHandoffChangesTheAnswerForTheSameTrack() {
        // The same track, asked twice around a network change.
        let wifi = TranscodePolicy.streamingDefault
        let cellular = TranscodePolicy(threshold: .lossless, codec: "opus", targetBitRateKbps: 128)
        #expect(wifi.target(forCodec: "flac", bitRateKbps: 900) == nil)
        #expect(cellular.target(forCodec: "flac", bitRateKbps: 900) == "opus")
        // A lossy track is untouched by both, so the prefetch survives the handoff.
        #expect(wifi.target(forCodec: "mp3", bitRateKbps: 256) == cellular.target(forCodec: "mp3", bitRateKbps: 256))
    }

    @Test("The watch policy converts what it must even with the switch off")
    func watchPolicyKeepsTheDecodabilityFloor() {
        let off = TranscodePolicy.watch(transcoding: false, kbps: 96)
        #expect(off.target(forCodec: "wma", bitRateKbps: nil) != nil)
        #expect(off.target(forCodec: "flac", bitRateKbps: nil) == nil)
        let on = TranscodePolicy.watch(transcoding: true, kbps: 96)
        #expect(on.target(forCodec: "flac", bitRateKbps: nil) != nil)
    }

    @Test("Offered rates: any stored figure maps to something on the list")
    func storedRatesMapToTheList() {
        for stored in [-1000, -1, 0, 1, 64, 96, 127, 128, 129, 144, 160, 176, 192, 224, 256, 288, 320, 321, 999, 1_000_000] {
            #expect(TranscodePolicy.offeredBitRates.contains(TranscodePolicy.offeredRate(nearest: stored)), "\(stored)")
        }
        // A tie goes upward: 144 sits between 128 and 160.
        #expect(TranscodePolicy.offeredRate(nearest: 144) == 160)
    }
}
