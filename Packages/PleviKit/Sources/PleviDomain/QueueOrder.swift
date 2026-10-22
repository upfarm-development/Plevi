import Foundation

/// The index maths behind the play queue, kept out of `PlayerModel` so it can be tested without an
/// audio engine.
public enum QueueOrder {
    /// A shuffled copy of `items`, optionally with one entry pinned first.
    public static func shuffled<Item>(
        _ items: [Item],
        track: (Item) -> Track,
        smart: Bool,
        settings: SmartShuffleSettings,
        pinned pinnedIndex: Int? = nil,
        now: Date = Date(),
        using generator: inout some RandomNumberGenerator
    ) -> [Item] {
        if let pinnedIndex, items.indices.contains(pinnedIndex) {
            var rest = items
            let first = rest.remove(at: pinnedIndex)
            return [first] + shuffled(
                rest, track: track, smart: smart, settings: settings, now: now, using: &generator
            )
        }
        guard items.count > 1 else { return items }
        guard smart else {
            return Array(items.indices).shuffled(using: &generator).map { items[$0] }
        }
        let positions = SmartShuffle.orderedPositions(
            items.map(track),
            settings: settings,
            now: now,
            using: &generator
        )
        return positions.map { items[$0] }
    }

    /// The queue put back into the order it had before it was shuffled, built from the *live* queue
    /// rather than a saved copy of it.
    public static func restored<Element: Identifiable>(
        _ queue: [Element],
        originalOrder: [Element.ID]
    ) -> [Element] {
        var rank: [Element.ID: Int] = [:]
        rank.reserveCapacity(originalOrder.count)
        for (position, id) in originalOrder.enumerated() where rank[id] == nil {
            rank[id] = position
        }

        var head: [Element] = []
        var groups: [(rank: Int, members: [Element])] = []
        groups.reserveCapacity(queue.count)
        for element in queue {
            if let position = rank[element.id] {
                groups.append((position, [element]))
            } else if !groups.isEmpty {
                groups[groups.count - 1].members.append(element)
            } else {
                head.append(element)
            }
        }
        groups.sort { $0.rank < $1.rank }
        var result = head
        result.reserveCapacity(queue.count)
        for group in groups { result.append(contentsOf: group.members) }
        return result
    }
}

/// What the audio engine has armed to follow the playing track, reconciled against what the queue
/// now says follows it.
public enum QueueJoin {
    public enum Status: Equatable, Sendable {
        /// The entry right after the playing one is the entry that is armed.
        case inPlace
        /// It is still in the queue, but no longer the next entry.
        case displaced
        /// It is not in the queue at all.
        case removed
    }

    public static func status<Element: Identifiable>(
        of queue: [Element],
        currentIndex: Int?,
        armed: Element.ID
    ) -> Status {
        if let currentIndex, queue.indices.contains(currentIndex + 1),
           queue[currentIndex + 1].id == armed {
            return .inPlace
        }
        return queue.contains { $0.id == armed } ? .displaced : .removed
    }

    /// The audio has already moved on to `armed`, so the queue follows it.
    public static func adopt<Element: Identifiable>(
        _ queue: inout [Element],
        currentIndex: Int,
        armed: Element
    ) -> Int {
        guard queue.indices.contains(currentIndex) else {
            queue.append(armed)
            return queue.count - 1
        }
        let playing = queue[currentIndex].id
        if let existing = queue.firstIndex(where: { $0.id == armed.id }) {
            if existing == currentIndex + 1 { return existing }
            queue.remove(at: existing)
        }
        // The entry that was playing may have shifted if the armed one sat
        // before it; find it again by identity rather than trusting the index.
        let anchor = queue.firstIndex { $0.id == playing } ?? min(currentIndex, queue.count - 1)
        queue.insert(armed, at: anchor + 1)
        return anchor + 1
    }
}
