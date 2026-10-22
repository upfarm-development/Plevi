import Foundation

/// How big a conversion is expected to be, from its bit rate and the song's own length — the
/// denominator a progress bar needs when the server sends no `Content-Length` for a transcode,
/// which is every transcode: Plex's transcoder segments a…
func estimatedConversionBytes(kbps: Int?, duration: TimeInterval?) -> Int64? {
    guard let kbps, kbps > 0, let duration, duration > 0 else { return nil }
    return Int64(duration * Double(kbps) * 1000 / 8)
}
