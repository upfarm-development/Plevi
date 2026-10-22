import SwiftUI
import PleviDomain

/// Hand-drawn line icons for the eight DJs, ported from the SVGs in the "Quiet List" hand-off
/// design rather than drawn fresh — every coordinate below is that source's own path data, only
/// rebased from its original pixel viewBox onto a 0...1…
enum DJGlyph {
    static func path(for kind: DJStrategyKind) -> AnyShape {
        switch kind {
        case .moody: AnyShape(MoodyGlyph())
        case .drift: AnyShape(DriftGlyph())
        case .era: AnyShape(EraGlyph())
        case .purist: AnyShape(PuristGlyph())
        case .deepCuts: AnyShape(DeepCutsGlyph())
        case .gold: AnyShape(GoldGlyph())
        case .fresh: AnyShape(FreshGlyph())
        case .journey: AnyShape(JourneyGlyph())
        }
    }
}

private func pt(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
}

/// Five bars of a waveform, the two outer ones worn down to ticks —
/// "matches the feel of what's playing."
struct MoodyGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.15, 0.5, 0.5), (0.325, 0.3, 0.7), (0.5, 0.175, 0.825), (0.675, 0.325, 0.675), (0.8625, 0.45, 0.45),
        ]
        for (x, y0, y1) in bars {
            path.move(to: pt(x, y0, in: rect))
            path.addLine(to: pt(x, y1, in: rect))
        }
        return path
    }
}

/// Two gusts, each a line trailing into a small curl — "lets go of the
/// queue, follows the sound."
struct DriftGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width

        path.move(to: pt(0.09, 0.34, in: rect))
        path.addLine(to: pt(0.56, 0.34, in: rect))
        path.addArc(
            center: pt(0.56, 0.225, in: rect), radius: 0.115 * w,
            startAngle: .degrees(90), endAngle: .degrees(340), clockwise: false
        )

        path.move(to: pt(0.09, 0.59, in: rect))
        path.addLine(to: pt(0.46, 0.59, in: rect))
        path.addArc(
            center: pt(0.46, 0.70, in: rect), radius: 0.10 * w,
            startAngle: .degrees(270), endAngle: .degrees(20), clockwise: true
        )
        return path
    }
}

/// A clock face — "stays in this song's decade."
struct EraGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(
            x: pt(0.1364, 0.1364, in: rect).x, y: pt(0.1364, 0.1364, in: rect).y,
            width: 0.7273 * rect.width, height: 0.7273 * rect.height
        ))
        path.move(to: pt(0.5, 0.295, in: rect))
        path.addLine(to: pt(0.5, 0.5, in: rect))
        path.addLine(to: pt(0.636, 0.591, in: rect))
        return path
    }
}

/// A shaft rising into a corner bracket — an arrow up and to the right,
/// "never leaves the genre."
struct PuristGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.182, 0.818, in: rect))
        path.addLine(to: pt(0.727, 0.273, in: rect))
        path.move(to: pt(0.591, 0.182, in: rect))
        path.addLine(to: pt(0.818, 0.182, in: rect))
        path.addLine(to: pt(0.818, 0.409, in: rect))
        return path
    }
}

/// A lidded box — "this vibe, but songs you never play."
struct DeepCutsGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(
            x: pt(0.159, 0.227, in: rect).x, y: pt(0.159, 0.227, in: rect).y,
            width: 0.682 * rect.width, height: 0.591 * rect.height
        ), cornerSize: CGSize(width: 0.1136 * rect.width, height: 0.1136 * rect.height))
        path.move(to: pt(0.159, 0.409, in: rect))
        path.addLine(to: pt(0.841, 0.409, in: rect))
        path.move(to: pt(0.386, 0.568, in: rect))
        path.addLine(to: pt(0.614, 0.568, in: rect))
        return path
    }
}

/// A five-point star, unfilled — "only your 4-star-and-up favourites."
struct GoldGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [
            (0.5, 0.159), (0.609, 0.382), (0.855, 0.418), (0.677, 0.591), (0.718, 0.836),
            (0.5, 0.723), (0.282, 0.836), (0.323, 0.591), (0.145, 0.418), (0.391, 0.382),
        ]
        var path = Path()
        path.move(to: pt(points[0].0, points[0].1, in: rect))
        for p in points.dropFirst() { path.addLine(to: pt(p.0, p.1, in: rect)) }
        path.closeSubpath()
        return path
    }
}

/// A plus over a faint X — an eight-point sparkle, "mixes in your newest
/// additions."
struct FreshGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.5, 0.182, in: rect))
        path.addLine(to: pt(0.5, 0.818, in: rect))
        path.move(to: pt(0.182, 0.5, in: rect))
        path.addLine(to: pt(0.818, 0.5, in: rect))
        path.move(to: pt(0.273, 0.273, in: rect))
        path.addLine(to: pt(0.727, 0.727, in: rect))
        path.move(to: pt(0.727, 0.273, in: rect))
        path.addLine(to: pt(0.273, 0.727, in: rect))
        return path
    }
}

/// A folded map, creases and all — "steers the music to a destination."
struct JourneyGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [
            (0.159, 0.295), (0.364, 0.227), (0.636, 0.318), (0.841, 0.25),
            (0.841, 0.75), (0.636, 0.773), (0.364, 0.682), (0.159, 0.75),
        ]
        var path = Path()
        path.move(to: pt(points[0].0, points[0].1, in: rect))
        for p in points.dropFirst() { path.addLine(to: pt(p.0, p.1, in: rect)) }
        path.closeSubpath()
        path.move(to: pt(0.364, 0.227, in: rect))
        path.addLine(to: pt(0.364, 0.682, in: rect))
        path.move(to: pt(0.636, 0.318, in: rect))
        path.addLine(to: pt(0.636, 0.773, in: rect))
        return path
    }
}

/// The selected row's own check, same source as the rest.
struct DJCheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.179, 0.536, in: rect))
        path.addLine(to: pt(0.393, 0.75, in: rect))
        path.addLine(to: pt(0.821, 0.25, in: rect))
        return path
    }
}
