import Foundation
import Testing
@testable import PleviAudio

@Suite("Opus on the watch (watch-08)")
struct WatchOpusTests {
    @Test("A watch that converts nothing still converts Opus, which its player cannot open")
    func watchConvertsOpusWithTheSwitchOff() {
        let off = TranscodePolicy.watch(transcoding: false, kbps: 128)
        #expect(off.target(forCodec: "opus", bitRateKbps: 128) == "aac")
        #expect(off.target(forCodec: "audio/opus", bitRateKbps: nil) == "aac")
        #expect(off.target(forCodec: "OPUS", bitRateKbps: nil) == "aac")
    }

    @Test("The phone's policy is unchanged: its decoder opens Opus")
    func phoneStillTakesOpusAsItIs() {
        let phone = TranscodePolicy(threshold: .never)
        #expect(phone.target(forCodec: "opus", bitRateKbps: 128) == nil)
        #expect(TranscodePolicy.streamingDefault.target(forCodec: "opus", bitRateKbps: 128) == nil)
        #expect(TranscodePolicy.downloadDefault.target(forCodec: "opus", bitRateKbps: 128) == nil)
    }

    @Test("Other formats on the watch follow the switch as before")
    func restUnchanged() {
        let off = TranscodePolicy.watch(transcoding: false, kbps: 128)
        #expect(off.target(forCodec: "flac", bitRateKbps: 1000) == nil)
        #expect(off.target(forCodec: "mp3", bitRateKbps: 320) == nil)
        #expect(off.target(forCodec: nil, bitRateKbps: nil) == nil)
    }

    @Test("A policy stored before the field existed still decodes")
    func oldPoliciesDecode() throws {
        let stored = Data(#"""
        {"threshold":"never","bitRateLimitKbps":320,"codec":"opus","targetBitRateKbps":192}
        """#.utf8)
        let policy = try JSONDecoder().decode(TranscodePolicy.self, from: stored)
        #expect(policy.mustConvert == nil)
        #expect(policy.target(forCodec: "opus", bitRateKbps: 128) == nil)
    }

    @Test("A watch policy round-trips with its must-convert set")
    func watchPolicyRoundTrips() throws {
        let policy = TranscodePolicy.watch(transcoding: false, kbps: 128)
        let back = try JSONDecoder().decode(TranscodePolicy.self, from: JSONEncoder().encode(policy))
        #expect(back == policy)
    }
}
