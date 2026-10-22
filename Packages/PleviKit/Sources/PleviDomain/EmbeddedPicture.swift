import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// The cover picture written into an audio file's own tags.
public enum EmbeddedPicture {
    /// A picture larger than this is not a cover, it is something wrong.
    static let sizeLimit = 24 * 1024 * 1024

    /// The picture's bytes — JPEG or PNG as the tag held them — or nil.
    public static func read(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let source = FileSource(handle)
        if isImage(source) {
            guard let size = source.length, size <= sizeLimit else { return nil }
            return source.read(at: 0, count: size)
        }
        return read(from: source)
    }

    /// The picture in the first bytes of an audio file — what a range request
    /// for its head brings back. Nil when the picture does not fit in them.
    public static func read(fromHead head: Data) -> Data? {
        read(from: DataSource(head))
    }

    private static func read(from source: any ByteSource) -> Data? {
        guard let magic = source.read(at: 0, count: 12) else { return nil }
        if magic.starts(with: Data("fLaC".utf8)) { return flac(source) }
        if magic.starts(with: Data("ID3".utf8)) { return id3(source) }
        if magic.count >= 8, magic[4..<8] == Data("ftyp".utf8) { return mp4(source) }
        return nil
    }

    private static func isImage(_ source: any ByteSource) -> Bool {
        guard let magic = source.read(at: 0, count: 4) else { return false }
        let bytes = [UInt8](magic)
        return bytes.starts(with: [0xFF, 0xD8, 0xFF]) || bytes == [0x89, 0x50, 0x4E, 0x47]
    }

    #if canImport(ImageIO)
    /// The picture re-encoded no larger than `maxPixels` on its longer side,
    /// or as it is when already that small. Nil when it cannot be read.
    public static func downsized(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        guard max(width, height) > maxPixels else { return data }
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
    #endif

    // MARK: FLAC

    /// `METADATA_BLOCK_PICTURE`s sit in the metadata blocks before the audio:
    /// a four-byte header (last flag, type, 24-bit length) and a body. The
    /// front cover wins when there are several; otherwise the first.
    static func flac(_ source: any ByteSource) -> Data? {
        var offset = 4
        var first: Data?
        while let header = source.read(at: offset, count: 4) {
            let isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = Int(header[header.startIndex + 1]) << 16
                | Int(header[header.startIndex + 2]) << 8
                | Int(header[header.startIndex + 3])
            if type == 6, length <= sizeLimit,
               let body = source.read(at: offset + 4, count: length),
               let picture = flacPicture(body) {
                if picture.type == 3 { return picture.data }
                first = first ?? picture.data
            }
            if isLast { break }
            offset += 4 + length
        }
        return first
    }

    private static func flacPicture(_ body: Data) -> (type: UInt32, data: Data)? {
        var cursor = ByteCursor(body)
        guard let type = cursor.uint32(),
              let mimeLength = cursor.uint32(), cursor.skip(Int(mimeLength)),
              let descriptionLength = cursor.uint32(), cursor.skip(Int(descriptionLength)),
              cursor.skip(16),   // width, height, depth, colours
              let dataLength = cursor.uint32(),
              let data = cursor.take(Int(dataLength)), !data.isEmpty
        else { return nil }
        return (type, data)
    }

    // MARK: ID3v2 (MP3 and others)

    /// The `APIC` frame (`PIC` in 2.2) of the tag at the start of the file.
    static func id3(_ source: any ByteSource) -> Data? {
        guard let header = source.read(at: 0, count: 10) else { return nil }
        let b = [UInt8](header)
        let version = Int(b[3])
        guard (2...4).contains(version) else { return nil }
        let size = synchsafe(b[6], b[7], b[8], b[9])
        guard size > 0, size <= sizeLimit, let tag = source.read(at: 10, count: size) else { return nil }
        var bytes = [UInt8](tag)
        // 2.3/2.4's optional extended header comes first and says how long it is.
        var position = 0
        if b[5] & 0x40 != 0, bytes.count >= 4 {
            let extended = version == 4
                ? synchsafe(bytes[0], bytes[1], bytes[2], bytes[3])
                : (Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])) + 4
            position = min(extended, bytes.count)
        }
        // Tag-wide unsynchronisation inserts a zero after every 0xFF.
        if b[5] & 0x80 != 0 { bytes = removingUnsynchronisation(bytes); position = min(position, bytes.count) }

