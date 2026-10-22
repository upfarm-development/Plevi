import Foundation

/// Where an endless carousel sits in its run.
public enum LoopingCarousel {
    /// How many times the run is laid out end to end. Odd, so there is a
    /// middle copy to come back to, and enough either side that a fast flick
    /// cannot reach an end before the recentring has happened.
    public static let copies = 9

    /// The first slot of the middle copy: as much to scroll through in one
    /// direction as the other.
    public static func middle(of count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (copies / 2) * count
    }

    /// Which card a slot is showing, whichever copy of it is on screen.
    public static func centredIndex(at slot: Int?, of count: Int) -> Int {
        guard let slot, count > 0 else { return 0 }
        return ((slot % count) + count) % count
    }

    /// Where the run should sit after the carousel's contents change.
    public static func slot(
        keeping current: Int?,
        wasShowing old: Int,
        nowShowing new: Int,
        grew: Bool
    ) -> Int? {
        guard new > 0 else { return nil }
        let home = middle(of: new)
        guard grew, old > 0, let current else { return home }
        return home + centredIndex(at: current, of: old)
    }
}
