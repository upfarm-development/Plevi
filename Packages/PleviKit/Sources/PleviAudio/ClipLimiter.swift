// AVAudioUnitEffect is API_UNAVAILABLE(watchos), and the watchOS SDK ships
// no AudioToolbox at all — there is no peak-limiter audio unit on the wrist to reach for, so every
// symbol below is simply absent there.
#if !os(watchOS)
import AVFoundation

/// A safety limiter for the end of the playback chain.
public enum ClipLimiter {
    /// Fast enough to catch a transient, slow enough not to chase waveform
    /// peaks and dull the sound.
    public static let attackSeconds: Float = 0.002
    /// Long enough that gain reduction rides over a passage rather than
    /// pumping on every beat.
    public static let decaySeconds: Float = 0.05

    public static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    /// A configured limiter node, ready to attach.
    public static func makeNode() -> AVAudioUnitEffect {
        let node = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        configure(node)
        return node
    }

    /// Sets the times. Pre-gain stays at zero: this is a safety net at the
    /// end of the chain, not a loudness stage.
    public static func configure(_ node: AVAudioUnitEffect) {
        let unit = node.audioUnit
        AudioUnitSetParameter(unit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, attackSeconds, 0)
        AudioUnitSetParameter(unit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, decaySeconds, 0)
        AudioUnitSetParameter(unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
    }
}
#endif
