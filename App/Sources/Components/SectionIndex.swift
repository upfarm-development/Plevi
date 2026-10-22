import SwiftUI
import PleviDomain

/// The A–Z jump bar down the right edge of a long list.
struct SectionIndexBar: View {
    /// The sections that have rows, already in bar order.
    let sections: [String]
    let onSelect: (String) -> Void

    /// Tracked so the same section is not fired repeatedly as a thumb slides
    /// within one letter's band.
    @State private var lastSection: String?
    /// Where the thumb is and what is under it, while it is down.
    @State private var touch: Touch?
    /// The jump waiting to happen, if the thumb settles before it fires.
    @State private var pendingJump: Task<Void, Never>?

    private struct Touch: Equatable {
        var y: CGFloat
        var section: String
    }

    /// Each letter's band.
    private static let letterHeight: CGFloat = 14

    /// Invisible room around the letters, so the strip is a thumb's width to hit rather than the
    /// twenty points it is to look at.
    private static let touchInset: CGFloat = 22

    /// The letter shown under the thumb, and how far from the strip it sits.
    private static let bubbleSize: CGFloat = 56
    /// Clear space between the bubble and the letters.
    private static let bubbleGap: CGFloat = 6

    private var barHeight: CGFloat {
        CGFloat(sections.count) * Self.letterHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sections, id: \.self) { section in
                Text(section)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)
                    .frame(width: 20, height: Self.letterHeight)
            }
        }
        // The whole strip is the target, not each label: the letters are far
        // too small to hit individually.
        .padding(.leading, Self.touchInset)
        .padding(.vertical, Self.touchInset / 2)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) { bubble }
        // High priority, so a touch here beats the list underneath.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    select(atY: value.location.y - Self.touchInset / 2, height: barHeight)
                }
                .onEnded { value in
                    pendingJump?.cancel()
                    pendingJump = nil
                    // Land exactly where the thumb was lifted, at once — the
                    // debounce is for a thumb still moving, and this one just
                    // stopped.
                    let height = barHeight
                    if height > 0, !sections.isEmpty {
                        let step = height / CGFloat(sections.count)
                        let y = value.location.y - Self.touchInset / 2
                        let index = min(max(Int(y / step), 0), sections.count - 1)
                        onSelect(sections[index])
                    }
                    lastSection = nil
                    touch = nil
                }
        )
        .padding(.trailing, 2)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var bubble: some View {
        if let touch {
            Text(touch.section)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
                .frame(width: Self.bubbleSize, height: Self.bubbleSize)
                // Thick rather than regular: it lands on album artwork as
                // often as on a plain list, and a letter you have to look
                // twice at is no help at all.
                .background(.thickMaterial, in: .circle)
                .overlay { Circle().strokeBorder(.quaternary) }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                // Anchored to the top of the letters, then moved down to the
                // thumb: the letters column starts below the vertical inset.
                .offset(
                    x: -(Self.bubbleSize + Self.bubbleGap),
                    y: Self.touchInset / 2 + touch.y - Self.bubbleSize / 2
                )
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func select(atY y: CGFloat, height: CGFloat) {
        guard height > 0, !sections.isEmpty else { return }
        let step = height / CGFloat(sections.count)
        let index = min(max(Int(y / step), 0), sections.count - 1)
        let section = sections[index]
        // The bubble follows the thumb even inside one letter's band, so it
        // stays under the finger rather than jumping a letter at a time.
        touch = Touch(y: min(max(y, 0), height), section: section)
        guard section != lastSection else { return }
        let firstTouch = lastSection == nil
        lastSection = section
        UISelectionFeedbackGenerator().selectionChanged()

        pendingJump?.cancel()
        guard !firstTouch else {
            // The very first letter under the thumb jumps at once — nothing
            // is debounced about landing where a touch began.
            onSelect(section)
            return
        }
        // Anything after that waits a beat to see whether the thumb is still sliding.
        pendingJump = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled else { return }
            onSelect(section)
        }
    }
}

/// Shared metrics for the library's list views, so artists, genres, search
/// results and playlists all sit at the same density.
enum CompactList {
    static let thumbnailSize: CGFloat = 40
    /// How tall a row's content is, set by the thumbnail every row is built
    /// around. Rows that have no thumbnail — "New Playlist…" and its like —
    /// take it too, so a list of them does not step where they fall.
    static let rowHeight: CGFloat = thumbnailSize
    static let rowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
    /// Wider on the trailing side to clear the jump bar, so a disclosure
    /// chevron does not sit underneath the letters.
    static let indexedRowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 32)
}

