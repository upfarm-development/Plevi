import Foundation

/// Something the audio system did to us that playback has to survive.
public enum AudioDisruption: Sendable, Hashable {
    /// The engine's configuration changed underneath us — a new output, or
    /// the same one at a different sample rate. The engine has stopped and
    /// its connections are broken.
    case configurationChanged
    /// The thing we were playing to has gone. Headphones out of the socket,
    /// a Bluetooth speaker walked away from.
    case outputDisappeared
    /// Something else has taken the audio: a phone call, another app.
    case interrupted
    /// The interruption is over. The system says whether it thinks we should
    /// pick up where we left off — a call ending, yes; the user having
    /// deliberately started something else, no.
    case interruptionEnded(mayResume: Bool)
}

/// What playback should do about it.
public enum AudioRecovery: Sendable, Hashable {
    case nothing
    case pause
    case resume
    /// Rebuild the graph and start the engine again. Whether the music picks
    /// up depends on whether it was playing when the world changed.
    case rebuild(resumePlaying: Bool)
}

/// The rules for surviving a disruption.
public enum AudioDisruptionPolicy {
    /// - Parameters: - isPlaying: whether audio is playing at the moment of the event.
    public static func recovery(
        for disruption: AudioDisruption,
        isPlaying: Bool,
        wasPlayingBeforeInterruption: Bool = false
    ) -> AudioRecovery {
        switch disruption {
        case .configurationChanged:
            // Always rebuild, playing or not: the connections are broken
            // either way, and a paused player still has to have somewhere to
            // send the next track.
            return .rebuild(resumePlaying: isPlaying)

        case .outputDisappeared:
            // The rule every music app is judged by. What was going into
            // headphones must not continue out of the speaker.
            return isPlaying ? .pause : .nothing

        case .interrupted:
            return isPlaying ? .pause : .nothing

        case .interruptionEnded(let mayResume):
            // Two conditions, both required. The system has to think resuming
            // is right, and we have to have been playing before — otherwise
            // a missed call would start music that was never on.
            return mayResume && wasPlayingBeforeInterruption ? .resume : .nothing
        }
    }
}
