#!/usr/bin/env swift
// Renders the placeholder app icon: an eighth note on a blue gradient.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("could not create bitmap context")
}

// Background: diagonal gradient, light blue down to deep indigo.
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.36, green: 0.66, blue: 0.99, alpha: 1),
        CGColor(red: 0.16, green: 0.28, blue: 0.72, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

// Note head: an ellipse tilted the way engraved notation draws it.
context.saveGState()
context.translateBy(x: 395, y: 330)
context.rotate(by: -20 * .pi / 180)
context.fillEllipse(in: CGRect(x: -158, y: -118, width: 316, height: 236))
context.restoreGState()

// Stem rising from the right edge of the head.
let stem = CGPath(
    roundedRect: CGRect(x: 505, y: 300, width: 58, height: 480),
    cornerWidth: 29,
    cornerHeight: 29,
    transform: nil
)
context.addPath(stem)
context.fillPath()

// Flag hooking off the top of the stem.
let flag = CGMutablePath()
flag.move(to: CGPoint(x: 545, y: 762))
flag.addCurve(
    to: CGPoint(x: 610, y: 505),
    control1: CGPoint(x: 715, y: 735),
    control2: CGPoint(x: 700, y: 590)
)
context.addPath(flag)
context.setLineWidth(62)
context.setLineCap(.round)
context.strokePath()

guard let image = context.makeImage() else {
    fatalError("could not render image")
}
try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("could not create image destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("could not write \(output.path)")
}
print("wrote \(output.path)")
