import Foundation

/// What this device can decode for itself, and what has to be converted.
public enum NativeAudioSupport {
    /// Formats Core Audio decodes on iOS. FLAC has been among them since
    /// iOS 11, which matters — a lossless library should not be transcoded
    /// for no reason.
    public static let decodableCodecs: Set<String> = [
        "mp3", "mpeg", "mpga",
        "aac", "m4a", "mp4", "alac", "m4b",
        "flac",
        "wav", "wave", "pcm",
        "aiff", "aif", "aifc",
        "caf",
    ]

    /// Common names for things Core Audio cannot decode, kept only so the
    /// reason a track needs converting can be explained.
    public static let knownUndecodableCodecs: Set<String> = [
        // Opus is not among these any more.
        "vorbis", "ogg", "oga",
        "wma", "wmav2",
        "ape", "monkeys audio",
        "wavpack", "wv",
        "musepack", "mpc",
        "dsd", "dsf", "dff",
        "tta", "shorten", "shn",
    ]

    /// Families recognised by their start, because servers spell them many ways: `wma`, `wmav1`,
    /// `wmav2`, `wmapro`, `wmalossless`; `dsd`, `dsd_lsbf_planar`; `musepack7`, `musepack8`.
    public static let undecodablePrefixes: [String] = [
        "wma", "dsd", "musepack", "wavpack",
    ]

    /// Normalises the many spellings a server might use — a container name,
    /// a codec name, a MIME type, a file extension.
    public static func normalise(_ codec: String?) -> String? {
        guard let codec else { return nil }
        var value = codec.lowercased()
        // A MIME type can carry parameters: "audio/ogg; codecs=vorbis".
        if let semicolon = value.firstIndex(of: ";") {
            value = String(value[..<semicolon])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        if let dot = value.lastIndex(of: ".") {
            value = String(value[value.index(after: dot)...])
        }
        // "audio/x-ms-wma" is "x-ms-wma": strip the vendor prefixes, however
        // many there are.
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["x-", "ms-"] where value.hasPrefix(prefix) && value.count > prefix.count {
                value.removeFirst(prefix.count)
                stripped = true
            }
        }
        return value.isEmpty ? nil : value
    }

    /// Formats the app decodes itself, with a decoder it carries, because Core Audio on iOS will
    /// not: Ogg Vorbis, measured on 2026-10-05 on the iOS 26 simulator runtime, where an Ogg Opus
    /// file opened and decoded and an Ogg Vorbis one failed with…
    public static let bundledDecoders: Set<String> = ["vorbis", "ogg", "oga"]

    /// Whether the device can play this codec as it stands.
    public static func canDecode(_ codec: String?, includingBundled: Bool = false) -> Bool {
        guard let value = normalise(codec) else { return true }
        if decodableCodecs.contains(value) { return true }
        if includingBundled, bundledDecoders.contains(value) { return true }
        if knownUndecodableCodecs.contains(value) { return false }
        if undecodablePrefixes.contains(where: value.hasPrefix) { return false }
        return true
    }

    /// The format to ask the server for, or nil to send the file untouched.
    public static func transcodeTarget(
        for codec: String?,
        preferred: String = "aac"
    ) -> String? {
        canDecode(codec) ? nil : preferred
    }
}
