import SwiftUI
import PleviDomain

/// The presentation half of a DJ — colour, in the order the sheet lays its cards out — kept in the
/// App target the same way `RadioStations` keeps `RadioStation`'s presentation apart from
/// `LibraryIndex.Station`'s own identity.
enum DJStrategyCatalog {
    /// Reading order — the order the "Quiet List" card stacks its rows in.
    /// A ninth DJ is a new case added to `DJStrategyKind` and a new line
    /// here; nothing about the sheet itself changes.
    static let all: [DJStrategyKind] = [
        .moody, .drift, .era, .purist, .deepCuts, .gold, .fresh, .journey,
    ]

    /// The hand-off design's own accent per mode, given in `oklch(L C H)` and converted here to
    /// sRGB rather than left as a colour picked to merely look right on this one screen — the same
    /// eight numbers someone will hand back if this design ever…
    static func tint(for kind: DJStrategyKind) -> Color {
        switch kind {
        case .moody: Color(red: 0.5067, green: 0.3383, blue: 0.751) // oklch(0.55 0.16 300)
        case .drift: Color(red: 0.4539, green: 0.8532, blue: 0.7783) // oklch(0.82 0.10 180)
        case .era: Color(red: 0.9541, green: 0.7536, blue: 0.5028) // oklch(0.84 0.10 72)
        case .purist: Color(red: 0.9755, green: 0.5566, blue: 0.5467) // oklch(0.76 0.13 22)
        case .deepCuts: Color(red: 0.6113, green: 0.7601, blue: 0.9167) // oklch(0.80 0.07 250)
        case .gold: Color(red: 0.9611, green: 0.7956, blue: 0.4375) // oklch(0.86 0.12 85)
        case .fresh: Color(red: 0.5895, green: 0.8443, blue: 0.595) // oklch(0.82 0.11 145)
        case .journey: Color(red: 0.533, green: 0.7565, blue: 1.0) // oklch(0.80 0.12 255)
        }
    }

    /// The sheet's own background wash when there is no artwork colour to
    /// pull from — the hand-off design's default gradient, top to bottom.
    static let fallbackBackground: [Color] = [
        Color(red: 0.4557, green: 0.2372, blue: 0.0035), // oklch(0.42 0.10 58)
        Color(red: 0.2275, green: 0.1026, blue: 0.0166), // oklch(0.26 0.06 52)
        Color(red: 0.1015, green: 0.0434, blue: 0.0175), // oklch(0.17 0.03 48)
    ]
}
