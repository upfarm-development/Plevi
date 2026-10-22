import Foundation
import PleviDomain
import PleviAudio

/// The small monospaced badge that says what a file is: "FLAC 44.1/16", "MP3 320", "OPUS 160".
@MainActor
enum CodecBadge {
    /// The file as it sits on the server.
    static func downloaded(codec: String, kbps: Int?, settings: AppSettings) -> String {
        var parts = [codec.uppercased()]
        if settings.badgeShowsLossyBitRate, let kbps, kbps > 0 {
            parts.append("\(kbps)")
        }
        return parts.joined(separator: " ")
    }

    static func original(for track: Track, settings: AppSettings) -> String? {
        guard let codec = track.codec?.uppercased(), !codec.isEmpty else { return nil }
        var parts = [codec]
        if TranscodePolicy.isLossless(track.codec) {
            if settings.badgeShowsLosslessDetail {
                // Sample rate and depth belong together — "44.1/16" is one
                // fact about the file, not two.
                var detail: [String] = []
                if let rate = track.sampleRate, rate > 0 {
                    detail.append(String(format: "%.4g", Double(rate) / 1000))
                }
                if let depth = track.bitDepth, depth > 0 {
                    detail.append("\(depth)")
                }
                if !detail.isEmpty { parts.append(detail.joined(separator: "/")) }
            }
        } else if settings.badgeShowsLossyBitRate, let bitRate = track.bitRateKbps, bitRate > 0 {
            parts.append("\(bitRate)")
        }
        return parts.joined(separator: " ")
    }

    /// What the file being played turned out to be, when the engine has had a look at it: format,
    /// sample rate and depth for lossless, bit rate for lossy.
    static func measured(
        _ format: PlayingAudioFormat,
        track: Track?,
        settings: AppSettings
    ) -> String? {
        guard let codec = format.codec else { return nil }
        // Core Audio reports no bit depth for a compressed file, so the
        // server's figure fills in — but only when it is describing the same
        // format. After a conversion the old depth means nothing.
        let sameFormat = track?.codec?.uppercased() == codec
        var parts = [codec]
        if TranscodePolicy.isLossless(codec) {
            if settings.badgeShowsLosslessDetail {
                var detail: [String] = []
                if let rate = format.sampleRate, rate > 0 {
                    detail.append(String(format: "%.4g", Double(rate) / 1000))
                }
                if let depth = format.bitDepth ?? (sameFormat ? track?.bitDepth : nil), depth > 0 {
                    detail.append("\(depth)")
                }
                if !detail.isEmpty { parts.append(detail.joined(separator: "/")) }
            }
        } else if settings.badgeShowsLossyBitRate, let bitRate = format.bitRateKbps, bitRate > 0 {
            parts.append("\(bitRate)")
        }
        return parts.joined(separator: " ")
    }

    /// What is expected to come down the wire, from the streaming policy — used until the engine
    /// has opened the file and can say for certain.
    static func playing(
        _ track: Track,
        settings: AppSettings,
        expensiveNetwork: Bool
    ) -> String? {
        // The policy for the connection in use, so the badge cannot promise
        // one thing on wi-fi and the player deliver another on mobile data.
        let policy = settings.streamingTranscode(expensiveNetwork: expensiveNetwork)
        guard let target = policy.target(
            forCodec: track.codec ?? track.contentType,
            bitRateKbps: track.bitRateKbps,
            bundledDecoders: true
        ) else {
            return original(for: track, settings: settings)
        }
        return "\(target.uppercased()) \(policy.targetBitRateKbps)"
    }
}
