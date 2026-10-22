import Foundation
import AVFoundation
import CVorbis

/// What a decoded Ogg Vorbis file was, for the badge: the original's own
/// figures, since the copy that is played is plain PCM and says nothing of it.
public struct VorbisSourceInfo: Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var frames: Int64
    /// The original's size against its length — the honest bit rate of an
    /// Ogg file, which carries no figure of its own worth trusting.
    public var bitRateKbps: Int?
}

/// Whether a file is Ogg Vorbis, which iOS cannot play — as opposed to Ogg
/// Opus, which it can, and which shares the container and the extension.
public enum VorbisFile {
    /// "OggS" at the start, and the Vorbis identification header ("\u{1}vorbis")
    /// at the start of the first page's data.
    public static func isVorbis(head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(256))
        guard bytes.count >= 35,
              bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53
        else { return false }
        // The first page's data begins after the 27-byte page header and its
        // segment table, whose length is byte 26.
        let tableLength = Int(bytes[26])
        let start = 27 + tableLength
        guard bytes.count >= start + 7 else { return false }
        return bytes[start] == 0x01
            && bytes[start + 1] == 0x76 && bytes[start + 2] == 0x6F && bytes[start + 3] == 0x72
            && bytes[start + 4] == 0x62 && bytes[start + 5] == 0x69 && bytes[start + 6] == 0x73
    }

    public static func isVorbis(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256) else { return false }
        return isVorbis(head: head)
    }
}

/// Decodes Ogg Vorbis into a plain PCM file the audio engine can read, the one
/// thing iOS's Core Audio will not do for it.
public enum VorbisDecoder {
    public enum DecodeError: Error, Equatable {
        case cannotOpen(code: Int32)
        case unsupported
        case writeFailed
    }

    /// Frames decoded at a time: small enough to keep memory flat on a long
    /// song, large enough that the loop is not the cost.
    private static let chunkFrames = 16_384

    /// Writes `source` as a 16-bit CAF at `destination`. The file appears under
    /// its final name only when it is complete.
    public static func decode(_ source: URL, to destination: URL) throws -> VorbisSourceInfo {
        var code: Int32 = 0
        guard let decoder = source.path.withCString({ cvorbis_open($0, &code) }) else {
            throw DecodeError.cannotOpen(code: code)
        }
        defer { cvorbis_close(decoder) }

        let channels = Int(cvorbis_channels(decoder))
        let rate = Int(cvorbis_sample_rate(decoder))
        guard channels > 0, channels <= 8, rate > 0 else { throw DecodeError.unsupported }

        let partial = destination.deletingPathExtension().appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(rate),
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var written: AVAudioFile?
        do {
            written = try AVAudioFile(
                forWriting: partial, settings: settings,
                commonFormat: .pcmFormatInt16, interleaved: true
            )
        } catch {
            throw DecodeError.writeFailed
        }
        guard let output = written, let buffer = AVAudioPCMBuffer(
            pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(chunkFrames)
        ), let samples = buffer.int16ChannelData?[0] else { throw DecodeError.writeFailed }

        var total: Int64 = 0
        while true {
            let frames = Int(cvorbis_read(decoder, samples, Int32(chunkFrames)))
            if frames <= 0 { break }
            buffer.frameLength = AVAudioFrameCount(frames)
            do { try output.write(from: buffer) } catch { throw DecodeError.writeFailed }
            total += Int64(frames)
        }
        guard total > 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw DecodeError.unsupported
        }
        // Releasing the writer is what finishes the file's header, so it goes
        // before the file is moved into place.
        written = nil
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: partial, to: destination) } catch { throw DecodeError.writeFailed }

        var kbps: Int?
        if let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, total > 0 {
            let seconds = Double(total) / Double(rate)
            if seconds > 0 { kbps = Int((Double(size) * 8 / seconds / 1000).rounded()) }
        }
        return VorbisSourceInfo(sampleRate: rate, channels: channels, frames: total, bitRateKbps: kbps)
    }

    // MARK: Decoding as it goes

    /// Decodes `source` into a CAF that can be read while it is still being written, and calls
    /// `onStart` as soon as enough is there to begin playing.
    @discardableResult
    public static func decodeProgressively(
        _ source: URL,
        to destination: URL,
        startAfterSeconds: Double = 1.5,
        onStart: (VorbisSourceInfo) -> Void
    ) throws -> VorbisSourceInfo {
        var code: Int32 = 0
        guard let decoder = source.path.withCString({ cvorbis_open($0, &code) }) else {
            throw DecodeError.cannotOpen(code: code)
        }
        defer { cvorbis_close(decoder) }
        let channels = Int(cvorbis_channels(decoder))
        let rate = Int(cvorbis_sample_rate(decoder))
        guard channels > 0, channels <= 8, rate > 0 else { throw DecodeError.unsupported }

        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination)
        else { throw DecodeError.writeFailed }
        defer { try? handle.close() }
        do { try handle.write(contentsOf: cafHeader(rate: rate, channels: channels)) } catch { throw DecodeError.writeFailed }

        var samples = [Int16](repeating: 0, count: chunkFrames * channels)
        var total: Int64 = 0
        var started = false
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        func info(frames: Int64) -> VorbisSourceInfo {
            var kbps: Int?
            if size > 0, frames > 0 {
                let seconds = Double(frames) / Double(rate)
                if seconds > 0 { kbps = Int((Double(size) * 8 / seconds / 1000).rounded()) }
            }
            return VorbisSourceInfo(sampleRate: rate, channels: channels, frames: frames, bitRateKbps: kbps)
        }

        while true {
            let frames = Int(samples.withUnsafeMutableBufferPointer { cvorbis_read(decoder, $0.baseAddress, Int32(chunkFrames)) })
            if frames <= 0 { break }
            // Little-endian 16-bit, which is what the CAF header says.
            let bytes = samples.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(start: $0.baseAddress, count: frames * channels)) }
            do { try handle.write(contentsOf: bytes) } catch { throw DecodeError.writeFailed }
            total += Int64(frames)
            if !started, Double(total) / Double(rate) >= startAfterSeconds {
                started = true
                // The estimated whole length, so a badge or a seek bar has a
                // figure to start from.
                let whole = Int64(cvorbis_total_frames(decoder))
                onStart(info(frames: whole > 0 ? whole : total))
            }
        }
        guard total > 0 else { throw DecodeError.unsupported }
        let final = info(frames: total)
        if !started { onStart(final) }
        return final
    }

    /// The start of a CAF file for 16-bit little-endian PCM whose data chunk
    /// runs to the end of the file. All CAF fields are big-endian.
    private static func cafHeader(rate: Int, channels: Int) -> Data {
        func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
        func be32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> UInt32(24 - 8 * $0)) & 0xFF) } }
        func be64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> UInt64(56 - 8 * $0)) & 0xFF) } }
        var bytes: [UInt8] = []
        bytes += Array("caff".utf8) + be16(1) + be16(0)
        // 'desc': sample rate (Float64), 'lpcm', flags, bytes per packet,
        // frames per packet, channels, bits per channel.
        bytes += Array("desc".utf8) + be64(32)
        bytes += be64(Double(rate).bitPattern)
        bytes += Array("lpcm".utf8)
        bytes += be32(2)                         // kCAFLinearPCMFormatFlagIsLittleEndian
        bytes += be32(UInt32(channels * 2))
        bytes += be32(1)
        bytes += be32(UInt32(channels))
        bytes += be32(16)
        // 'data': no declared size, then the edit count.
        bytes += Array("data".utf8) + be64(UInt64.max)
        bytes += be32(0)
        return Data(bytes)
    }
}
