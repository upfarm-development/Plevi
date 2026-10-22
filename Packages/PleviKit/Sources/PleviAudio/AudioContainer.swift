import Foundation

/// Which file extension a downloaded song should carry.
public enum AudioContainer {
    /// Extensions AVFoundation opens, so a guess from a URL is only trusted
    /// when it is one of them (`download.view` is not an audio extension).
    public static let playableExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "flac", "alac", "wav", "aif", "aiff", "aifc", "caf", "ogg", "opus",
    ]

    /// The extension for a codec, container name or MIME type, or nil when it
    /// names nothing playable.
    public static func fileExtension(for label: String?) -> String? {
        guard let value = NativeAudioSupport.normalise(label) else { return nil }
        switch value {
        case "mp3", "mpeg", "mpga": return "mp3"
        case "aac", "m4a", "mp4", "alac": return "m4a"
        case "m4b": return "m4b"
        case "flac": return "flac"
        case "wav", "wave", "pcm": return "wav"
        case "aiff", "aif", "aifc": return "aiff"
        case "caf": return "caf"
        case "ogg", "oga", "opus", "vorbis": return "ogg"
        default: return nil
        }
    }

    /// What the first bytes of a file say it is.
    public static func sniff(_ head: Data) -> String? {
        let bytes = [UInt8](head.prefix(16))
        guard bytes.count >= 4 else { return nil }
        func ascii(_ range: Range<Int>) -> String? {
            guard bytes.count >= range.upperBound else { return nil }
            return String(bytes: bytes[range], encoding: .isoLatin1)
        }
        if ascii(0..<3) == "ID3" { return "mp3" }
        if ascii(0..<4) == "fLaC" { return "flac" }
        if ascii(0..<4) == "OggS" { return "ogg" }
        if ascii(0..<4) == "caff" { return "caf" }
        if ascii(4..<8) == "ftyp" { return "m4a" }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return "wav" }
        if ascii(0..<4) == "FORM", let kind = ascii(8..<12), kind == "AIFF" || kind == "AIFC" { return "aiff" }
        // A bare MPEG audio frame: eleven bits of sync. ADTS AAC shares the
        // sync pattern and is told apart by its layer bits, which are 00.
        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            return bytes[1] & 0x06 == 0 ? "aac" : "mp3"
        }
        return nil
    }
}
