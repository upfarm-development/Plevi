import Foundation

/// One entry in the Help section: what a feature is, and the logic behind it.
struct HelpTopic: Identifiable, Hashable {
    enum Chapter: String, CaseIterable, Identifiable {
        case playing
        case home
        case library
        case downloads
        case data

        var id: String { rawValue }

        var label: String {
            switch self {
            case .playing: "Playing"
            case .home: "Home"
            case .library: "Library"
            case .downloads: "Downloads"
            case .data: "Your library and your data"
            }
        }
    }

    var title: String
    var chapter: Chapter
    /// One line, shown under the title in the list.
    var summary: String
    /// The explanation, a paragraph per element.
    var body: [String]
    /// What someone might go looking for this by, when it is not in the title.
    var keywords: [String] = []

    var id: String { title }

    /// Everything worth searching, folded once.
    private let haystack: String

    init(
        title: String,
        chapter: Chapter,
        summary: String,
        body: [String],
        keywords: [String] = []
    ) {
        self.title = title
        self.chapter = chapter
        self.summary = summary
        self.body = body
        self.keywords = keywords
        self.haystack = ([title, summary] + body + keywords)
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func matches(_ query: String) -> Bool {
        haystack.contains(
            query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        )
    }
}
