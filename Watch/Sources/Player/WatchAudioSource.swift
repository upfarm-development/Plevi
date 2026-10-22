import Foundation
import AVFoundation
import PleviAudio
import PleviDomain
import PleviTransport

/// Turns a track into something `AVPlayer` can play.
struct WatchAudioSource {
    let config: ServerConfig
    let provider: any MusicServerProvider
    let transport: any HTTPTransport
    let proxySessions: (any ProxySessionSource)?

    /// Whether this server's audio has to come through our transport.
    var needsOwnTransport: Bool {
        if !config.pinnedCertificates.isEmpty { return true }
        if config.usesClientCertificate { return true }
        if let url = config.addresses.preferred as URL?,
           proxySessions?.session(for: url) != nil { return true }
        return false
    }

    enum Prepared {
        /// Ready to play, and it will stream as it arrives.
        case streaming(AVPlayerItem)
        /// Has to be fetched whole first.
        case needsFetch(StreamSource)
    }

    func prepare(_ track: Track, options: StreamOptions) async throws -> Prepared {
        let source = try await provider.streamSource(for: track.id, options: options)
        guard !needsOwnTransport else { return .needsFetch(source) }
        guard let url = source.request.url else { throw WatchPlaybackError.noURL }
        return .streaming(AVPlayerItem(asset: asset(for: url, request: source.request)))
    }

    /// Custom headers reach AVFoundation through the community-standard but undocumented asset
    /// option — the same one the phone used before it owned its own fetch.
    private func asset(for url: URL, request: URLRequest) -> AVURLAsset {
        var headers = request.allHTTPHeaderFields ?? [:]
        if let authenticated = proxySessions?.authenticating(request).allHTTPHeaderFields {
            headers.merge(authenticated) { _, new in new }
        }
        guard !headers.isEmpty else { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    /// How a song would arrive, without deciding how to play it.
    func source(for track: Track, options: StreamOptions) async throws -> StreamSource {
        try await provider.streamSource(for: track.id, options: options)
    }

    /// What to call the file a fetched song is written to.
    static func fileExtension(
        for options: StreamOptions, track: Track, request: URLRequest
    ) -> String {
        // A conversion arrives in the container its codec belongs in: Opus
        // in Ogg, AAC in MPEG-4, MP3 as itself.
        if let codec = options.transcodeTo {
            switch codec {
            case .aac: return "m4a"
            case .opus: return "ogg"
            default: return codec.rawValue
            }
        }
        // Only an extension AVFoundation opens: a Subsonic download URL ends
        // in `download.view`, which is not a format.
        let fromServer = request.url?.pathExtension.lowercased() ?? ""
        if AudioContainer.playableExtensions.contains(fromServer) { return fromServer }
        // Then what the library says the song is. The raw codec string was
        // used here and an unrecognised one became the file's extension.
        if let known = AudioContainer.fileExtension(for: track.codec)
            ?? AudioContainer.fileExtension(for: track.contentType) {
            return known
        }
        // Nobody can say. `audio` marks the file to be named from its own
        // bytes once it has arrived — see `sniffedExtension(of:)`.
        return "audio"
    }

    /// What the first bytes of a file say it is, for a song that had to be
    /// saved without a name for its format.
    static func sniffedExtension(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16) else { return nil }
        return AudioContainer.sniff(head)
    }

    /// Fetches a whole song through the app's transport and hands back the file.
    func fetch(_ source: StreamSource, for track: Track, to destination: URL) async throws -> URL {
        do {
            try await transport.download(source.request, to: destination, onProgress: nil)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // A 2xx is not yet a song: a sign-in page, a server's error envelope
        // and an empty body all arrive this way, and kept, each becomes a
        // file the player is told to play.
        if let reason = AudioResponseCheck.verdict(forFileAt: destination, response: nil) {
            try? FileManager.default.removeItem(at: destination)
            throw WatchPlaybackError.notAudio(reason.message)
        }
        return destination
    }
}

enum WatchPlaybackError: LocalizedError {
    case noURL
    case server(Int)
    case notAudio(String)
    /// Not connected to the server yet, and the song is not on this watch.
    /// Not a fault in the song, so it is never counted towards giving up.
    case connecting

    var errorDescription: String? {
        switch self {
        case .noURL: "The server did not say where the audio is."
        case .server(let code): "The server answered \(code)."
        case .notAudio(let message): message
        case .connecting: "Connecting to your server…"
        }
    }
}
