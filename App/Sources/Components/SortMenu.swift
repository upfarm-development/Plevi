import SwiftUI
import PleviLibraryIndex

/// The sort control every library list uses: what to sort by, and which way round it runs.
struct SortMenu<Order: SortableOrder>: View {
    @Binding var order: Order
    @Binding var direction: LibraryIndex.SortDirection

    var body: some View {
        Menu {
            SortMenuContent(order: $order, direction: $direction)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
        // What is on screen is sorted the moment the menu is touched, and the
        // menu names both halves of the answer.
        .accessibilityValue("\(order.label), \(order.scale.label(direction))")
    }
}

/// The two pickers on their own, for a toolbar that has no room for a
/// control of its own and folds them into a wider menu instead.
struct SortMenuContent<Order: SortableOrder>: View {
    @Binding var order: Order
    @Binding var direction: LibraryIndex.SortDirection

    var body: some View {
        Picker("Sort by", selection: $order) {
            ForEach(Order.allCases) { option in
                Text(option.label).tag(option)
            }
        }

        // Its own section, so the two questions do not read as one long list.
        Section {
            Picker("Order", selection: $direction) {
                ForEach(LibraryIndex.SortDirection.allCases) { way in
                    Text(order.scale.label(way)).tag(way)
                }
            }
        }
    }
}

/// What `SortMenu` needs of an order to draw it: a name, the two names its directions go by, and
/// the list of them.
protocol SortableOrder: CaseIterable, Hashable, Identifiable
where AllCases: RandomAccessCollection {
    var label: String { get }
    var scale: LibraryIndex.SortScale { get }
}

extension LibraryIndex.SongOrder: SortableOrder {}
extension LibraryIndex.ArtistOrder: SortableOrder {}
// The albums list keeps its own sort type, since what it offers is a subset
// of `AlbumFilter` rather than an order of its own — see
// `AlbumCollectionView.AlbumSort`.
extension AlbumCollectionView.AlbumSort: SortableOrder {}
