import Foundation
import Testing
import PleviAudio

@Suite struct NativeAudioSupportTests {
    @Test func playsTheFormatsCoreAudioDecodes() {
        for codec in ["mp3", "aac", "m4a", "alac", "wav", "aiff"] {
            #expect(NativeAudioSupport.canDecode(codec), "\(codec)")
        }
    }

    /// FLAC has been decodable since iOS 11. Transcoding a lossless library
    /// for no reason is the exact mistake this list exists to prevent.
    @Test func playsFlacWithoutConverting() {
        #expect(NativeAudioSupport.canDecode("flac"))
        #expect(NativeAudioSupport.transcodeTarget(for: "flac") == nil)
    }

    @Test func convertsWhatCoreAudioCannotRead() {
        for codec in ["vorbis", "ogg", "wma", "ape", "wavpack", "dsd"] {
            #expect(!NativeAudioSupport.canDecode(codec), "\(codec)")
            #expect(NativeAudioSupport.transcodeTarget(for: codec) == "aac", "\(codec)")
        }
    }

    @Test func readsCodecNamesInWhicheverShapeAServerSendsThem() {
        #expect(NativeAudioSupport.normalise("audio/mpeg") == "mpeg")
        #expect(NativeAudioSupport.normalise("AUDIO/X-FLAC") == "flac")
        #expect(NativeAudioSupport.normalise("track.opus") == "opus")
        // Opus itself decodes on iOS 26 — measured on a device — while the
        // Ogg container stays undecodable, because Vorbis also arrives in
        // one and that has not been tried.
        #expect(NativeAudioSupport.canDecode("opus"))
        #expect(!NativeAudioSupport.canDecode("ogg"))
        #expect(!NativeAudioSupport.canDecode("vorbis"))
        #expect(NativeAudioSupport.normalise("  MP3 ") == "mp3")
        #expect(NativeAudioSupport.normalise("") == nil)
        #expect(NativeAudioSupport.normalise(nil) == nil)
    }

    @Test func recognisesUndecodableFormatsThroughTheirMIMETypes() {
        #expect(!NativeAudioSupport.canDecode("audio/ogg"))
        #expect(!NativeAudioSupport.canDecode("audio/x-wavpack"))
    }

    /// Guessing "playable" costs one failed track the user can report.
    /// Guessing the other way silently transcodes a library and loses quality
    /// nobody asked to lose.
    @Test func assumesAnUnknownCodecIsPlayable() {
        #expect(NativeAudioSupport.canDecode("some-new-codec"))
        #expect(NativeAudioSupport.transcodeTarget(for: "some-new-codec") == nil)
        #expect(NativeAudioSupport.canDecode(nil))
    }

    @Test func honoursARequestedTargetFormat() {
        #expect(NativeAudioSupport.transcodeTarget(for: "wma", preferred: "mp3") == "mp3")
        // And nothing is asked for on behalf of a codec that plays: an Opus
        // file in the library is played, not converted.
        #expect(NativeAudioSupport.transcodeTarget(for: "opus", preferred: "mp3") == nil)
    }

    @Test func theAppDecodesVorbisForItselfWhereAskedTo() {
        // Not by default: the watch asks the same question and cannot.
        #expect(!NativeAudioSupport.canDecode("vorbis"))
        for codec in ["vorbis", "ogg", "oga", "audio/ogg; codecs=vorbis"] {
            #expect(NativeAudioSupport.canDecode(codec, includingBundled: true), "\(codec)")
        }
        // What the app does not decode stays unplayable either way.
        #expect(!NativeAudioSupport.canDecode("wma", includingBundled: true))
        #expect(!NativeAudioSupport.canDecode("ape", includingBundled: true))
    }

    @Test func aPolicyThatConvertsNothingPlaysVorbisAsItIsOnThePhone() {
        let policy = TranscodePolicy(threshold: .never)
        #expect(policy.target(forCodec: "vorbis", bitRateKbps: 445, bundledDecoders: true) == nil)
        // The watch's own question is unchanged.
        #expect(policy.target(forCodec: "vorbis", bitRateKbps: 445) == "opus")
    }
}
