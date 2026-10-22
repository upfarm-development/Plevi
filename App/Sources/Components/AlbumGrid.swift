import SwiftUI
import PleviDomain

/// The measurements an album grid needs: how many across, how wide each one is, and the space
/// between them.
struct AlbumGridMetrics {
    var columns: Int
    var spacing: CGFloat
    /// The width a card gets, once padding and the gaps are taken out.
    var itemWidth: CGFloat

    init(availableWidth: CGFloat, columns: Int, spacing: CGFloat = 10) {
        let columns = max(1, columns)
        self.columns = columns
        self.spacing = spacing
        let gaps = spacing * CGFloat(columns - 1)
        // A floor so a first layout pass with no width yet cannot produce a
        // zero-sized artwork request.
        self.itemWidth = max(80, (availableWidth - gaps) / CGFloat(columns))
    }

    /// Flexible rather than fixed, which in the ordinary case is the same arrangement — `itemWidth`
    /// is the width divided by the columns, so both deal out equal shares that add up to exactly
    /// the room there is.
    var gridItems: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: columns
        )
    }
}

/// Reports the width its content is given, so a grid can size itself to it.
struct MeasuredWidth<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content

    @State private var width: CGFloat

    init(initial: CGFloat = 0, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.content = content
        _width = State(initialValue: initial)
    }

    var body: some View {
        content(width)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onGeometryChange(for: CGFloat.self) { _ in proxy.size.width } action: {
                            width = $0
                        }
                }
            }
    }
}
