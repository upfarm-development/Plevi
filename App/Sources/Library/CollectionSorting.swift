import Foundation
import PleviDomain
import PleviLibraryIndex

/// Sorting for the collection screens.
enum CollectionSorting {
    /// A tie broken the same way every time, so a list does not quietly
    /// reshuffle its equals between one visit and the next — the same
    /// guarantee the SQL orders get from ending on an id.
    static func byName<T>(
        _ items: [T],
        name: (T) -> String,
        id: (T) -> String,
        direction: LibraryIndex.SortDirection
    ) -> [T] {
        items.sorted { left, right in
            let a = name(left).localizedCaseInsensitiveCompare(name(right))
            if a != .orderedSame {
                return direction == .forward ? a == .orderedAscending : a == .orderedDescending
            }
            return id(left) < id(right)
        }
    }

    /// Sorts on a value that may be missing, with the missing ones last whichever way it runs.
    static func byValue<T, V: Comparable>(
        _ items: [T],
        value: (T) -> V?,
        name: (T) -> String,
        id: (T) -> String,
        direction: LibraryIndex.SortDirection,
        forwardIsDescending: Bool = true
    ) -> [T] {
        let descending = direction == .forward ? forwardIsDescending : !forwardIsDescending
        return items.sorted { left, right in
            switch (value(left), value(right)) {
            case let (l?, r?):
                if l != r { return descending ? l > r : l < r }
            case (nil, .some): return false
            case (.some, nil): return true
            case (nil, nil): break
            }
            let a = name(left).localizedCaseInsensitiveCompare(name(right))
            if a != .orderedSame { return a == .orderedAscending }
            return id(left) < id(right)
        }
    }
}

/// How the list of collections is ordered.
enum CollectionListSort: String, CaseIterable, Identifiable, SortableOrder {
    case name
    case itemCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .itemCount: "Size"
        }
    }

    var scale: LibraryIndex.SortScale {
        switch self {
        case .name: .alphabetical
        case .itemCount: .quantity
        }
    }

    func sorted(
        _ collections: [MediaCollection],
        direction: LibraryIndex.SortDirection
    ) -> [MediaCollection] {
        switch self {
        case .name:
            CollectionSorting.byName(
                collections, name: \.name, id: { $0.id.rawValue }, direction: direction
            )
        case .itemCount:
            CollectionSorting.byValue(
                collections, value: \.itemCount, name: \.name,
                id: { $0.id.rawValue }, direction: direction
            )
        }
    }
}

/// How the artists inside a collection are ordered.
enum CollectionArtistSort: String, CaseIterable, Identifiable, SortableOrder {
    case name
    case albumCount
    case rating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .albumCount: "Album count"
        case .rating: "Rating"
        }
    }

    var scale: LibraryIndex.SortScale {
        switch self {
        case .name: .alphabetical
        case .albumCount, .rating: .quantity
        }
    }

    func sorted(_ artists: [Artist], direction: LibraryIndex.SortDirection) -> [Artist] {
        switch self {
        case .name:
            CollectionSorting.byName(
                artists, name: \.name, id: { $0.id.rawValue }, direction: direction
            )
        case .albumCount:
            CollectionSorting.byValue(
                artists, value: \.albumCount, name: \.name,
                id: { $0.id.rawValue }, direction: direction
            )
        case .rating:
            CollectionSorting.byValue(
                artists, value: { $0.rating?.value }, name: \.name,
                id: { $0.id.rawValue }, direction: direction
            )
        }
    }
}

/// How the records inside a collection are ordered.
enum CollectionAlbumSort: String, CaseIterable, Identifiable, SortableOrder {
    case name
    case artist
    case year
    case dateAdded
    case datePlayed
    case playCount
    case rating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .artist: "Artist"
        case .year: "Year"
        case .dateAdded: "Date added"
        case .datePlayed: "Date played"
        case .playCount: "Play count"
        case .rating: "Rating"
        }
    }

    var scale: LibraryIndex.SortScale {
        switch self {
        case .name, .artist: .alphabetical
        case .year, .dateAdded, .datePlayed: .recency
        case .playCount, .rating: .quantity
        }
    }

    func sorted(_ albums: [Album], direction: LibraryIndex.SortDirection) -> [Album] {
        let title: (Album) -> String = { $0.displayName }
        let key: (Album) -> String = { $0.id.rawValue }
        switch self {
        case .name:
            return CollectionSorting.byName(albums, name: title, id: key, direction: direction)
        case .artist:
            return CollectionSorting.byName(
                albums, name: { $0.artistName ?? $0.displayName }, id: key, direction: direction
            )
        case .year:
            return CollectionSorting.byValue(
                albums, value: \.year, name: title, id: key, direction: direction
            )
        case .dateAdded:
            return CollectionSorting.byValue(
                albums, value: \.addedAt, name: title, id: key, direction: direction
            )
        case .datePlayed:
            return CollectionSorting.byValue(
                albums, value: \.playedAt, name: title, id: key, direction: direction
            )
        case .playCount:
            return CollectionSorting.byValue(
                albums, value: \.playCount, name: title, id: key, direction: direction
            )
        case .rating:
            return CollectionSorting.byValue(
                albums, value: { $0.rating?.value }, name: title, id: key, direction: direction
            )
        }
    }
}
