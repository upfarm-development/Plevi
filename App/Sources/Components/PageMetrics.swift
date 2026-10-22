import SwiftUI

/// How much room a detail page has been given, and the handful of numbers the artwork-led pages
/// derive from it.
struct PageMetrics: Equatable {
    /// The width the page is laying out in, read from its scroll view's
    /// `containerSize`. Zero until the first reading lands — see
    /// `effectiveWidth`.
    var width: CGFloat
    /// And how tall, from the same reading.
    var height: CGFloat
    var horizontalSizeClass: UserInterfaceSizeClass?
    var verticalSizeClass: UserInterfaceSizeClass?
    var dynamicTypeSize: DynamicTypeSize

    init(
        size: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        dynamicTypeSize: DynamicTypeSize
    ) {
        self.width = size.width
        self.height = size.height
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.dynamicTypeSize = dynamicTypeSize
    }

    // MARK: The arrangement's own measurements

    /// The sleeve, the photograph or the mosaic, at the size the wide page draws it.
    static let artworkSide: CGFloat = 300

    /// The picture's corner, on all three pages.
    static let artworkCorner: CGFloat = 16

    /// The page's own left and right margin.
    static let pageMargin: CGFloat = 16

    /// Between the picture and the column of words beside it.
    static let columnGutter: CGFloat = 28

    /// A little room under the navigation bar before the card starts.
    static let headerTopGap: CGFloat = 12
    /// And a clear step after it before whatever the page puts first.
    static let headerBottomGap: CGFloat = 26

    /// Between the foot of the controls and the first line of About.
    static let aboutTopGap: CGFloat = 16

    /// What the details block is assumed to be tall before it has reported its real height —
    /// roughly the two-line-title case.
    static let detailsHeightSeed: CGFloat = 200

    /// How wide Play, Shuffle and the menu are allowed to get together.
    static let actionRowWidth: CGFloat = 420

    /// Between song columns, matching the phone's adaptive grid so a shelf
    /// laid out either way has the same rhythm.
    static let songColumnSpacing: CGFloat = 10

    // MARK: Thresholds

    /// Below this the phone's page stands and nothing else here is read.
    static let sideBySideWidth: CGFloat = 700

    /// The narrowest window five songs may be laid across.
    static let fiveAcrossWidth: CGFloat = 900

    /// The narrowest window a record's tracklist may be dealt into two.
    static let pairedTracksWidth: CGFloat = 800

    /// What to assume for the one frame before the scroll view has reported anything.
    static let unmeasuredWidth: CGFloat = 1024

    /// The width to reason from: what was measured, or the seed above until
    /// something has been.
    var effectiveWidth: CGFloat {
        width > 0 ? width : Self.unmeasuredWidth
    }

    // MARK: The decision

    /// Whether the picture stands beside the words rather than above them.
    var standsSideBySide: Bool {
        guard !dynamicTypeSize.isAccessibilitySize else { return false }
        guard horizontalSizeClass == .regular, verticalSizeClass == .regular else { return false }
        return effectiveWidth >= Self.sideBySideWidth
    }

    /// What is left for the name, the facts, the controls and the About
    /// paragraph once the picture and the margins have had theirs.
    var textColumnWidth: CGFloat {
        max(0, effectiveWidth - Self.pageMargin * 2 - Self.artworkSide - Self.columnGutter)
    }

    /// How wide Play, Shuffle and the menu actually come out: the cap, or
    /// the column, whichever is less.
    var actionRowWidth: CGFloat {
        min(Self.actionRowWidth, textColumnWidth)
    }

    /// Whether the window is lying on its side rather than standing up.
    var isOnItsSide: Bool {
        height > 0 && effectiveWidth > height
    }

    /// How many songs across the artist page's Popular and My Favourites shelves lay out — five
    /// where the window is on its side, three where it is stood up.
    var songColumns: Int? {
        guard standsSideBySide else { return nil }
        return isOnItsSide && effectiveWidth >= Self.fiveAcrossWidth ? 5 : 3
    }

    /// Whether *Appears On* and *Similar Artists* stand side by side at the
    /// foot of an artist page rather than one under the other. Half of 700
    /// less the margins is still a wider shelf than any phone has.
    var pairsClosingSections: Bool { standsSideBySide }

    /// Whether a record's tracklist runs in two columns rather than one.
    var pairsTrackList: Bool {
        standsSideBySide && isOnItsSide && effectiveWidth >= Self.pairedTracksWidth
    }

    /// Exactly this many columns, dividing the room equally.
    static func songGrid(_ columns: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: songColumnSpacing, alignment: .top),
            count: max(1, columns)
        )
    }
}
