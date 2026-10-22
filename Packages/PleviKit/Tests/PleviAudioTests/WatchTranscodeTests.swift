import Testing
@testable import PleviAudio

/// What a watch asks its server for.
@Suite("What the watch asks the server for")
struct WatchTranscodeTests {
    @Test("Transcoding on converts a lossless file to AAC at the chosen rate")
    func convertsLossless() {
        let policy = TranscodePolicy.watch(transcoding: true, kbps: 128)
        #expect(policy.target(forCodec: "flac", bitRateKbps: 1000) == "aac")
        #expect(policy.targetBitRateKbps == 128)
    }

    @Test("Transcoding on converts an already-lossy file too")
    func convertsLossy() {
        let policy = TranscodePolicy.watch(transcoding: true, kbps: 96)
        // Re-encoding an MP3 is a real cost in quality, and it is still the
        // right answer here: a 320 kbps file over Bluetooth is three times
        // the bytes of a 96 kbps one for a difference nobody hears on a run.
        #expect(policy.target(forCodec: "mp3", bitRateKbps: 320) == "aac")
    }

    @Test("Transcoding off leaves the server's own files alone")
    func leavesFilesAlone() {
        let policy = TranscodePolicy.watch(transcoding: false, kbps: 128)
        #expect(policy.target(forCodec: "flac", bitRateKbps: 1000) == nil)
        #expect(policy.target(forCodec: "mp3", bitRateKbps: 320) == nil)
        #expect(policy.target(forCodec: "aac", bitRateKbps: 256) == nil)
    }

    @Test("A format the watch cannot decode is converted whichever way the switch is set")
    func convertsWhatCannotBePlayed() {
        // The case that makes this worth a test rather than a comment: with
        // the switch off, an Ogg Vorbis file left alone would be silence.
        let off = TranscodePolicy.watch(transcoding: false, kbps: 128)
        #expect(off.target(forCodec: "vorbis", bitRateKbps: 192) == "aac")
        #expect(off.target(forCodec: "ogg", bitRateKbps: 192) == "aac")

        let on = TranscodePolicy.watch(transcoding: true, kbps: 128)
        #expect(on.target(forCodec: "vorbis", bitRateKbps: 192) == "aac")
    }

    @Test("Every offered bit rate survives the round trip")
    func carriesEveryRate() {
        for rate in [64, 96, 128, 192, 256] {
            let policy = TranscodePolicy.watch(transcoding: true, kbps: rate)
            #expect(policy.targetBitRateKbps == rate)
            #expect(policy.codec == "aac")
        }
    }

    @Test("A song whose format the library does not record is left alone when the switch is off")
    func handlesUnknownCodec() {
        // An unknown codec is taken to be playable rather than unplayable —
        // `NativeAudioSupport.canDecode(nil)` is true.
        let off = TranscodePolicy.watch(transcoding: false, kbps: 128)
        #expect(off.target(forCodec: nil, bitRateKbps: nil) == nil)

        // With the switch on there is no guessing to do: everything goes.
        let on = TranscodePolicy.watch(transcoding: true, kbps: 128)
        #expect(on.target(forCodec: nil, bitRateKbps: nil) == "aac")
    }
}
