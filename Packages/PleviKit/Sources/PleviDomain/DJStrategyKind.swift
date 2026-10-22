import Foundation

/// Which of the eight DJs.
public enum DJStrategyKind: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case moody
    case drift
    case era
    case purist
    case deepCuts
    case gold
    case fresh
    case journey

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .moody: "Moody"
        case .drift: "Drift"
        case .era: "Era"
        case .purist: "Purist"
        case .deepCuts: "Deep Cuts"
        case .gold: "Gold"
        case .fresh: "Fresh"
        case .journey: "Journey"
        }
    }

    /// One line, exactly as specced — what the DJ sheet's card shows under
    /// the name.
    public var subtitle: String {
        switch self {
        case .moody: "Weaves similar tracks between your queue"
        case .drift: "Lets go of the queue, follows the sound"
        case .era: "Stays in this song's decade"
        case .purist: "Never leaves the genre"
        case .deepCuts: "This vibe, but songs you never play"
        case .gold: "Only your 4-star-and-up favorites"
        case .fresh: "Mixes in your newest additions"
        case .journey: "Steers the music to a destination"
        }
    }

    /// Chosen to read as its own idea without borrowing a glyph already spoken for elsewhere — none
    /// of these are `dot.radiowaves.left.and.
    public var symbolName: String {
        switch self {
        case .moody: "waveform.path"
        case .drift: "wind"
        case .era: "clock.arrow.circlepath"
        case .purist: "tuningfork"
        case .deepCuts: "archivebox"
        case .gold: "star.circle.fill"
        case .fresh: "sparkles"
        case .journey: "map"
        }
    }

    /// The family glyph for the bottom bar toggle and the DJ sheet's own title — "a DJ is active,"
    /// not "which one" (each card already names itself).
    public static let familySymbolName = "infinity"
}
