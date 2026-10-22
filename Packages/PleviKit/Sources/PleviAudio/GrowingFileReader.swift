import AVFoundation
import Foundation

/// Reading only what a file that is still arriving can actually deliver.
public enum GrowingFileReader {
    public struct Result {
        /// Consecutive decoded buffers, starting at the frame asked for.
        public var buffers: [AVAudioPCMBuffer]
        /// Frames in `buffers`.
        public var frames: Int64
        /// The file as opened, for its format and declared length.
        public var file: AVAudioFile
        /// What the header declares.
        public var declaredLength: Int64
        public var sampleRate: Double
        /// Whether the read stopped because the bytes on disk ran out (as
        /// opposed to reaching `limit`). If so, nothing more can be read until
        /// more has arrived.
        public var needsMoreData: Bool
    }

    /// Bytes on disk now, read fresh each time (`URL` caches resource values).
    public static func bytesOnDisk(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Decodes from `start` towards `limit`, stopping at whichever comes first: the limit, or the
    /// end of what is decodable from the bytes on disk.
    public static func read(
        url: URL,
        from start: Int64,
        limit: (_ declaredLength: Int64, _ sampleRate: Double) -> Int64,
        chunkSeconds: Double = 0.5
    ) -> Result? {
        guard let reader = try? AVAudioFile(forReading: url) else { return nil }
        let format = reader.processingFormat
        let declared = reader.length
        let chunkFrames = AVAudioFrameCount(max(1, (format.sampleRate * chunkSeconds).rounded()))
        let end = min(limit(declared, format.sampleRate), declared)
        var result = Result(
            buffers: [],
            frames: 0,
            file: reader,
            declaredLength: declared,
            sampleRate: format.sampleRate,
            needsMoreData: false
        )
        guard start >= 0, start < end else { return result }
        reader.framePosition = start
        var position = start
        while position < end {
            let wanted = AVAudioFrameCount(min(Int64(chunkFrames), end - position))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else { break }
            do {
                try reader.read(into: buffer, frameCount: wanted)
            } catch {
                result.needsMoreData = true
                break
            }
            // A short read is the end of what the bytes hold.
            guard buffer.frameLength == wanted else {
                result.needsMoreData = true
                break
            }
            result.buffers.append(buffer)
            position += Int64(wanted)
        }
        result.frames = position - start
        return result
    }
}
