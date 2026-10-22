import Foundation
import PleviDomain

/// One entry in the play queue.
struct QueueItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var track: Track
    /// Which DJ put this entry here, or `nil` for the user's own.
    var djOrigin: DJStrategyKind?

    init(_ track: Track) {
        self.id = UUID()
        self.track = track
    }

    /// For a mirrored queue only: entries here are never minted locally —
    /// they carry the *target's* own `entry` UUID, so a later `jump`/`remove`/`move` command names
    /// the row the target itself knows, not one invented on…
    init(id: UUID, track: Track, djOrigin: DJStrategyKind? = nil) {
        self.id = id
        self.track = track
        self.djOrigin = djOrigin
    }

    static func authored(_ track: Track, by origin: DJStrategyKind) -> QueueItem {
        var item = QueueItem(track)
        item.djOrigin = origin
        return item
    }
}

/// What happens when the queue runs out.
enum RepeatMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case all
    case one

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }

    var isOn: Bool {
        self != .off
    }

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var label: String {
        switch self {
        case .off: "Repeat off"
        case .all: "Repeat queue"
        case .one: "Repeat song"
        }
    }
}
