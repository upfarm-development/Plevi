import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// A record that came out on today's date, in some earlier year.
struct OnThisDayEntry: Identifiable, Equatable {
    let album: Album
    /// The review, when the server has one. Empty until it arrives, and often
    /// empty for good — plenty of records have nothing written about them.
    var summary: String = ""

    var id: String { album.id.rawValue }

    /// The small line above the title: who it is by, and the year it landed.
    var label: String {
        [album.artistName, album.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// One card: the sleeve, fading into a colour taken from it, with the reason to go back underneath.
struct OnThisDayCard: View {
    let entry: OnThisDayEntry
    let width: CGFloat
    /// How tall the card is. The big kind is square; the small kind keeps a
    /// sleeve's height and runs wider, which is what buys the title a line to
    /// itself.
    let height: CGFloat
    @Environment(AppModel.self) private var app
    @State private var palette: PaletteLoader

    /// The surface the small cards sit on.
    private var surface: Color { Color(.secondarySystemBackground) }

    init(
        entry: OnThisDayEntry,
        width: CGFloat,
        height: CGFloat? = nil
    ) {
        self.entry = entry
        self.width = width
        self.height = height ?? width
        _palette = State(initialValue: PaletteLoader(artwork: entry.album.artwork))
    }

    /// The colour the card sits on.
    private var ground: Color {
        let colours = palette.palette
        return colours.chromeScheme == nil ? Color(.secondarySystemBackground) : colours.background
    }

    var body: some View {
        NavigationLink(value: entry.album) {
            tintedCard
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: 22))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .albumContextMenu(entry.album, actions: MediaActions(app: app))
        .task(id: entry.album.artwork?.rawValue) {
            await palette.load(artwork: entry.album.artwork, using: app.artwork)
        }
        // It arrives after the picture does, so it fades in rather than
        // snapping.
        .animation(.easeOut(duration: 0.45), value: ground)
    }

    /// The tinted row: everything on one line, on a wash of the record's own
    /// colour, with the sleeve set on it rather than cut into it.
    private var tintedCard: some View {
        let sleeve = height - 28

        return HStack(spacing: 16) {
            ArtworkView(artwork: entry.album.artwork, size: sleeve, cornerRadius: 14)
                .frame(width: sleeve, height: sleeve)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(credit)
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .kerning(1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(entry.album.name)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.35)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let artist = entry.album.artistName {
                    Text(artist)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                // Under the words rather than beside them, which is what
                // gives a long title the whole width of the card instead of
                // whatever a button on the end had left over.
                playButton
            }
            // Nothing to push against: without this a long title widens the
            // row instead of truncating in it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { surface }
    }

    /// Plays the record without opening it.
    private var playButton: some View {
        Button {
            MediaActions(app: app).playAlbum(entry.album)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 12))
                Text("Play").font(.system(size: 14, weight: .semibold))
            }
            .padding(.leading, 13)
            .padding(.trailing, 16)
            .frame(height: 32)
            .background(Color(.label), in: .capsule)
            .foregroundStyle(Color(.systemBackground))
        }
        .buttonStyle(.plain)
    }

    /// How long ago, which is the only thing this shelf is about.
    private var credit: String {
        guard let year = entry.album.year else { return "" }
        let thisYear = Calendar.current.component(.year, from: Date())
        let ago = thisYear - year
        return switch ago {
        case ..<0: ""
        case 0: "This year"
        case 1: "1 year ago"
        default: "\(ago) years ago"
        }
    }
}

struct OnThisDayShelf: View {
    let entries: [OnThisDayEntry]
    /// The screen's own width, measured once above the `LazyVStack` this shelf sits in rather than
    /// re-measured here — see `MeasuredWidth`.
    var knownWidth: CGFloat = 0
    /// Whether more cards may still arrive — see `OnThisDayStore.isFilling`.
    var isFilling = false

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The shelf only moves while the app is in front.
    @Environment(\.scenePhase) private var scenePhase
    /// For the first moments after the app comes back, when the cards are laid
    /// out again and the scroll position is put back on `current`: that
    /// restoration is done without animation, so it cannot be seen sliding.
    @State private var justResumed = false

    /// The small kind: the same carousel, endless and moving on its own, but a card a sleeve tall
    /// rather than one filling the width.

    /// Which slot of the repeated run is centred, rather than which card: the same card appears in
    /// several slots.
    @State private var current: Int?
    @State private var advances = true

    init(entries: [OnThisDayEntry], knownWidth: CGFloat = 0, isFilling: Bool = false) {
        self.entries = entries
        self.knownWidth = knownWidth
        self.isFilling = isFilling
        _current = State(initialValue: entries.isEmpty ? nil : LoopingCarousel.middle(of: entries.count))
    }

    /// How many times the run is laid out end to end — see
    /// `LoopingCarousel`, which owns the arithmetic of being endless.
    private static let copies = LoopingCarousel.copies
    /// How much of the cards either side shows.
    private static let peek: CGFloat = 34
    /// Where the small cards begin: the same inset as the section title, so
    /// the two line up.
    private static let inset: CGFloat = 16
    private static let maxCardWidth: CGFloat = 460

    /// Repeated only when there is more than one thing to repeat: one card
    /// laid out nine times is the same record nine times.
    private var loop: [Int] {
        guard entries.count > 1 else { return entries.isEmpty ? [] : [0] }
        return Array(0..<(entries.count * Self.copies))
    }

