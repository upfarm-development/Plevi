import AVFoundation
import Testing
@testable import PleviAudio

/// Renders real audio through the limiter and measures what comes out.
@Suite("The limiter holds the signal under full scale")
struct ClipLimiterTests {
    private static let sampleRate = 44_100.0
    private static let seconds = 1.0

    /// Renders a sine at `amplitude` through an optional limiter and returns
    /// the peak of the second half — after the limiter's attack has settled,
    /// so the measurement is of steady state rather than the first transient.
    private static func renderPeak(amplitude: Float, limited: Bool) throws -> Float {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ) else {
            Issue.record("could not make a render format")
            return 0
        }

        engine.attach(player)
        let limiter = ClipLimiter.makeNode()
        if limited {
            engine.attach(limiter)
            engine.connect(player, to: limiter, format: format)
            engine.connect(limiter, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }

        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            Issue.record("could not make a source buffer")
            return 0
        }
        source.frameLength = frames
        // A 440 Hz sine, scaled past full scale on purpose.
        for frame in 0..<Int(frames) {
            let value = amplitude * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            for channel in 0..<Int(format.channelCount) {
                source.floatChannelData?[channel][frame] = value
            }
        }

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleBuffer(source, at: nil, options: [])
        player.play()

        guard let sink = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            Issue.record("could not make a render buffer")
            return 0
        }

        var peak: Float = 0
        var rendered: AVAudioFramePosition = 0
        let halfway = AVAudioFramePosition(frames / 2)
        while rendered < AVAudioFramePosition(frames) {
            let remaining = AVAudioFramePosition(frames) - rendered
            let ask = AVAudioFrameCount(min(AVAudioFramePosition(sink.frameCapacity), remaining))
            let status = try engine.renderOffline(ask, to: sink)
            guard status == .success else { break }
            for frame in 0..<Int(sink.frameLength) where rendered + AVAudioFramePosition(frame) > halfway {
                for channel in 0..<Int(sink.format.channelCount) {
                    peak = max(peak, abs(sink.floatChannelData?[channel][frame] ?? 0))
                }
            }
            rendered += AVAudioFramePosition(sink.frameLength)
        }

        player.stop()
        engine.stop()
        return peak
    }

    @Test("A signal well over full scale comes back under it")
    func limitsAnOverload() throws {
        // Twice full scale: what a mis-tagged file with no peak, or a track
        // at full scale with the bass boosted, actually presents.
        let peak = try Self.renderPeak(amplitude: 2.0, limited: true)
        #expect(peak <= 1.02, "limiter let \(peak) through; full scale is 1.0")
    }

    @Test("Without the limiter the same signal clips, so the test can fail")
    func controlClips() throws {
        // The other half of the previous test: if this did not overshoot,
        // the one above would pass whether or not the limiter did anything.
        let peak = try Self.renderPeak(amplitude: 2.0, limited: false)
        #expect(peak > 1.5, "unlimited peak was \(peak); the overload never happened")
    }

    @Test("Music already inside full scale is left alone")
    func leavesHeadroomAlone() throws {
        // A safety limiter that colours everything under it is a compressor.
        // Half scale must come out at half scale.
        let peak = try Self.renderPeak(amplitude: 0.5, limited: true)
        #expect(peak > 0.47 && peak <= 0.52, "quiet signal came back at \(peak)")
    }
}
