import Foundation
import AVFoundation
import PleviAudio

/// The playback engine boundary. Milestone 1 fulfils it with AVPlayer;
/// Milestone 3 swaps in the AVAudioEngine pipeline (gapless, EQ, ReplayGain)
/// behind the same interface without touching `PlayerModel` or any view.
@MainActor
protocol AudioEngine: AnyObject {
    var onEvent: ((AudioEngineEvent) -> Void)? { get set }
    var currentTime: TimeInterval { get }

    func load(_ request: URLRequest, autoplay: Bool)
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)

    /// Loudness levelling for the current track, as a linear multiplier.
    func setGain(_ linearGain: Float)
    func setEqualizer(_ preset: EqualizerPreset)
    /// Turns the end-of-chain safety limiter on or off.
    func setLimiter(_ enabled: Bool)

    /// Queues the next track to follow this one with no gap.
    func preloadNext(_ request: URLRequest) -> Bool
    /// Starts the next track so that it overlaps the tail of this one by `overlap` seconds,
    /// beginning at a sample-accurate moment worked out from the render clock rather than from a
    /// timer.
    func beginOverlap(
        into request: URLRequest,
        overlap: TimeInterval,
        envelope: TransitionEnvelope,
        incomingGain: Float,
        attenuation: Float
    ) -> Bool

    /// Starts a file that is still being written, so a track being converted on the server can play
    /// from its first seconds instead of its last.
    func loadGrowing(_ url: URL, expectedDuration: TimeInterval?, autoplay: Bool, declaresLength: Bool)
    func growthFinished(at url: URL)
    /// The transfer ended before the file was whole, and what arrived is all
    /// there is. Returns how many seconds of it can be played, where that is
    /// known.
    @discardableResult
    func growthCutOff(at url: URL) -> TimeInterval?

    /// Whether a join is armed behind the playing track — a gapless preload
    /// on the node, or an overlap scheduled and not yet handed over. Read by
    /// the model to notice that a seek or a rebuild has thrown its join away.
    var hasArmedNext: Bool { get }
    /// Takes back the armed join so the model can arm a different one (the queue changed behind it,
    /// repeat-one was switched on, an end-of-song sleep was set).
    func cancelPendingNext() -> Bool
}

extension AudioEngine {
    // An engine that cannot read a file as it grows simply waits: nothing
    // happens until the file is whole, which is what it did before.
    func loadGrowing(_ url: URL, expectedDuration: TimeInterval?, autoplay: Bool, declaresLength: Bool) {}
    func growthFinished(at url: URL) { load(URLRequest(url: url), autoplay: true) }
    func growthCutOff(at url: URL) -> TimeInterval? { growthFinished(at: url); return nil }

    // AVPlayer offers neither, and pretending otherwise would put controls
    // in front of the user that do nothing.
    func setGain(_ linearGain: Float) {}
    func setEqualizer(_ preset: EqualizerPreset) {}
    func setLimiter(_ enabled: Bool) {}
    func preloadNext(_ request: URLRequest) -> Bool { false }
    var hasArmedNext: Bool { false }
    func cancelPendingNext() -> Bool { true }
    func beginOverlap(
        into request: URLRequest,
        overlap: TimeInterval,
        envelope: TransitionEnvelope,
        incomingGain: Float,
        attenuation: Float
    ) -> Bool { false }
}

/// What the audio being played actually turned out to be, read from the
/// file itself rather than from what the app asked the server for.
struct PlayingAudioFormat: Equatable {
    /// "FLAC", "AAC", "OPUS" — from the file's own format identifier.
    var codec: String?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    /// Average over the whole file: its size against its duration. Close
    /// enough to name a bit rate, and the only honest figure available
    /// without decoding the container's own header.
    var bitRateKbps: Int?

    /// For a mirrored player: what the target
    /// itself reported, not read from a file this device has.
    init(codec: String?, sampleRate: Int?, bitDepth: Int?, channels: Int?, bitRateKbps: Int?) {
        self.codec = codec; self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.channels = channels; self.bitRateKbps = bitRateKbps
    }

    /// Reads what Core Audio made of the file.
    init?(fileAt url: URL, duration: TimeInterval?) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.fileFormat
        sampleRate = format.sampleRate > 0 ? Int(format.sampleRate.rounded()) : nil
        channels = Int(format.channelCount)
        codec = Self.name(for: format.streamDescription.pointee.mFormatID)

        if let bits = format.settings[AVLinearPCMBitDepthKey] as? Int, bits > 0 {
            bitDepth = bits
        } else if let bits = format.streamDescription.pointee.mBitsPerChannel as UInt32?, bits > 0 {
            bitDepth = Int(bits)
        }
        // Core Audio says nothing of the depth of a compressed file. FLAC's own
        // first block does, and it is there offline, where the server's figure
        // is not.
        if bitDepth == nil, codec == "FLAC",
           let head = try? FileHandle(forReadingFrom: url).read(upToCount: 4096),
           let info = FlacStreamInfo.read(from: head) {
            bitDepth = info.bitsPerSample
        }

        if let duration, duration > 0,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            bitRateKbps = Int((Double(size) * 8 / duration / 1000).rounded())
        }
    }

    private static func name(for formatID: AudioFormatID) -> String? {
        switch formatID {
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
        case kAudioFormatOpus: "OPUS"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatLinearPCM: "PCM"
        default: nil
        }
    }
}

enum AudioEngineEvent {
    case readyToPlay(duration: TimeInterval?)
    /// What was loaded, as the file itself reports it.
    case loadedFormat(PlayingAudioFormat?)
    case progress(TimeInterval)
    case rateChanged(Float)
    case stalled
    case didFinish
    /// A preloaded track has begun playing. The queue should move on without
    /// loading anything — the audio is already running.
    case advancedToPreloaded
    case failed(String)
}
