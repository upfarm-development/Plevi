import Foundation
import Testing
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import PleviDomain

/// Reading a cover out of an audio file's tags, and telling two covers apart.
@Suite("Embedded pictures")
struct EmbeddedPictureTests {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + (0..<40).map { UInt8($0) })

    private func file(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "embedded-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func be32(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func synchsafe(_ value: Int) -> [UInt8] {
        [UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
    }

    // MARK: FLAC

    private func flacBlock(type: UInt8, last: Bool, body: [UInt8]) -> [UInt8] {
        [(last ? 0x80 : 0) | type, UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    private func flacPicture(type: Int, data: Data) -> [UInt8] {
        let mime = Array("image/jpeg".utf8)
        return be32(type) + be32(mime.count) + mime + be32(0)
            + be32(1500) + be32(1500) + be32(24) + be32(0) + be32(data.count) + [UInt8](data)
    }

    @Test("A FLAC's picture block is read")
    func flacPictureIsRead() throws {
        let streamInfo = flacBlock(type: 0, last: false, body: [UInt8](repeating: 1, count: 34))
        let comment = flacBlock(type: 4, last: false, body: [UInt8](repeating: 2, count: 20))
        let picture = flacBlock(type: 6, last: true, body: flacPicture(type: 3, data: jpeg))
        let url = try file(Array("fLaC".utf8) + streamInfo + comment + picture + [0xFF, 0xF8, 0, 0])
        #expect(EmbeddedPicture.read(from: url) == jpeg)
    }

    @Test("A FLAC prefers the front cover over another picture")
    func flacPrefersFrontCover() throws {
        let back = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9, 9])
        let blocks = flacBlock(type: 6, last: false, body: flacPicture(type: 4, data: back))
            + flacBlock(type: 6, last: true, body: flacPicture(type: 3, data: jpeg))
        let url = try file(Array("fLaC".utf8) + blocks)
        #expect(EmbeddedPicture.read(from: url) == jpeg)
    }

    @Test("A FLAC with no picture answers nil")
    func flacWithoutPicture() throws {
        let streamInfo = flacBlock(type: 0, last: true, body: [UInt8](repeating: 1, count: 34))
        let url = try file(Array("fLaC".utf8) + streamInfo)
        #expect(EmbeddedPicture.read(from: url) == nil)
    }

    @Test("A FLAC cut off in the middle of its picture answers nil")
    func flacTruncated() throws {
        let picture = flacBlock(type: 6, last: true, body: flacPicture(type: 3, data: jpeg))
        let url = try file(Array("fLaC".utf8) + picture.dropLast(10))
        #expect(EmbeddedPicture.read(from: url) == nil)
    }

    // MARK: ID3v2

    private func id3(version: UInt8, frames: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        Array("ID3".utf8) + [version, 0, flags] + synchsafe(frames.count) + frames
    }

    private func apic(version: UInt8, type: UInt8, data: Data, encoding: UInt8 = 0, description: [UInt8] = [0]) -> [UInt8] {
        let body: [UInt8] = [encoding] + Array("image/jpeg".utf8) + [0, type] + description + [UInt8](data)
        let size = version == 4 ? synchsafe(body.count) : be32(body.count)
        return Array("APIC".utf8) + size + [0, 0] + body
    }

    @Test("An ID3v2.3 APIC frame is read")
    func id3v23() throws {
        let text = Array("TIT2".utf8) + be32(4) + [0, 0] + [0, 65, 66, 67]
        let url = try file(id3(version: 3, frames: text + apic(version: 3, type: 3, data: jpeg)) + [0xFF, 0xFB])
        #expect(EmbeddedPicture.read(from: url) == jpeg)
    }

    @Test("An ID3v2.4 APIC frame with a UTF-16 description is read")
    func id3v24Utf16() throws {
        let description: [UInt8] = [0xFF, 0xFE, 0x41, 0x00, 0x00, 0x00]
        let url = try file(id3(version: 4, frames: apic(version: 4, type: 3, data: jpeg, encoding: 1, description: description)))
        #expect(EmbeddedPicture.read(from: url) == jpeg)
    }

    @Test("A tag with padding and no picture answers nil")
    func id3WithoutPicture() throws {
        let text = Array("TIT2".utf8) + be32(4) + [0, 0] + [0, 65, 66, 67]
        let url = try file(id3(version: 3, frames: text + [UInt8](repeating: 0, count: 30)))
        #expect(EmbeddedPicture.read(from: url) == nil)
    }

    // MARK: MP4

    private func atom(_ name: String, _ body: [UInt8]) -> [UInt8] {
        be32(body.count + 8) + Array(name.utf8) + body
    }

    private func m4a(moovAtEnd: Bool) -> [UInt8] {
        let data = atom("data", be32(13) + be32(0) + [UInt8](jpeg))
        let ilst = atom("ilst", be32(8 + 16 + 5) + [0xA9] + Array("nam".utf8) + atom("data", be32(1) + be32(0) + Array("Title".utf8)) + atom("covr", data))
        let meta = atom("meta", be32(0) + ilst)
        let moov = atom("moov", atom("mvhd", [UInt8](repeating: 0, count: 100)) + atom("udta", meta))
        let ftyp = atom("ftyp", Array("M4A ".utf8) + be32(0))
        let mdat = atom("mdat", [UInt8](repeating: 7, count: 500))
        return moovAtEnd ? ftyp + mdat + moov : ftyp + moov + mdat
    }

    @Test("An M4A's covr atom is read wherever moov sits")
    func mp4Cover() throws {
        #expect(EmbeddedPicture.read(from: try file(m4a(moovAtEnd: false))) == jpeg)
        #expect(EmbeddedPicture.read(from: try file(m4a(moovAtEnd: true))) == jpeg)
    }

    @Test("Something that is not a recognised audio file answers nil")
    func unknownFormat() throws {
        #expect(EmbeddedPicture.read(from: try file([UInt8](repeating: 0x41, count: 64))) == nil)
        #expect(EmbeddedPicture.read(from: try file([])) == nil)
        #expect(EmbeddedPicture.read(from: URL(filePath: "/nonexistent/none.flac")) == nil)
    }

    // MARK: Head of a file, and a picture kept on its own

    @Test("The picture is read from the head of a file that has been cut short after it")
    func headOfFile() throws {
        let streamInfo = flacBlock(type: 0, last: false, body: [UInt8](repeating: 1, count: 34))
        let picture = flacBlock(type: 6, last: true, body: flacPicture(type: 3, data: jpeg))
        let head = Data(Array("fLaC".utf8) + streamInfo + picture + [UInt8](repeating: 0xAB, count: 1000))
        #expect(EmbeddedPicture.read(fromHead: head) == jpeg)
    }

    @Test("A head that ends inside the picture answers nil")
    func headEndsInsidePicture() throws {
        let picture = flacBlock(type: 6, last: true, body: flacPicture(type: 3, data: jpeg))
        let head = Data(Array("fLaC".utf8) + picture.dropLast(20))
        #expect(EmbeddedPicture.read(fromHead: head) == nil)
    }

    @Test("A file that is itself a picture is answered as it stands")
    func pictureOnItsOwn() throws {
        let bytes = [UInt8](jpeg)
        #expect(EmbeddedPicture.read(from: try file(bytes)) == jpeg)
    }

    @Test("A large picture is shrunk to the size asked, and a small one left alone")
    func downsizing() throws {
        let large = picture([(0.8, 0.1, 0.1), (0.1, 0.2, 0.7)], size: 1500, type: .jpeg)
        let small = try #require(EmbeddedPicture.downsized(large, maxPixels: 600))
        let source = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let width = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        #expect(width == 600)
        #expect(EmbeddedPicture.downsized(small, maxPixels: 1200) == small)
        #expect(EmbeddedPicture.downsized(Data([1, 2, 3]), maxPixels: 600) == nil)
    }

    // MARK: Signature

    /// A picture of horizontal bands, encoded as the given type.
    private func picture(_ colours: [(CGFloat, CGFloat, CGFloat)], size: Int, type: UTType) -> Data {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let band = CGFloat(size) / CGFloat(colours.count)
        for (i, c) in colours.enumerated() {
            context.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            context.fill(CGRect(x: 0, y: CGFloat(i) * band, width: CGFloat(size), height: band))
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    private let sunset: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.1, 0.1), (0.9, 0.6, 0.2), (0.3, 0.2, 0.1)]
    private let ocean: [(CGFloat, CGFloat, CGFloat)] = [(0.1, 0.2, 0.7), (0.2, 0.6, 0.8), (0.0, 0.1, 0.3)]

    @Test("The same cover at another size and encoding is not different")
    func sameCoverIsSame() throws {
        let big = try #require(ArtworkSignature(imageData: picture(sunset, size: 1200, type: .png)))
        let small = try #require(ArtworkSignature(imageData: picture(sunset, size: 300, type: .jpeg)))
        #expect(!big.isDifferent(from: small))
        #expect(big.distance(to: small) < 0.04)
    }

    @Test("Two different covers are different")
    func differentCoversDiffer() throws {
        let a = try #require(ArtworkSignature(imageData: picture(sunset, size: 600, type: .jpeg)))
        let b = try #require(ArtworkSignature(imageData: picture(ocean, size: 600, type: .jpeg)))
        #expect(a.isDifferent(from: b))
    }

    @Test("Bytes that are not a picture have no signature")
    func notAPicture() {
        #expect(ArtworkSignature(imageData: Data([1, 2, 3, 4])) == nil)
    }
}
