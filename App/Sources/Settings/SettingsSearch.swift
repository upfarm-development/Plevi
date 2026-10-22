import SwiftUI

/// One searchable setting: what it is called, which page it lives on, and the other words someone
/// might go looking for it by.
struct SettingsEntry: Identifiable, Hashable {
    enum Page: Hashable {
        case servers
        case appearance
        case home
        case library
        case playlists
        case search
        case nowPlaying
        case pageSections
        case playback
        case storage
        case streamingTranscode
        case streamingTranscodeCellular
        case downloadTranscode

        var label: String {
            switch self {
            case .servers: "Servers"
            case .appearance: "Appearance"
            case .home: "Home"
            case .library: "Library"
            case .playlists: "Playlists"
            case .search: "Search"
            case .nowPlaying: "Now Playing"
            case .pageSections: "Library › Page sections"
            case .playback: "Playback"
            case .storage: "Downloads & Data"
            case .streamingTranscode: "Downloads & Data › Transcoding › Wi-Fi"
            case .streamingTranscodeCellular: "Downloads & Data › Transcoding › Cellular"
            case .downloadTranscode: "Downloads & Data › Transcoding › Downloads"
            }
        }
    }

    /// Which kind of device a setting is shown on, for the few that are not on both.
    enum Device: Hashable {
        case phone
        case pad

        static var current: Device {
            UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        }
    }

    var title: String
    var page: Page
    /// Words that are not in the title but describe the same thing — what the
    /// setting is called elsewhere, and the values it can take.
    var keywords: [String] = []
    /// Nil for a setting on every device.
    var only: Device? = nil

    var id: String { "\(page.label)|\(title)" }

