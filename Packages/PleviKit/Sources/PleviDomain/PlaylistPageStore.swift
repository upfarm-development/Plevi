import Foundation

/// Where the first page of a playlist is kept between visits.
public protocol PlaylistPageStoring: Sendable {
    func page(for id: MediaID) async -> PlaylistPage?
    func save(_ page: PlaylistPage, for id: MediaID) async
    /// Whether a page saved within the last `seconds` is on file.
    func hasPage(for id: MediaID, newerThan seconds: TimeInterval) async -> Bool
}

/// One JSON file per playlist, in a folder the system may clear.
public actor FilePlaylistPageStore: PlaylistPageStoring {
    private let directory: URL
    private let capacity: Int

    public init(directory: URL, capacity: Int = 40) {
        self.directory = directory
        self.capacity = capacity
    }

    private func file(for id: MediaID) -> URL {
        let raw = id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "playlist"
        return directory.appending(path: "\(id.server.rawValue.uuidString)-\(raw).json")
    }

    public func page(for id: MediaID) -> PlaylistPage? {
        let url = file(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let page = try? JSONDecoder().decode(PlaylistPage.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return page
    }

    public func save(_ page: PlaylistPage, for id: MediaID) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(page) else { return }
        try? data.write(to: file(for: id), options: .atomic)
        trim()
    }

    public func hasPage(for id: MediaID, newerThan seconds: TimeInterval) -> Bool {
        let values = try? file(for: id).resourceValues(forKeys: [.contentModificationDateKey])
        guard let saved = values?.contentModificationDate else { return false }
        return Date().timeIntervalSince(saved) < seconds
    }

    /// Keeps the folder to the most recently written `capacity` playlists.
    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ), files.count > capacity else { return }
        let dated = files.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - capacity) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
