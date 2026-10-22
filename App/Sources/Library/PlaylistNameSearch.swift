import PleviDomain

/// Neither backend has a playlist search endpoint, so playlist search is a plain name match over a
/// list already held in memory — shared by `SearchView` and `CarPlayCoordinator`'s own search,
/// which each hold their own copy of the list rather…
enum PlaylistNameSearch {
    static func matching(_ query: String, in playlists: [Playlist]) -> [Playlist] {
        playlists
            .filter { $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