        let frameHeader = version == 2 ? 6 : 10
        var first: Data?
        while position + frameHeader <= bytes.count {
            guard bytes[position] != 0 else { break }   // padding
            let id = String(decoding: bytes[position..<position + (version == 2 ? 3 : 4)], as: UTF8.self)
            let length: Int
            switch version {
            case 2: length = Int(bytes[position + 3]) << 16 | Int(bytes[position + 4]) << 8 | Int(bytes[position + 5])
            case 3: length = Int(bytes[position + 4]) << 24 | Int(bytes[position + 5]) << 16
                | Int(bytes[position + 6]) << 8 | Int(bytes[position + 7])
            default: length = synchsafe(bytes[position + 4], bytes[position + 5], bytes[position + 6], bytes[position + 7])
            }
            let start = position + frameHeader
            guard length >= 0, start + length <= bytes.count else { break }
            if id == "APIC" || id == "PIC",
               let picture = id3Picture(Array(bytes[start..<start + length]), shortFormat: version == 2) {
                if picture.type == 3 { return picture.data }
                first = first ?? picture.data
            }
            position = start + length
        }
        return first
    }

    /// Text encoding, MIME type (a three-letter format in 2.2), picture type,
    /// a description in the same encoding, then the image.
    private static func id3Picture(_ frame: [UInt8], shortFormat: Bool) -> (type: UInt8, data: Data)? {
        guard frame.count > 4 else { return nil }
        let encoding = frame[0]
        var i = 1
        if shortFormat {
            i += 3
        } else {
            while i < frame.count, frame[i] != 0 { i += 1 }
            i += 1
        }
        guard i < frame.count else { return nil }
        let type = frame[i]
        i += 1
        // The description ends at a terminator as wide as its encoding.
        let wide = encoding == 1 || encoding == 2
        while i < frame.count {
            if wide {
                if i + 1 < frame.count, frame[i] == 0, frame[i + 1] == 0 { i += 2; break }
                i += 2
            } else {
                if frame[i] == 0 { i += 1; break }
                i += 1
            }
        }
        guard i < frame.count else { return nil }
        return (type, Data(frame[i...]))
    }

    private static func synchsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7F) << 21 | Int(b & 0x7F) << 14 | Int(c & 0x7F) << 7 | Int(d & 0x7F)
    }

    private static func removingUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0 { i += 1 }
            i += 1
        }
        return out
    }

    // MARK: MP4 (M4A, ALAC)

    /// `moov` → `udta` → `meta` → `ilst` → `covr` → `data`. Walked by header,
    /// seeking past everything else, since `moov` is as likely to be at the
    /// end of the file as the start.
    static func mp4(_ source: any ByteSource) -> Data? {
        guard let end = source.length else { return nil }
        guard let moov = findAtom("moov", in: 0..<end, source: source) else { return nil }
        guard let udta = findAtom("udta", in: moov, source: source),
              let meta = findAtom("meta", in: udta, source: source, skipping: 4),
              let ilst = findAtom("ilst", in: meta, source: source),
              let covr = findAtom("covr", in: ilst, source: source),
              let data = findAtom("data", in: covr, source: source)
        else { return nil }
        // Version and flags, then a locale: eight bytes before the picture.
        let payload = (data.lowerBound + 8)..<data.upperBound
        guard payload.count > 0, payload.count <= sizeLimit else { return nil }
        return source.read(at: payload.lowerBound, count: payload.count)
    }

    /// The body of the first atom called `name` among those in `range`.
    /// `skipping` is the bytes a full box puts between its header and its
    /// children.
    private static func findAtom(
        _ name: String, in range: Range<Int>, source: any ByteSource, skipping: Int = 0
    ) -> Range<Int>? {
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            guard let header = source.read(at: offset, count: 8) else { return nil }
            let h = [UInt8](header)
            var size = Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            var headerSize = 8
            if size == 1 {
                guard let wide = source.read(at: offset + 8, count: 8) else { return nil }
                size = wide.reduce(0) { $0 << 8 | Int($1) }
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= headerSize, offset + size <= range.upperBound else { return nil }
            if String(decoding: h[4..<8], as: UTF8.self) == name {
                let start = offset + headerSize + skipping
                return start <= offset + size ? start..<(offset + size) : nil
            }
            offset += size
        }
        return nil
    }

    // MARK: Reading

    /// Positioned reads over something with a length; short or failed reads
    /// are nil.
    protocol ByteSource {
        var length: Int? { get }
        func read(at offset: Int, count: Int) -> Data?
    }

    struct DataSource: ByteSource {
        let data: Data

        init(_ data: Data) { self.data = data }

        var length: Int? { data.count }

        func read(at offset: Int, count: Int) -> Data? {
            guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
            return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
        }
    }

    struct FileSource: ByteSource {
        let handle: FileHandle

        init(_ handle: FileHandle) { self.handle = handle }

        var length: Int? {
            guard let size = try? handle.seekToEnd() else { return nil }
            return Int(size)
        }

        func read(at offset: Int, count: Int) -> Data? {
            guard count >= 0, (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count
            else { return nil }
            return data
        }
    }

    struct ByteCursor {
        private let data: Data
        private var position: Int

        init(_ data: Data) {
            self.data = data
            position = data.startIndex
        }

        mutating func uint32() -> UInt32? {
            guard position + 4 <= data.endIndex else { return nil }
            defer { position += 4 }
            return data[position..<position + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, position + count <= data.endIndex else { return false }
            position += count
            return true
        }

        mutating func take(_ count: Int) -> Data? {
            guard count >= 0, position + count <= data.endIndex else { return nil }
            defer { position += count }
            return data[position..<position + count]
        }
    }
}

extension ArtworkID {
    private static let embeddedPrefix = "embedded:"

    /// The picture inside a song's own downloaded file, as artwork.
    public static func embedded(in track: MediaID) -> ArtworkID {
        ArtworkID(server: track.server, rawValue: embeddedPrefix + track.rawValue)
    }

    /// The song whose file this artwork lives in, when it is that kind.
    public var embeddedTrack: MediaID? {
        guard rawValue.hasPrefix(Self.embeddedPrefix) else { return nil }
        return MediaID(server: server, rawValue: String(rawValue.dropFirst(Self.embeddedPrefix.count)))
    }
}

/// A picture reduced to what it looks like, small enough to compare two that were scaled and
/// re-encoded differently.
public struct ArtworkSignature: Sendable, Equatable {
    static let side = 16
    private let samples: [UInt8]

    /// Beyond this mean difference (0 to 1) two pictures are different art.
    public static let differenceThreshold = 0.08

    #if canImport(ImageIO)
    public init?(imageData: Data) {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
              ] as CFDictionary)
        else { return nil }
        self.init(cgImage: image)
    }

    /// Reduced in two steps whatever size it starts at, so a 1500-pixel
    /// original and a 300-pixel copy of the same cover meet at the same
    /// intermediate size and come out alike.
    public init?(cgImage image: CGImage) {
        guard let middle = Self.draw(image, side: 64), let small = Self.draw(middle, side: Self.side),
              let pixels = small.dataProvider?.data as Data?
        else { return nil }
        samples = [UInt8](pixels)
    }

    private static func draw(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
    #endif

    /// Mean difference per colour channel, 0 (identical) to 1.
    public func distance(to other: ArtworkSignature) -> Double {
        var total = 0
        var count = 0
        for i in samples.indices where i % 4 != 3 {
            total += abs(Int(samples[i]) - Int(other.samples[i]))
            count += 1
        }
        return count == 0 ? 0 : Double(total) / Double(count) / 255
    }

    public func isDifferent(from other: ArtworkSignature) -> Bool {
        distance(to: other) > Self.differenceThreshold
    }
}
