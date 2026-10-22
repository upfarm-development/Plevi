import Foundation

/// Album listing filters. Providers map these to their native list endpoints
/// (Subsonic `getAlbumList2` types, Plex library section filters).
public enum AlbumFilter: Hashable, Sendable, Codable {
    case recentlyAdded
    /// By the record's own release date, newest first — not by when it was added to the server,
    /// which `recentlyAdded` already answers.
    case recentlyReleased
    case recentlyPlayed
    case mostPlayed
    case highestRated
    case random
    /// Records worth meeting again: never played, or not for a long time.
    case rediscover
    case favorites
    case alphabeticalByName
    case alphabeticalByArtist
    case genre(String)
    case yearRange(from: Int, to: Int)
}

/// Formats a server can transcode to on the fly. Used both for bandwidth
/// management and for codecs the device cannot decode natively (Ogg Vorbis,
/// Opus-in-Ogg).
public enum TranscodeCodec: String, Hashable, Sendable, Codable, CaseIterable {
    case mp3
    case aac
    case opus
}

/// Where the audio for a track comes from.
public struct StreamSource: Sendable {
    public enum Kind: Sendable, Hashable {
        /// The request's response is the audio.
        case file
    }

    public var request: URLRequest
    public var kind: Kind

    public init(request: URLRequest, kind: Kind = .file) {
        self.request = request
        self.kind = kind
    }
}

/// Options for building a stream or download request.
public struct StreamOptions: Hashable, Sendable {
    /// Cap in kbit/s; nil means no cap.
    public var maxBitRateKbps: Int?
    /// Request server-side transcoding to this codec; nil requests the
    /// original file untouched.
    public var transcodeTo: TranscodeCodec?
    /// Start position for transcoded seeks. Honoured only when the server's
    /// capabilities include `.transcodeOffset`.
    public var startOffset: TimeInterval?
    /// Ask the server to estimate Content-Length for transcoded media so
    /// progress reporting works.
    public var estimateContentLength: Bool

    public init(
        maxBitRateKbps: Int? = nil,
        transcodeTo: TranscodeCodec? = nil,
        startOffset: TimeInterval? = nil,
        estimateContentLength: Bool = false
    ) {
        self.maxBitRateKbps = maxBitRateKbps
        self.transcodeTo = transcodeTo
        self.startOffset = startOffset
        self.estimateContentLength = estimateContentLength
    }

    /// The original file, no transcoding, no bitrate cap.
    public static let original = StreamOptions()
}