    func matches(_ query: String) -> Bool {
        ([title] + keywords).contains { term in
            term.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static let all: [SettingsEntry] = [
        .init(title: "Theme", page: .appearance,
              keywords: ["appearance", "light", "dark", "system", "colour scheme", "color scheme"]),
        .init(title: "Artwork background", page: .library,
              keywords: ["appearance", "blurred", "colour", "color", "immersive", "page style", "artwork"]),
        .init(title: "Albums per row", page: .library,
              keywords: ["grid", "columns", "two", "three", "artwork", "size", "layout"],
              only: .phone),
        .init(title: "Grid density", page: .library,
              keywords: ["grid", "columns", "albums per row", "low", "high", "artwork", "size", "layout"],
              only: .pad),
        .init(title: "Sonically similar albums", page: .pageSections,
              keywords: ["similar", "sounds like", "album page", "sonic analysis",
                         "recommendations", "plex"]),
        .init(title: "Album review", page: .pageSections,
              keywords: ["about", "notes", "description", "album page"]),
        .init(title: "Page sections", page: .library,
              keywords: ["artist", "order", "top songs", "similar artists", "favourites", "albums"]),
        .init(title: "Codec badge on album pages", page: .library,
              keywords: ["format", "flac", "mp3", "album", "tracklist", "quality"]),
        .init(title: "Codec badge on Now Playing", page: .library,
              keywords: ["format", "player", "transcode", "opus", "aac", "kbps"]),
        .init(title: "Bit rate for lossy formats", page: .library,
              keywords: ["badge", "codec", "kbps", "mp3", "aac", "opus"]),
        .init(title: "kHz and bit depth for lossless", page: .library,
              keywords: ["badge", "codec", "sample rate", "flac", "alac", "24 bit", "hi-res"]),
        .init(title: "Show ratings", page: .library,
              keywords: ["stars", "hidden", "now playing", "albums", "playlists", "everywhere"]),
        .init(title: "Only on rated songs", page: .library,
              keywords: ["stars", "empty", "hide", "tidy", "ratings"]),
        .init(title: "Rating style", page: .library,
              keywords: ["stars", "half stars", "single star", "ratings"]),
        .init(title: "Lyrics", page: .nowPlaying,
              keywords: ["words", "lyrics", "sing", "karaoke", "lrc", "synced",
                         "now playing", "text"]),
        .init(title: "Now Playing layout", page: .nowPlaying,
              keywords: ["player", "classic", "framed", "bleed", "full width", "panel",
                         "artwork", "plexamp", "layout", "screen", "design"],
              only: .phone),
        .init(title: "Queue rail", page: .nowPlaying,
              keywords: ["queue", "up next", "rail", "sidebar", "side panel", "panel",
                         "open", "collapse", "expand", "tucked", "landscape", "portrait",
                         "now playing"],
              only: .pad),
        .init(title: "Track rows", page: .library,
              keywords: ["tracklist", "layout", "spacing", "stars", "number",
                         "rating", "album", "playlist", "popular", "favourites"]),
        .init(title: "Scrolling text", page: .nowPlaying,
              keywords: ["marquee", "roll", "scroll", "title", "artist", "album",
                         "truncate", "now playing", "ticker"]),
        .init(title: "Home shelves", page: .home,
              keywords: ["home", "shelves", "order", "radio", "recently added", "random",
                         "favourites", "reorder", "sections"]),
        .init(title: "Pinned items", page: .home,
              keywords: ["pinned", "pin", "home", "order", "reorder", "rearrange",
                         "drag", "unpin", "shelf"]),
        .init(title: "Radio", page: .home,
              keywords: ["radio", "stations", "shuffle", "deep cuts", "highly rated",
                         "decades", "genre", "mix"]),
        .init(title: "Playlist order", page: .playlists,
              keywords: ["playlists", "sort", "sorting", "smart", "alphabetical", "a-z", "order"]),
        .init(title: "Search result order", page: .search,
              keywords: ["search", "artists", "albums", "playlists", "songs", "order",
                         "reorder", "drag", "rank", "priority"]),
        .init(title: "Search all quick libraries", page: .search,
              keywords: ["search", "libraries", "quick switch", "other library", "kids",
                         "all libraries", "across", "plex"]),
        .init(title: "Playlists tab", page: .appearance, keywords: ["tabs", "tab bar"]),
        .init(title: "Downloads tab", page: .appearance, keywords: ["tabs", "tab bar", "offline"]),

        .init(title: "Custom equaliser presets", page: .playback,
              keywords: ["eq", "bands", "bass boost", "save", "preset", "curve"]),
        .init(title: "Equaliser", page: .playback,
              keywords: ["equalizer", "eq", "bass", "treble", "preset"]),
        .init(title: "Volume levelling", page: .playback,
              keywords: ["replaygain", "replay gain", "loudness", "normalise", "normalize"]),
        .init(title: "Crossfade", page: .playback, keywords: ["fade", "overlap", "gapless"]),
        .init(title: "Offline mode", page: .storage,
              keywords: ["offline", "downloads", "aeroplane", "airplane", "no network", "plane"]),
        .init(title: "Download over mobile data", page: .storage,
              keywords: ["downloads", "offline", "cellular", "data", "4g", "5g"]),
        .init(title: "Downloads", page: .storage,
              keywords: ["offline", "keep", "storage", "space", "space used"]),
        .init(title: "Merge downloads from all libraries", page: .storage,
              keywords: ["downloads", "offline", "quick switch", "libraries", "combined", "one list"]),
        .init(title: "Artwork cache", page: .storage,
              keywords: ["images", "covers", "sleeves", "storage", "size", "clear", "mb"]),
        .init(title: "Play cache", page: .storage,
              keywords: ["cache", "storage", "offline", "space", "gigabytes", "gb",
                         "purge", "clear", "re-stream", "data"]),
        .init(title: "Pre-cache", page: .storage,
              keywords: ["prefetch", "read ahead", "cache", "buffer", "wi-fi", "cellular", "data"]),
        .init(title: "Confirm stop and clear", page: .nowPlaying,
              keywords: ["queue", "warning", "dialogue", "dialog", "stop", "clear", "ask"]),
        .init(title: "Progress bar", page: .nowPlaying,
              keywords: ["waveform", "line", "scrubber", "now playing"]),
        .init(title: "Colour it like the stars", page: .nowPlaying,
              keywords: ["progress bar", "tint", "color", "accent", "white", "bleed",
                         "played", "now playing"],
              only: .phone),
        .init(title: "Transcoding on cellular", page: .streamingTranscodeCellular,
              keywords: ["transcode", "convert", "cellular", "mobile data", "streaming",
                         "4g", "5g", "data", "hotspot", "tethering", "bit rate",
                         "bandwidth", "aac", "opus"]),
        .init(title: "Refresh album details at launch", page: .storage,
              keywords: ["downloads", "refresh", "review", "about", "cover", "artwork",
                         "metadata", "update", "offline", "launch"]),
        .init(title: "Treat other Wi-Fi as cellular", page: .storage,
              keywords: ["transcode", "convert", "wifi", "wi-fi", "away", "home", "hotel",
                         "work", "public", "network", "streaming", "full quality", "original"]),
        .init(title: "Transcoding on Wi-Fi", page: .streamingTranscode,
              keywords: ["transcode", "convert", "wifi", "wi-fi", "streaming", "opus",
                         "aac", "bit rate", "bandwidth"]),
        .init(title: "Transcoding for downloads", page: .downloadTranscode,
              keywords: ["transcode", "convert", "download quality", "opus", "aac",
                         "bit rate", "offline"]),

        .init(title: "Test connection", page: .servers,
              keywords: ["reachable", "local", "remote", "endpoint", "proxy"]),
        .init(title: "Add server", page: .servers,
              keywords: ["navidrome", "subsonic", "plex", "sign in", "url", "password"]),
        .init(title: "Sync library now", page: .servers,
              keywords: ["index", "refresh", "rescan", "artists", "albums", "songs"]),
        .init(title: "Server details", page: .servers,
              keywords: ["version", "product", "opensubsonic", "extensions"]),
    ]

    static func results(for query: String) -> [SettingsEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let device = Device.current
        return all.filter { entry in
            (entry.only.map { $0 == device } ?? true) && entry.matches(trimmed)
        }
    }
}

/// Opens the page a search result lives on.
struct SettingsSearchResultLink: View {
    @Environment(AppModel.self) private var app
    let entry: SettingsEntry

    var body: some View {
        NavigationLink {
            destination
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(entry.page.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var destination: some View {
        @Bindable var settings = app.settings
        switch entry.page {
        case .servers:
            ServerSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .home:
            HomeSectionsSettingsView()
        case .library:
            LibrarySettingsView()
        case .playlists:
            PlaylistSettingsView()
        case .search:
            SearchSettingsView()
        case .nowPlaying:
            NowPlayingSettingsView()
        case .storage:
            StorageSettingsView()
        case .pageSections:
            ArtistSectionsSettingsView()
        case .playback:
            PlaybackSettingsView()
        case .streamingTranscode:
            TranscodeSettingsView(
                title: "Wi-Fi",
                policy: $settings.streamingTranscodeWiFi
            )
        case .streamingTranscodeCellular:
            TranscodeSettingsView(
                title: "Cellular",
                policy: $settings.streamingTranscodeCellular
            )
        case .downloadTranscode:
            TranscodeSettingsView(
                title: "Downloads",
                policy: $settings.downloadTranscode
            )
        }
    }
}
