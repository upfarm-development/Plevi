import Foundation

/// When to ask a server to convert a track, and to what.
public struct TranscodePolicy: Hashable, Sendable, Codable {
    /// What is allowed through untouched.
    public enum Threshold: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        /// Only what the device cannot decode is converted.
        case never
        /// Lossless files are converted; lossy ones pass through.
        case lossless
        /// Anything above `bitRateLimitKbps` is converted, lossless included.
        case aboveBitRate
        /// Everything is converted.
        case always

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .never: "Only if unplayable"
            case .lossless: "Lossless only"
            case .aboveBitRate: "Above a bit rate"
            case .always: "Everything"
            }
        }
    }

    public var threshold: Threshold
    /// Used by `.aboveBitRate`.
    public var bitRateLimitKbps: Int
    public var codec: String
    /// What the server is asked to produce.
    public var targetBitRateKbps: Int
    /// Formats this device cannot decode although `NativeAudioSupport`, which was measured on an
    /// iPhone, says it can.
    public var mustConvert: Set<String>?

    public init(
        threshold: Threshold = .never,
        bitRateLimitKbps: Int = 320,
        codec: String = "opus",
        targetBitRateKbps: Int = 192,
        mustConvert: Set<String>? = nil
    ) {
        self.threshold = threshold
        self.bitRateLimitKbps = bitRateLimitKbps
        self.codec = codec
        self.targetBitRateKbps = targetBitRateKbps
        self.mustConvert = mustConvert
    }

    /// What the watch's player refuses although the phone's decodes.
    public static let watchMustConvert: Set<String> = ["opus"]

    /// Untouched audio when streaming; the point of a self-hosted library is usually that the files
    /// are already what you want.
    public static let streamingDefault = TranscodePolicy()

    /// The same, at the rate worth spending mobile data on. Opus at 128 is
    /// transparent enough that the difference is an argument rather than an
    /// observation, and it is two-thirds of the data.
    public static let cellularDefault = TranscodePolicy(targetBitRateKbps: 128)

    /// Also untouched by default. A download is the copy you keep, and
    /// quietly shrinking it is not a decision to make on someone's behalf.
    public static let downloadDefault = TranscodePolicy()

    /// The rates offered, smallest useful first.
    public static let offeredBitRates = [96, 128, 160, 192, 256, 320]

    /// The nearest offered rate to one that was stored before the list changed, so a picker is
    /// never left showing a value it has no row for.
    public static func offeredRate(nearest stored: Int) -> Int {
        offeredBitRates.min { first, second in
            let firstGap = abs(first - stored)
            let secondGap = abs(second - stored)
            return firstGap == secondGap ? first > second : firstGap < secondGap
        } ?? 192
    }

    /// What a watch asks its server for.
    public static func watch(
        transcoding: Bool,
        kbps: Int,
        codec: String = "aac"
    ) -> TranscodePolicy {
        TranscodePolicy(
            threshold: transcoding ? .always : .never,
            codec: codec,
            targetBitRateKbps: kbps,
            mustConvert: watchMustConvert
        )
    }

    /// Formats that carry no loss, so "lossless only" knows what it means.
    public static let losslessCodecs: Set<String> = [
        "flac", "alac", "wav", "wave", "aiff", "aif", "aifc", "pcm",
        "ape", "wavpack", "wv", "tta", "shorten", "shn", "dsd", "dsf", "dff",
    ]

    public static func isLossless(_ codec: String?) -> Bool {
        guard let value = NativeAudioSupport.normalise(codec) else { return false }
        return losslessCodecs.contains(value)
    }

    /// The format to request, or nil to take the file as it is.
    public func target(forCodec codec: String?, bitRateKbps: Int?, bundledDecoders: Bool = false) -> String? {
        if !NativeAudioSupport.canDecode(codec, includingBundled: bundledDecoders) { return self.codec }
        if let mustConvert,
           let value = NativeAudioSupport.normalise(codec), mustConvert.contains(value) {
            return self.codec
        }

        switch threshold {
        case .never:
            return nil
        case .lossless:
            return Self.isLossless(codec) ? self.codec : nil
        case .aboveBitRate:
            // An unknown bit rate is not evidence of a large file, and
            // converting on a guess would be the wrong way to be wrong.
            guard let bitRateKbps, bitRateKbps > bitRateLimitKbps else { return nil }
            return self.codec
        case .always:
            return self.codec
        }
    }

    /// Whether a copy already kept on the phone should be played instead of asking the server for a
    /// stream.
    public static func prefersDownloadedCopy(
        isOffline: Bool,
        downloadIsConverted: Bool,
        streamWouldConvert: Bool
    ) -> Bool {
        guard !isOffline else { return true }
        guard downloadIsConverted else { return true }
        return streamWouldConvert
    }
}
