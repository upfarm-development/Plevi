import Foundation

/// Why a response that said "200 OK" is not a song.
public enum NotAudioReason: Sendable, Equatable {
    /// A zero-byte body.
    case empty
    /// The server labelled it as text, JSON or XML.
    case textual(contentType: String)
    /// Its first bytes are markup or a server's JSON envelope, whatever it was
    /// labelled.
    case markup
    /// The body is not the length the server announced.
    case lengthMismatch(expected: Int64, actual: Int64)
    /// Too small to be a song, and not something a decoder can open either.
    case tooSmall(bytes: Int64)

    /// A sentence for a row that says what went wrong.
    public var message: String {
        switch self {
        case .empty:
            "The server sent an empty file."
        case .textual, .markup:
            "The server sent a web page or an error instead of the song."
        case .lengthMismatch(let expected, let actual):
            "The song arrived incomplete (\(actual) of \(expected) bytes)."
        case .tooSmall:
            "The server sent something too small to be the song."
        }
    }

    /// Whether this looks like a page in the way rather than a damaged
    /// transfer: what a sign-in wall in front of the server produces.
    public var looksLikeAWebPage: Bool {
        switch self {
        case .textual(let contentType):
            let type = contentType.lowercased()
            return type.contains("html") || type.contains("xhtml")
        case .markup:
            return true
        case .empty, .lengthMismatch, .tooSmall:
            return false
        }
    }
}

public enum AudioResponseCheck {
    /// The bytes of a file that decide whether it is markup.
    public static let sniffLength = 512

    /// Whether a `Content-Type` is one that can never be a song.
    public static func isTextualContentType(_ contentType: String?) -> Bool {
        guard let raw = contentType?.lowercased() else { return false }
        let type = raw.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
        if type.hasPrefix("text/") { return true }
        if type == "application/json" || type == "application/xml"
            || type == "application/xhtml+xml" || type == "application/javascript" {
            return true
        }
        return type.hasSuffix("+json") || type.hasSuffix("+xml")
    }

    /// Whether the first bytes of a body are markup or a server's error
    /// envelope. No audio container starts this way: MP3 opens on `ID3` or a
    /// frame sync, FLAC on `fLaC`, Ogg on `OggS`, MP4 on a box size.
    public static func startsLikeMarkup(_ head: Data) -> Bool {
        var bytes = head.prefix(sniffLength)[...]
        // A byte-order mark and leading whitespace come before the real first
        // character.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            bytes = bytes.dropFirst()
        }
        guard let first = bytes.first else { return false }
        if first == UInt8(ascii: "<") { return true }
        if first == UInt8(ascii: "{") {
            let text = String(decoding: bytes.prefix(64), as: UTF8.self).lowercased()
            return text.hasPrefix("{\"subsonic-response") || text.hasPrefix("{\"mediacontainer")
                || text.hasPrefix("{\"error") || text.hasPrefix("{\"message")
        }
        return false
    }

    /// The judgement, from what is known about a finished body.
    public static func verdict(
        contentType: String?,
        announcedLength: Int64?,
        size: Int64,
        head: Data
    ) -> NotAudioReason? {
        if size == 0 { return .empty }
        if isTextualContentType(contentType) {
            return .textual(contentType: contentType ?? "")
        }
        if startsLikeMarkup(head) { return .markup }
        if let announcedLength, announcedLength > 0, announcedLength != size {
            return .lengthMismatch(expected: announcedLength, actual: size)
        }
        return nil
    }

    /// Below this, a file no decoder can open is taken for a stray response
    /// rather than a song — see `verdictForCachedStream`.
    public static let smallestPlausibleSong: Int64 = 64 * 1024

    /// The judgement for a file the play cache is about to file as a song, where there may be no
    /// response to consult.
    public static func verdictForCachedStream(
        contentType: String? = nil,
        announcedLength: Int64? = nil,
        size: Int64,
        head: Data,
        canOpen: Bool
    ) -> NotAudioReason? {
        if let reason = verdict(
            contentType: contentType,
            announcedLength: announcedLength,
            size: size,
            head: head
        ) {
            return reason
        }
        if !canOpen, size < smallestPlausibleSong { return .tooSmall(bytes: size) }
        return nil
    }

    /// The first bytes of a file, for the verdict above.
    public static func head(ofFileAt url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: sniffLength)) ?? Data()
    }

    /// The size on disk, read fresh each time.
    public static func size(ofFileAt url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// The same, for a file on disk and the response that produced it.
    public static func verdict(forFileAt url: URL, response: URLResponse?) -> NotAudioReason? {
        // Read from the file system each time: `URL` caches resource values,
        // and a file written a moment ago would report the size it had.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var head = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            head = (try? handle.read(upToCount: sniffLength)) ?? Data()
            try? handle.close()
        }
        let http = response as? HTTPURLResponse
        // Content-Length is only comparable to the bytes on disk when nothing
        // transformed the body on the way.
        let encoded = http?.value(forHTTPHeaderField: "Content-Encoding").map { !$0.isEmpty && $0.lowercased() != "identity" } ?? false
        let announced: Int64? = {
            guard let http, !encoded, http.statusCode == 200 else { return nil }
            return http.expectedContentLength > 0 ? http.expectedContentLength : nil
        }()
        return verdict(
            contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? response?.mimeType,
            announcedLength: announced,
            size: size,
            head: head
        )
    }
}