    private func entry(at slot: Int) -> OnThisDayEntry {
        entries[slot % entries.count]
    }

    /// The slot to start on and come back to: the middle run, so there is as
    /// much to scroll through either way.
    private var middle: Int { LoopingCarousel.middle(of: entries.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HomeSection.onThisDay.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            MeasuredWidth(initial: knownWidth) { available in
                // Nothing until the width is known.
                let cardWidth = min(available - Self.inset - Self.peek, Self.maxCardWidth)
                // Everything the card does not use goes on the trailing side, and that is what
                // keeps it against the leading edge.
                let trailing = max(Self.peek, available - Self.inset - cardWidth)
                if cardWidth > 0 {
                    // Each kind is a fraction of its own width, so the shape holds at any size.
                    let height: CGFloat = cardWidth * 0.42
                    carousel(cardWidth: cardWidth, cardHeight: height, trailing: trailing)
                    } else {
                        // Not nothing: a branch that resolves to `EmptyView` is treated as no view
                        // at all, so the width behind it is never measured and this stays empty for
                        // ever.
                        Color.clear.frame(height: 0)
                    }
            }

            // So it reads as several rather than as one that changes.
            HStack(spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, _ in
                    Capsule()
                        .fill(.primary.opacity(index == centredIndex ? 0.8 : 0.22))
                        .frame(width: index == centredIndex ? 18 : 6, height: 5)
                }
            }
            .animation(.snappy(duration: 0.3), value: current)
            // Centred whichever kind of card is above them.
            .frame(maxWidth: .infinity, minHeight: 5)
            .opacity(entries.count > 1 && !isFilling ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: isFilling)
        }
        // Only for a shelf built before it had anything in it — with cards in hand the middle is
        // seeded at init.
        .onAppear {
            guard current == nil else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { current = middle }
        }
        // A different set of records is a different carousel; the same set keeps its place, so
        // coming back from an album does not send it back to the first card.
        .onChange(of: entries.map(\.id)) { old, new in
            // Without animation, because every run is identical: moving to
            // the same card in the new middle is a move nobody can see, and
            // animating it is the dance itself.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                current = LoopingCarousel.slot(
                    keeping: current,
                    wasShowing: old.count,
                    nowShowing: new.count,
                    grew: new.starts(with: old)
                )
            }
        }
    }

    private func carousel(
        cardWidth: CGFloat, cardHeight: CGFloat, trailing: CGFloat
    ) -> some View {
        ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(loop, id: \.self) { slot in
                            OnThisDayCard(
                                entry: entry(at: slot),
                                width: cardWidth,
                                height: cardHeight
                            )
                            .id(slot)
                        }
                    }
                    .scrollTargetLayout()
                }
                // Aligned to the cards rather than the page.
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $current)
                .transaction { transaction in
                    if justResumed { transaction.disablesAnimations = true }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    justResumed = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(900))
                        justResumed = false
                    }
                }
                // The card is exactly the room between these two, which is what turns "aligned"
                // into "aligned left": there is no spare width for the scroll view to divide
                // between the two sides, so the card comes to rest against the leading inset with
                // the…
                .safeAreaPadding(.leading, Self.inset)
                .safeAreaPadding(.trailing, trailing)
                // Height comes from the cards themselves rather than from the measured width.
                .fixedSize(horizontal: false, vertical: true)
                // A drag means someone is looking at this on purpose; it stops moving on its own
                // from then on.
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { advances = false }
                }
                // Keyed on the scene as well: leaving the foreground cancels the
                // loop, and coming back starts it again with a whole dwell to
                // wait, not what was left of one.
                .task(id: "\(advances)-\(entries.count)-\(scenePhase == .active)") { await runAdvancing() }
                // Back to the middle once the scrolling settles near an end.
                .onChange(of: current) { _, slot in
                    guard !advances, let slot else { return }
                    recentreIfNeeded(from: slot)
            }
    }

    /// Which card is centred, whichever copy of it is on screen.
    private var centredIndex: Int {
        LoopingCarousel.centredIndex(at: current, of: entries.count)
    }

    /// Long enough to read the title and take in the sleeve, short enough that the shelf is visibly
    /// alive while you are on Home.
    private static let dwell: Duration = .seconds(6)

    /// Puts the run back in the middle, without animating.
    @discardableResult
    private func recentreIfNeeded(from slot: Int) -> Int {
        let run = entries.count
        guard run > 0, slot < run || slot + 1 >= loop.count - run else { return slot }
        let centred = middle + (slot % run)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { current = centred }
        return centred
    }

    private func runAdvancing() async {
        guard advances, !reduceMotion, entries.count > 1, scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled, advances, scenePhase == .active, let slot = current else { return }

            // Back to the middle first, while nothing is moving. Done after
            // the step instead — which is what reacting to the slot amounted
            // to — it cancelled the step's own animation.
            let from = recentreIfNeeded(from: slot)
            if from != slot {
                // A moment to settle on the new offset before being asked to
                // animate away from it.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, advances else { return }
            }

            // A curve that does not overshoot, rather than a spring.
            withAnimation(.easeInOut(duration: 0.45)) { current = from + 1 }
        }
    }
}
