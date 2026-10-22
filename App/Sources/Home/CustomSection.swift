import Foundation
import PleviDomain
import Observation
import PleviLibraryIndex

/// A Home shelf built from a question you wrote yourself.
struct CustomHomeSection: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var filter: LibraryFilter
    /// How the shelf is ordered, for a shelf made from a list that was sorted when it was kept.
    var sort: SavedSort?
    /// How many the shelf holds at most, or nil for everything the rules find.
    var limit: Int?

    init(
        id: UUID = UUID(),
        name: String = "",
        filter: LibraryFilter = LibraryFilter(),
        sort: SavedSort? = nil,
        limit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.filter = filter
        self.sort = sort
        self.limit = limit
    }

    /// What a shelf of songs actually draws: a list of them, or the card that plays the lot.
    var showsSongList: Bool { !showsAlbums }

    /// A sort kept alongside a shelf's rules.
    struct SavedSort: Codable, Hashable, Sendable {
        var songOrder: LibraryIndex.SongOrder?
        var albumOrder: AlbumFilter?
        var direction: LibraryIndex.SortDirection

        init(
            songOrder: LibraryIndex.SongOrder? = nil,
            albumOrder: AlbumFilter? = nil,
            direction: LibraryIndex.SortDirection = .forward
        ) {
            self.songOrder = songOrder
            self.albumOrder = albumOrder
            self.direction = direction
        }
    }

    /// A section of records draws a shelf of sleeves; a section of songs
    /// draws a card that plays them. Which one it is follows from what the
    /// filter is asking about, so there is no second decision to make.
    var showsAlbums: Bool { filter.subject == .albums }

    /// What to call it when it has not been named.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (showsAlbums ? "Albums" : "Songs") : trimmed
    }
}

/// The custom sections, in the order they were made.
@MainActor
@Observable
final class CustomSections {
    /// Where shelves lived before they were kept per library. Handed to the
    /// first library that asks — the one they were built for — and then
    /// removed.
    private static let legacyKey = "home.customSections"

    private let defaults: UserDefaults
    private var library: ServerID?

    private(set) var sections: [CustomHomeSection] = []
    /// Shelves in the stored list that this build could not read, as raw JSON.
    private var unreadable: [Data] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Points the shelves at a library. Called whenever one is connected.
    func use(library: ServerID?) {
        guard library != self.library else { return }
        self.library = library
        unreadable = []
        sections = library.flatMap(load) ?? []
    }

    /// Reads the open library's shelves again, from the key a restore by hand
    /// has just written.
    func reload() {
        let current = library
        library = nil
        use(library: current)
    }

    private func key(for library: ServerID) -> String {
        "home.customSections.\(library.rawValue.uuidString)"
    }

    private func load(_ library: ServerID) -> [CustomHomeSection] {
        if let data = defaults.data(forKey: key(for: library)) {
            if let list = TolerantList<CustomHomeSection>.decode(data) {
                unreadable = list.leftovers
                return list.items
            }
            // A blob that is not even an array. Kept under a second key
            // before anything can save over it, and the shelves start empty.
            defaults.set(data, forKey: key(for: library) + ".unreadable")
            return []
        }
        if let data = defaults.data(forKey: Self.legacyKey),
           let inherited = TolerantList<CustomHomeSection>.decode(data) {
            defaults.removeObject(forKey: Self.legacyKey)
            defaults.set(data, forKey: key(for: library))
            unreadable = inherited.leftovers
            return inherited.items
        }
        return []
    }

    func section(id: UUID) -> CustomHomeSection? {
        sections.first { $0.id == id }
    }

    func save(_ section: CustomHomeSection) {
        if let index = sections.firstIndex(where: { $0.id == section.id }) {
            sections[index] = section
        } else {
            sections.append(section)
        }
        write()
    }

    func delete(id: UUID) {
        sections.removeAll { $0.id == id }
        write()
    }

    private func write() {
        guard let library,
              let data = TolerantList(items: sections, leftovers: unreadable).encoded()
        else { return }
        defaults.set(data, forKey: key(for: library))
    }
}