/// A list grouped into alphabet sections with a jump bar down the right edge.
struct IndexedList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    /// What each row is filed under — usually the name shown on it.
    let title: (Item) -> String
    var minimumForIndex = 20
    /// What tells one set of rows from another, when the rows themselves are too many to compare.
    var groupingKey: String = ""

    /// Runs worked out by the caller, over `items` already in bar order.
    var runs: AlphabetIndex.SectionRuns?

    @ViewBuilder let row: (Item) -> Row

    /// How the rows are filed, worked out once per set of rows.
    @State private var groups: [(section: String, values: [Item])] = []

    private var groupingIdentity: String { "\(groupingKey)|\(items.count)" }

    /// What to draw right now.
    private var shownGroups: [(section: String, values: [Item])] {
        groups.isEmpty && !items.isEmpty ? AlphabetIndex.group(items, title: title) : groups
    }

    /// The runs to draw when the caller supplied them.
    private var suppliedRuns: AlphabetIndex.SectionRuns? {
        guard let runs else { return nil }
        guard runs.count == items.count, !runs.isEmpty else { return .flat(count: items.count) }
        return runs
    }

    var body: some View {
        if let suppliedRuns {
            // No filing task: it was done before these rows ever arrived.
            preFiled(suppliedRuns)
        } else if items.count < minimumForIndex {
            List(items) { item in
                row(item).listRowInsets(CompactList.rowInsets)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollIndicators(.hidden)
        } else {
            indexed
                .task(id: groupingIdentity) {
                    groups = AlphabetIndex.group(items, title: title)
                }
        }
    }

    /// The same list, drawn from runs the caller worked out.
    private func preFiled(_ runs: AlphabetIndex.SectionRuns) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(runs.ranges.indices, id: \.self) { j in
                    Section {
                        ForEach(items[runs.ranges[j]]) { item in
                            row(item)
                                .listRowInsets(CompactList.indexedRowInsets)
                                .frame(height: rowHeight)
                        }
                    }
                    .id(runs.sections[j])
                }
            }
            .background {
                if rowHeight == nil, let first = items.first {
                    row(first)
                        .listRowInsets(CompactList.indexedRowInsets)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            rowHeight = $0
                        }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollIndicators(.hidden)
            .overlay(alignment: .trailing) {
                // Nothing to point at when the runs are one unnamed stretch.
                if runs.sections != [""] {
                    SectionIndexBar(sections: runs.sections) { section in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            guard let j = runs.sections.firstIndex(of: section),
                                  let target = items[runs.ranges[j].lowerBound] as Item?
                            else { return }
                            proxy.scrollTo(target.id, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    /// The height every row is held to, once it is known.
    @State private var rowHeight: CGFloat?

    private var indexed: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(shownGroups, id: \.section) { group in
                    // No letter over each run.
                    Section {
                        ForEach(group.values) { item in
                            row(item)
                                .listRowInsets(CompactList.indexedRowInsets)
                                .frame(height: rowHeight)
                        }
                    }
                    .id(group.section)
                }
            }
            .background {
                // One real row, measured and never drawn.
                if rowHeight == nil, let first = items.first {
                    row(first)
                        .listRowInsets(CompactList.indexedRowInsets)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            rowHeight = $0
                        }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            // The jump bar is the way down a list this long; a scroll bar
            // beside it is two indicators in the same strip of screen.
            .scrollIndicators(.hidden)
            .overlay(alignment: .trailing) {
                SectionIndexBar(sections: shownGroups.map(\.section)) { section in
                    let currentGroups = shownGroups
                    // No animation: a jump bar is for arriving, and animating
                    // across a few thousand rows is a long blur.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        // The row itself, not the Section wrapping it.
                        if let target = currentGroups.first(where: { $0.section == section })?
                            .values.first?.id
                        {
                            proxy.scrollTo(target, anchor: .top)
                        } else {
                            proxy.scrollTo(section, anchor: .top)
                        }
                    }
                }
            }
        }
    }
}

