import SwiftUI
import CoreGraphics
import UIKit
import PleviPalette

/// The colour a sleeve gives off, for the wash behind the playing screen.
enum WatchWash {
    /// 32 across rather than the phone's 48. The answer is a single dominant
    /// colour, and on a watch the difference between the two is invisible
    /// while the work is halved.
    private static let side = 32

    static func colour(from image: UIImage) -> Color? {
        guard let pixels = downsampled(image), !pixels.isEmpty else { return nil }
        guard let dominant = ArtworkColorAnalyzer.dominantColor(in: pixels) else { return nil }
        // The hue comes from the colourful parts, and how dark to keep it from the cover as a
        // whole.
        let colors = ArtworkColorAnalyzer.readableColors(
            from: dominant,
            artworkLuminance: ArtworkColorAnalyzer.meanLuminance(of: pixels),
            darkFraction: ArtworkColorAnalyzer.darkFraction(of: pixels)
        )
        return Color(
            red: colors.background.red,
            green: colors.background.green,
            blue: colors.background.blue
        )
    }

    private static func downsampled(_ image: UIImage) -> [RGBColor]? {
        guard let cgImage = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &data,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 0, to: data.count, by: 4).map { i in
            RGBColor(
                red: Double(data[i]) / 255,
                green: Double(data[i + 1]) / 255,
                blue: Double(data[i + 2]) / 255
            )
        }
    }
}
